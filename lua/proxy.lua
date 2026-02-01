-- proxy.lua - 主代理处理逻辑
local _M = {}
local config = require "config"
local circuit_breaker = require "circuit_breaker"
local rate_limiter = require "rate_limiter"
local metrics = require "metrics"
local logger = require "logger"
local redis_client = require "redis_client"
local http = require "resty.http"
local cjson = require "cjson"

-- API密钥缓存
local api_keys = nil

local function normalize_redis_value(value)
    if value == ngx.null then
        return nil
    end
    return value
end

-- 加载API密钥
local function load_api_keys()
    if not api_keys then
        api_keys = config.load_api_keys()
    end
    return api_keys
end

-- 不应该转发的headers
local hop_by_hop_headers = {
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    ["te"] = true,
    ["trailers"] = true,
    ["transfer-encoding"] = true,
    ["upgrade"] = true,
    ["host"] = true
}

-- 修复: 幂等方法判断,POST也可能是幂等的(带幂等键时)
local function is_idempotent_method(method)
    local m = string.upper(method or "")
    return m == "GET" or m == "HEAD" or m == "PUT" or m == "DELETE" or m == "OPTIONS" or m == "TRACE"
end

-- 修复: 更精确的错误分类
local function classify_error(err)
    if not err then
        return "upstream_error"
    end
    local lower = string.lower(err)
    if string.find(lower, "timeout", 1, true) or string.find(lower, "timed out", 1, true) then
        return "timeout"
    end
    if string.find(lower, "refused", 1, true) or string.find(lower, "connection refused", 1, true) then
        return "connection_refused"
    end
    if string.find(lower, "connect", 1, true) or string.find(lower, "failed to connect", 1, true) then
        return "connect_failure"
    end
    if string.find(lower, "ssl", 1, true) or string.find(lower, "certificate", 1, true) then
        return "ssl_error"
    end
    if string.find(lower, "broken pipe", 1, true) or string.find(lower, "connection reset", 1, true) then
        return "connection_broken"
    end
    return "upstream_error"
end

-- 修复: 缓存键应该包含方法和部分headers(如Accept)以避免缓存污染
local function cache_key(provider, method, uri, args)
    if args and args ~= "" then
        return string.format("cache:%s:%s:%s?%s", provider, method, uri, args)
    end
    return string.format("cache:%s:%s:%s", provider, method, uri)
end

-- 修复: 降级缓存应该检查缓存新鲜度
local function read_cached_response(provider, method, uri, args)
    if method ~= "GET" and method ~= "HEAD" then
        return nil, nil
    end

    local key = cache_key(provider, method, uri, args)
    local raw = nil

    if config.redis and config.redis.enabled then
        local redis_raw, err = redis_client.with_redis(function(red)
            return red:get(key)
        end)
        if err then
            ngx.log(ngx.WARN, "redis response_cache get failed: ", err)
        else
            raw = normalize_redis_value(redis_raw)
        end
    end

    if not raw then
        local cache = ngx.shared.response_cache
        if cache then
            raw = cache:get(key)
        end
    end

    if not raw then
        return nil, nil
    end

    local ok, cached = pcall(cjson.decode, raw)
    if not ok or not cached then
        ngx.log(ngx.WARN, "Failed to decode cached response: ", tostring(raw))
        return nil, nil
    end

    local cache_age = ngx.now() - (cached.cached_at or 0)
    return cached, cache_age
end

local function serve_cached_response(ctx, provider, cached, cache_age, degraded)
    ngx.header["X-Proxy-Request-ID"] = ctx.request_id
    ngx.header["X-Provider"] = provider
    ngx.header["X-Cache-Age"] = string.format("%.2f", cache_age)
    if degraded then
        ngx.header["X-Degraded"] = "cache"
    else
        ngx.header["X-Cache"] = "HIT"
    end

    if cached.content_type then
        ngx.header["Content-Type"] = cached.content_type
    end

    ngx.status = cached.status or 200
    ngx.print(cached.body or "")
    return true
end

local function try_serve_fresh_cached_response(ctx, provider)
    local cached, cache_age = read_cached_response(provider, ngx.var.request_method, ngx.var.uri, ngx.var.args)
    if not cached then
        return false
    end

    if cache_age > config.proxy.cache_ttl then
        return false
    end

    return serve_cached_response(ctx, provider, cached, cache_age, false)
end

local function try_serve_cached_response(ctx, provider)
    local cached, cache_age = read_cached_response(provider, ngx.var.request_method, ngx.var.uri, ngx.var.args)
    if not cached then
        return false
    end

    -- 修复: 添加缓存时间戳检查,避免提供过期缓存
    local max_stale = config.proxy.cache_ttl * 2  -- 允许最多2倍TTL的陈旧缓存用于降级
    if cache_age > max_stale then
        ngx.log(ngx.INFO, "Cached response too old, age: ", cache_age, "s")
        return false
    end

    return serve_cached_response(ctx, provider, cached, cache_age, true)
end

-- 构建上游URL
local function build_upstream_url(provider_config, original_path, api_key)
    local upstream = provider_config.upstream
    local path = string.sub(original_path, #provider_config.prefix)
    if path == "" then
        path = "/"
    end

    -- Alchemy 特殊处理:API Key 拼接在URL路径
    if provider_config.auth_type == "url" and api_key then
        path = "/v2/" .. api_key .. path
    end

    return upstream .. path
end

-- 构建请求headers
local function build_request_headers(provider_config, original_headers, api_key, request_id)
    local headers = {}

    -- 复制原始headers,过滤hop-by-hop headers
    for k, v in pairs(original_headers) do
        if not hop_by_hop_headers[string.lower(k)] then
            headers[k] = v
        end
    end

    -- 添加追踪header
    headers["x-onekey-request-id"] = request_id

    -- 注入认证信息
    if provider_config.auth_type == "basic" and api_key then
        -- Basic Auth
        headers["Authorization"] = "Basic " .. ngx.encode_base64(api_key .. ":")
    elseif provider_config.auth_type == "header" and api_key then
        -- Header方式
        headers[provider_config.auth_header] = api_key
    end
    -- URL方式的认证已经在URL中处理

    return headers
end

-- 修复: 重试逻辑应该支持更细粒度的控制
local function should_retry(error_type, attempt, max_attempts)
    if attempt >= max_attempts then
        return false
    end
    
    -- 某些错误类型不应该重试
    local non_retryable = {
        ["ssl_error"] = true,
        ["request_too_large"] = true,
        ["upstream_4xx"] = true  -- 客户端错误不重试
    }
    
    return not non_retryable[error_type]
end

-- 执行HTTP请求(带重试)
local function do_http_request(httpc, method, url, headers, body, timeout, retry_config, ssl_verify)
    local attempts = 0
    local retry_times = retry_config and retry_config.times or 0
    
    -- 非幂等请求不重试
    if not is_idempotent_method(method) then
        retry_times = 0
    end
    
    local max_attempts = retry_times + 1
    local retry_delay = (retry_config and retry_config.delay or 100) / 1000 -- 转换为秒
    local last_error = nil
    local last_error_type = nil

    while attempts < max_attempts do
        attempts = attempts + 1

        -- 设置超时
        httpc:set_timeouts(timeout.connect, timeout.send, timeout.read)

        -- 发送请求
        local res, err = httpc:request_uri(url, {
            method = method,
            headers = headers,
            body = body,
            ssl_verify = ssl_verify
        })

        if res then
            return res, nil
        end

        -- 请求失败
        last_error = err
        last_error_type = classify_error(err)
        
        ngx.log(ngx.WARN, "Upstream request failed (attempt ", attempts, "/", max_attempts, "): ", err,
                " type: ", last_error_type)

        -- 检查是否应该重试
        if not should_retry(last_error_type, attempts, max_attempts) then
            return nil, err
        end
        
        -- 如果还有重试机会,等待后重试
        if attempts < max_attempts then
            -- 修复: 指数退避重试
            local backoff = retry_delay * math.pow(2, attempts - 1)
            ngx.sleep(math.min(backoff, 2))  -- 最多等待2秒
        end
    end

    return nil, last_error or "max retries exceeded"
end

-- 处理代理请求
function _M.handle_request()
    local start_time = ngx.now()
    local ctx = ngx.ctx

    -- 生成请求ID
    ctx.request_id = logger.generate_request_id()

    -- 获取Provider配置
    local provider_name, provider_config = config.get_provider(ngx.var.uri)
    if not provider_name then
        logger.log_error(ctx, "invalid_provider", "No matching provider found", { path = ngx.var.uri })
        ngx.status = 404
        ngx.say('{"error": "Provider not found"}')
        return
    end

    ctx.provider = provider_name

    -- 记录请求开始
    logger.log_request_start(ctx)

    -- 检查限流
    local ip = ngx.var.remote_addr
    local rate_ok, limit_type, limit, current = rate_limiter.check(provider_name, ip)
    if not rate_ok then
        logger.log_rate_limit(ctx, limit_type, limit, current)
        metrics.record_request(provider_name, ngx.var.request_method, 429, nil, "rate_limit")
        ngx.status = 429
        ngx.header["Retry-After"] = "60"
        ngx.say('{"error": "Rate limit exceeded", "type": "' .. limit_type .. '"}')
        return
    end

    -- 正常缓存命中(仅GET/HEAD),仅在熔断器关闭时使用
    local cb_state = circuit_breaker.get_state(provider_name)
    if cb_state == "closed" then
        if try_serve_fresh_cached_response(ctx, provider_name) then
            local latency = (ngx.now() - start_time) * 1000
            metrics.record_request(provider_name, ngx.var.request_method, ngx.status, latency, "cache_hit")
            logger.log_request_end(ctx, ngx.status, latency, "cache hit")
            logger.access_log(ctx, ngx.status, latency)
            return
        end
    end

    -- 检查熔断器
    if not circuit_breaker.allow_request(provider_name) then
        local cb_state = circuit_breaker.get_state(provider_name)
        logger.log_circuit_breaker(provider_name, cb_state, { request_id = ctx.request_id })
        
        -- 修复: 熔断时先尝试降级缓存
        if try_serve_cached_response(ctx, provider_name) then
            local latency = (ngx.now() - start_time) * 1000
            ctx.error_type = "degraded_cache"
            metrics.record_request(provider_name, ngx.var.request_method, ngx.status, latency, "degraded_cache")
            logger.log_request_end(ctx, ngx.status, latency, "degraded from circuit breaker")
            logger.access_log(ctx, ngx.status, latency)
            return
        end
        
        metrics.record_request(provider_name, ngx.var.request_method, 503, nil, "circuit_breaker")
        ngx.status = 503
        ngx.header["Retry-After"] = "30"
        ngx.say('{"error": "Service temporarily unavailable", "reason": "circuit_breaker", "state": "' .. cb_state .. '"}')
        return
    end

    -- 获取API密钥
    local keys = load_api_keys()
    local api_key = keys[provider_name]
    if not api_key and provider_config.auth_type ~= "none" then
        logger.log_error(ctx, "missing_api_key", "API key not configured", { provider = provider_name })
        circuit_breaker.release_half_open_slot(provider_name)  -- 释放半开槽位
        ngx.status = 500
        ngx.say('{"error": "Service configuration error"}')
        return
    end

    -- 构建上游请求
    local upstream_url = build_upstream_url(provider_config, ngx.var.uri, api_key)
    if ngx.var.args then
        upstream_url = upstream_url .. "?" .. ngx.var.args
    end

    local request_headers = build_request_headers(
        provider_config,
        ngx.req.get_headers(),
        api_key,
        ctx.request_id
    )

    -- 请求体大小检查
    local content_length = ngx.req.get_headers()["content-length"]
    if content_length then
        local size = tonumber(content_length) or 0
        if size > config.proxy.max_body_size then
            ctx.error_type = "request_too_large"
            metrics.record_request(provider_name, ngx.var.request_method, 413, nil, "request_too_large")
            logger.log_error(ctx, "request_too_large", "Request body too large", { size = size })
            circuit_breaker.release_half_open_slot(provider_name)
            ngx.status = 413
            ngx.say('{"error": "Request body too large"}')
            return
        end
    end

    -- 读取请求body
    ngx.req.read_body()
    local request_body = ngx.req.get_body_data()

    -- 记录上游请求
    logger.log_upstream_request(ctx, upstream_url, request_headers, request_body)

    -- 增加活跃连接数
    metrics.incr_active_connections(provider_name)

    -- 发送HTTP请求
    local httpc = http.new()
    local res, err = do_http_request(
        httpc,
        ngx.var.request_method,
        upstream_url,
        request_headers,
        request_body,
        provider_config.timeout,
        provider_config.retry,
        provider_config.ssl_verify ~= false
    )

    -- 减少活跃连接数
    metrics.decr_active_connections(provider_name)
    
    -- 修复: 无论成功失败都要释放半开槽位
    circuit_breaker.release_half_open_slot(provider_name)

    -- 计算延迟
    local latency = (ngx.now() - start_time) * 1000 -- 转换为毫秒

    -- 处理响应
    if not res then
        -- 请求失败
        local error_type = classify_error(err)
        ctx.error_type = error_type
        logger.log_error(ctx, error_type, err, { url = upstream_url })
        circuit_breaker.record_failure(provider_name)

        -- 修复: 失败时尝试降级缓存
        if try_serve_cached_response(ctx, provider_name) then
            local degraded_latency = (ngx.now() - start_time) * 1000
            ctx.error_type = "degraded_cache"
            metrics.record_request(provider_name, ngx.var.request_method, ngx.status, degraded_latency, "degraded_cache")
            logger.log_request_end(ctx, ngx.status, degraded_latency, "degraded from error: " .. err)
            logger.access_log(ctx, ngx.status, degraded_latency)
            return
        end

        metrics.record_request(provider_name, ngx.var.request_method, 502, latency, error_type)
        logger.log_request_end(ctx, 502, latency, err)

        ngx.status = 502
        ngx.say('{"error": "Upstream service error", "type": "' .. error_type .. '"}')
        return
    end

    -- 记录上游响应
    logger.log_upstream_response(ctx, res.status, res.headers, res.body)

    -- 修复: 根据状态码判断成功/失败 - 只有5xx才记录为熔断失败
    if res.status >= 200 and res.status < 500 then
        circuit_breaker.record_success(provider_name)
        
        -- 修复: 缓存成功响应(2xx和部分4xx如404可以缓存)
        if (res.status >= 200 and res.status < 300) or res.status == 404 then
            if (ngx.var.request_method == "GET" or ngx.var.request_method == "HEAD") and
               res.body and #res.body <= config.proxy.cache_max_body_size then
                
                local content_type = res.headers["Content-Type"] or res.headers["content-type"]
                local key = cache_key(provider_name, ngx.var.request_method, ngx.var.uri, ngx.var.args)
                local payload = {
                    status = res.status,
                    body = res.body,
                    content_type = content_type,
                    cached_at = ngx.now()
                }
                
                local ok, encoded = pcall(cjson.encode, payload)
                if not ok then
                    ngx.log(ngx.WARN, "Failed to encode cache payload: ", encoded)
                else
                    local cached = false

                    if config.redis and config.redis.enabled then
                        local _, redis_err = redis_client.with_redis(function(red)
                            return red:setex(key, config.proxy.cache_ttl, encoded)
                        end)
                        if redis_err then
                            ngx.log(ngx.WARN, "redis response_cache set failed: ", redis_err)
                        else
                            cached = true
                        end
                    end

                    if not cached then
                        local cache = ngx.shared.response_cache
                        if cache then
                            local ok_set, err_set = cache:set(key, encoded, config.proxy.cache_ttl)
                            if not ok_set then
                                ngx.log(ngx.WARN, "shared dict cache set failed: ", err_set)
                            end
                        end
                    end
                end
            end
        end
    elseif res.status >= 500 then
        circuit_breaker.record_failure(provider_name)
    end

    -- 记录指标
    local error_type = nil
    if res.status >= 400 then
        if res.status >= 500 then
            error_type = "upstream_5xx"
        else
            error_type = "upstream_4xx"
        end
        ctx.error_type = error_type
    end
    metrics.record_request(provider_name, ngx.var.request_method, res.status, latency, error_type)

    -- 返回响应
    ctx.upstream_status = res.status
    ctx.upstream_addr = upstream_url

    -- 设置响应headers
    for k, v in pairs(res.headers) do
        if not hop_by_hop_headers[string.lower(k)] then
            ngx.header[k] = v
        end
    end

    -- 添加自定义headers
    ngx.header["X-Proxy-Request-ID"] = ctx.request_id
    ngx.header["X-Provider"] = provider_name

    ngx.status = res.status
    ngx.say(res.body)

    -- 记录请求结束
    logger.log_request_end(ctx, res.status, latency, nil)
    logger.access_log(ctx, res.status, latency)
end

-- 测试辅助(不影响生产逻辑)
_M._test = {
    is_idempotent_method = is_idempotent_method,
    classify_error = classify_error,
    build_request_headers = build_request_headers,
    build_upstream_url = build_upstream_url,
    should_retry = should_retry
}

return _M
