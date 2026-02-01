-- metrics.lua - 监控指标模块
local _M = {}
local config = require "config"
local circuit_breaker = require "circuit_breaker"

-- 使用 prometheus 格式输出指标

-- 初始化指标
function _M.init()
    -- 使用 shared dict 存储指标
    local metrics = ngx.shared.metrics
    if not metrics then
        ngx.log(ngx.ERR, "metrics shared dict not found")
        return
    end
end

-- 记录请求
function _M.record_request(provider, method, status, latency, error_type)
    local metrics = ngx.shared.metrics
    if not metrics then
        return
    end
    
    -- 请求总数
    local key = string.format("requests:total:%s:%s", provider, method)
    metrics:incr(key, 1, 0)
    
    -- 按状态码分类
    local status_key = string.format("requests:status:%s:%s:%d", provider, method, status)
    metrics:incr(status_key, 1, 0)
    
    -- 成功/失败计数
    if status >= 200 and status < 300 then
        metrics:incr("requests:success:" .. provider, 1, 0)
    else
        metrics:incr("requests:failure:" .. provider, 1, 0)
    end
    
    -- 错误类型统计
    if error_type then
        local error_key = string.format("requests:error:%s:%s", provider, error_type)
        metrics:incr(error_key, 1, 0)
    end
    
    -- 延迟统计 (简化版本，使用分桶)
    if latency then
        _M.record_latency(provider, latency)
    end
end

-- 记录延迟
function _M.record_latency(provider, latency_ms)
    local metrics = ngx.shared.metrics
    if not metrics then
        return
    end
    
    -- 延迟分桶: <10ms, <50ms, <100ms, <500ms, <1000ms, >1000ms
    local buckets = {10, 50, 100, 500, 1000}
    local bucket = ">1000"
    
    for _, b in ipairs(buckets) do
        if latency_ms < b then
            bucket = "<" .. b
            break
        end
    end
    
    local key = string.format("latency:%s:%s", provider, bucket)
    metrics:incr(key, 1, 0)
    
    -- 总延迟和请求数，用于计算平均值
    metrics:incr("latency:sum:" .. provider, latency_ms, 0)
    metrics:incr("latency:count:" .. provider, 1, 0)
end

-- 记录活跃连接
function _M.incr_active_connections(provider)
    local metrics = ngx.shared.metrics
    if metrics then
        metrics:incr("active_connections:" .. provider, 1, 0)
    end
end

function _M.decr_active_connections(provider)
    local metrics = ngx.shared.metrics
    if metrics then
        local key = "active_connections:" .. provider
        local current = metrics:get(key) or 0
        if current <= 0 then
            metrics:set(key, 0)
            return
        end
        metrics:incr(key, -1)
    end
end

local function estimate_percentile(metrics, provider, percentile)
    local buckets = {10, 50, 100, 500, 1000}
    local total = 0
    local counts = {}
    for _, b in ipairs(buckets) do
        local key = string.format("latency:%s:<%d", provider, b)
        local count = metrics:get(key) or 0
        total = total + count
        table.insert(counts, {le = b, count = count})
    end
    local gt_key = string.format("latency:%s:>1000", provider)
    local gt_count = metrics:get(gt_key) or 0
    total = total + gt_count
    table.insert(counts, {le = 1000, count = gt_count})

    if total == 0 then
        return nil
    end

    local target = total * percentile
    local cumulative = 0
    for _, entry in ipairs(counts) do
        cumulative = cumulative + entry.count
        if cumulative >= target then
            return entry.le
        end
    end
    return 1000
end

-- 导出 Prometheus 格式的指标
function _M.export_prometheus()
    local metrics = ngx.shared.metrics
    if not metrics then
        return "# metrics shared dict not available\n"
    end
    
    local lines = {}
    table.insert(lines, "# HELP api_proxy_requests_total Total number of requests")
    table.insert(lines, "# TYPE api_proxy_requests_total counter")
    
    -- 遍历所有指标
    local keys = metrics:get_keys(0) -- 获取所有key
    
    for _, key in ipairs(keys) do
        local value = metrics:get(key)
        if value then
            -- 解析key并生成prometheus格式
            if string.match(key, "^requests:total:") then
                local parts = {}
                for part in string.gmatch(key, "[^:]+") do
                    table.insert(parts, part)
                end
                if #parts >= 4 then
                    local provider = parts[3]
                    local method = parts[4]
                    table.insert(lines, string.format(
                        'api_proxy_requests_total{provider="%s",method="%s"} %d',
                        provider, method, value))
                end
            elseif string.match(key, "^requests:status:") then
                local parts = {}
                for part in string.gmatch(key, "[^:]+") do
                    table.insert(parts, part)
                end
                if #parts >= 5 then
                    local provider = parts[3]
                    local method = parts[4]
                    local status = parts[5]
                    table.insert(lines, string.format(
                        'api_proxy_requests_by_status{provider="%s",method="%s",status="%s"} %d',
                        provider, method, status, value))
                end
            elseif string.match(key, "^requests:success:") then
                local provider = string.match(key, "^requests:success:(.+)$")
                table.insert(lines, string.format(
                    'api_proxy_requests_success_total{provider="%s"} %d',
                    provider, value))
            elseif string.match(key, "^requests:failure:") then
                local provider = string.match(key, "^requests:failure:(.+)$")
                table.insert(lines, string.format(
                    'api_proxy_requests_failure_total{provider="%s"} %d',
                    provider, value))
            elseif string.match(key, "^requests:error:") then
                local parts = {}
                for part in string.gmatch(key, "[^:]+") do
                    table.insert(parts, part)
                end
                if #parts >= 4 then
                    local provider = parts[3]
                    local error_type = parts[4]
                    table.insert(lines, string.format(
                        'api_proxy_requests_error_total{provider="%s",error_type="%s"} %d',
                        provider, error_type, value))
                end
            elseif string.match(key, "^latency:") and not string.match(key, ":sum:") and not string.match(key, ":count:") then
                local parts = {}
                for part in string.gmatch(key, "[^:]+") do
                    table.insert(parts, part)
                end
                if #parts >= 3 then
                    local provider = parts[2]
                    local bucket = parts[3]
                    table.insert(lines, string.format(
                        'api_proxy_latency_bucket{provider="%s",le="%s"} %d',
                        provider, bucket, value))
                end
            elseif string.match(key, "^active_connections:") then
                local provider = string.match(key, "^active_connections:(.+)$")
                table.insert(lines, string.format(
                    'api_proxy_active_connections{provider="%s"} %d',
                    provider, value))
            end
        end
    end
    
    -- 添加平均延迟
    table.insert(lines, "# HELP api_proxy_latency_avg_ms Average latency in milliseconds")
    table.insert(lines, "# TYPE api_proxy_latency_avg_ms gauge")
    for _, key in ipairs(keys) do
        if string.match(key, "^latency:sum:") then
            local provider = string.match(key, "^latency:sum:(.+)$")
            local sum = metrics:get(key) or 0
            local count = metrics:get("latency:count:" .. provider) or 1
            local avg = sum / count
            table.insert(lines, string.format(
                'api_proxy_latency_avg_ms{provider="%s"} %.2f',
                provider, avg))
        end
    end

    -- 延迟百分位（基于分桶估算）
    table.insert(lines, "# HELP api_proxy_latency_p50_ms P50 latency in milliseconds")
    table.insert(lines, "# TYPE api_proxy_latency_p50_ms gauge")
    table.insert(lines, "# HELP api_proxy_latency_p95_ms P95 latency in milliseconds")
    table.insert(lines, "# TYPE api_proxy_latency_p95_ms gauge")
    table.insert(lines, "# HELP api_proxy_latency_p99_ms P99 latency in milliseconds")
    table.insert(lines, "# TYPE api_proxy_latency_p99_ms gauge")
    for provider, _ in pairs(config.providers or {}) do
        local p50 = estimate_percentile(metrics, provider, 0.50)
        local p95 = estimate_percentile(metrics, provider, 0.95)
        local p99 = estimate_percentile(metrics, provider, 0.99)
        if p50 then
            table.insert(lines, string.format(
                'api_proxy_latency_p50_ms{provider="%s"} %.2f',
                provider, p50))
            table.insert(lines, string.format(
                'api_proxy_latency_p95_ms{provider="%s"} %.2f',
                provider, p95))
            table.insert(lines, string.format(
                'api_proxy_latency_p99_ms{provider="%s"} %.2f',
                provider, p99))
        end
    end

    -- Provider 健康状态
    table.insert(lines, "# HELP api_proxy_provider_health Provider health status (1=healthy,0.5=half_open,0=unhealthy)")
    table.insert(lines, "# TYPE api_proxy_provider_health gauge")
    for provider, _ in pairs(config.providers or {}) do
        local state = circuit_breaker.get_state(provider)
        local value = 1
        if state == "half_open" then
            value = 0.5
        elseif state == "open" then
            value = 0
        end
        table.insert(lines, string.format(
            'api_proxy_provider_health{provider="%s",state="%s"} %.1f',
            provider, state, value))
    end
    
    return table.concat(lines, "\n") .. "\n"
end

-- 导出JSON格式的指标（用于健康检查）
function _M.export_json()
    local metrics = ngx.shared.metrics
    if not metrics then
        return '{"error": "metrics not available"}'
    end
    
    local cjson = require "cjson"
    local data = {}
    
    local keys = metrics:get_keys(0)
    for _, key in ipairs(keys) do
        local value = metrics:get(key)
        if value then
            data[key] = value
        end
    end
    
    return cjson.encode(data)
end

return _M
