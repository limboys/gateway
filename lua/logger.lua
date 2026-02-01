-- logger.lua - 结构化日志模块
local _M = {}
local config = require "config"
local cjson = require "cjson"

-- 脱敏处理
local function sanitize_headers(headers)
    if not headers then
        return {}
    end
    
    local sanitized = {}
    for k, v in pairs(headers) do
        local should_sanitize = false
        for _, sensitive in ipairs(config.logging.sensitive_headers) do
            if string.lower(k) == string.lower(sensitive) then
                should_sanitize = true
                break
            end
        end
        
        if should_sanitize then
            sanitized[k] = "***REDACTED***"
        else
            sanitized[k] = v
        end
    end
    
    return sanitized
end

-- 截断大型body
local function truncate_body(body, max_size)
    if not body then
        return nil
    end
    
    max_size = max_size or config.logging.max_body_size
    if #body <= max_size then
        return body
    end
    
    return string.sub(body, 1, max_size) .. "... (truncated)"
end

-- 生成请求ID
function _M.generate_request_id()
    local random = math.random(10000000, 99999999)
    return string.format("%s-%d-%d", ngx.var.hostname or "unknown", 
                         ngx.now() * 1000, random)
end

-- 记录请求开始
function _M.log_request_start(ctx)
    local log_data = {
        timestamp = ngx.now(),
        request_id = ctx.request_id,
        event = "request_start",
        provider = ctx.provider,
        method = ngx.var.request_method,
        path = ngx.var.uri,
        query = ngx.var.args,
        client_ip = ngx.var.remote_addr,
        user_agent = ngx.var.http_user_agent,
        headers = sanitize_headers(ngx.req.get_headers())
    }
    
    ngx.log(ngx.INFO, "REQUEST_START: ", cjson.encode(log_data))
end

-- 记录请求结束
function _M.log_request_end(ctx, status, latency, error_msg)
    local log_data = {
        timestamp = ngx.now(),
        request_id = ctx.request_id,
        event = "request_end",
        provider = ctx.provider,
        method = ngx.var.request_method,
        path = ngx.var.uri,
        status = status,
        latency_ms = latency,
        upstream_status = ctx.upstream_status,
        upstream_addr = ctx.upstream_addr,
        bytes_sent = ngx.var.bytes_sent,
        bytes_received = ngx.var.request_length
    }
    
    if error_msg then
        log_data.error = error_msg
        log_data.error_type = ctx.error_type
    end
    
    -- 根据状态选择日志级别
    local level = ngx.INFO
    if status >= 500 then
        level = ngx.ERR
    elseif status >= 400 then
        level = ngx.WARN
    end
    
    ngx.log(level, "REQUEST_END: ", cjson.encode(log_data))
end

-- 记录上游请求
function _M.log_upstream_request(ctx, url, headers, body)
    local log_data = {
        timestamp = ngx.now(),
        request_id = ctx.request_id,
        event = "upstream_request",
        provider = ctx.provider,
        url = url,
        headers = sanitize_headers(headers),
        body = truncate_body(body)
    }
    
    ngx.log(ngx.INFO, "UPSTREAM_REQUEST: ", cjson.encode(log_data))
end

-- 记录上游响应
function _M.log_upstream_response(ctx, status, headers, body)
    local log_data = {
        timestamp = ngx.now(),
        request_id = ctx.request_id,
        event = "upstream_response",
        provider = ctx.provider,
        status = status,
        headers = sanitize_headers(headers),
        body = truncate_body(body)
    }
    
    ngx.log(ngx.INFO, "UPSTREAM_RESPONSE: ", cjson.encode(log_data))
end

-- 记录错误
function _M.log_error(ctx, error_type, error_msg, details)
    local log_data = {
        timestamp = ngx.now(),
        request_id = ctx.request_id,
        event = "error",
        provider = ctx.provider,
        error_type = error_type,
        error_message = error_msg,
        details = details
    }
    
    ngx.log(ngx.ERR, "ERROR: ", cjson.encode(log_data))
end

-- 记录熔断事件
function _M.log_circuit_breaker(provider, state, details)
    local log_data = {
        timestamp = ngx.now(),
        event = "circuit_breaker",
        provider = provider,
        state = state,
        details = details
    }
    
    ngx.log(ngx.WARN, "CIRCUIT_BREAKER: ", cjson.encode(log_data))
end

-- 记录限流事件
function _M.log_rate_limit(ctx, limit_type, limit, current)
    local log_data = {
        timestamp = ngx.now(),
        request_id = ctx.request_id,
        event = "rate_limit",
        provider = ctx.provider,
        limit_type = limit_type,
        limit = limit,
        current = current,
        client_ip = ngx.var.remote_addr
    }
    
    ngx.log(ngx.WARN, "RATE_LIMIT: ", cjson.encode(log_data))
end

-- 访问日志 (结构化)
function _M.access_log(ctx, status, latency)
    local log_data = {
        timestamp = ngx.now(),
        request_id = ctx.request_id,
        provider = ctx.provider,
        method = ngx.var.request_method,
        path = ngx.var.uri,
        query = ngx.var.args,
        status = status,
        latency_ms = latency,
        client_ip = ngx.var.remote_addr,
        user_agent = ngx.var.http_user_agent,
        bytes_sent = ngx.var.bytes_sent,
        bytes_received = ngx.var.request_length,
        upstream_addr = ngx.var.upstream_addr,
        upstream_status = ngx.var.upstream_status,
        upstream_response_time = ngx.var.upstream_response_time
    }

    if ctx.error_type then
        log_data.error_type = ctx.error_type
    end
    
    -- 写入访问日志文件 (JSON格式，一行一条)
    ngx.log(ngx.INFO, "ACCESS: ", cjson.encode(log_data))
end

return _M
