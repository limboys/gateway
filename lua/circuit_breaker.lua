-- circuit_breaker.lua - 熔断器实现
local _M = {}
local config = require "config"
local redis_client = require "redis_client"

-- 熔断器状态
local CLOSED = "closed"       -- 正常状态
local OPEN = "open"           -- 熔断状态
local HALF_OPEN = "half_open" -- 半开状态

-- 使用shared dict存储熔断器状态
local function get_state_key(provider)
    return "cb:state:" .. provider
end

local function get_failure_key(provider)
    return "cb:failures:" .. provider
end

local function get_success_key(provider)
    return "cb:success:" .. provider
end

local function get_last_failure_key(provider)
    return "cb:last_failure:" .. provider
end

local function get_half_open_key(provider)
    return "cb:half_open_count:" .. provider
end

local function normalize_redis_value(value)
    if value == ngx.null then
        return nil
    end
    return value
end

local function eval_redis(script, keys, ...)
    local args = {...}  -- 在外层函数捕获可变参数
    return redis_client.with_redis(function(red)
        -- 构建完整的参数列表: script, numkeys, keys..., args...
        local eval_args = {script, #keys}
        for i = 1, #keys do
            table.insert(eval_args, keys[i])
        end
        for i = 1, #args do
            table.insert(eval_args, args[i])
        end
        return red:eval(table.unpack(eval_args))
    end)
end

-- 修复: Redis脚本中的类型转换和边界检查
local CB_ALLOW_SCRIPT = [[
local state = redis.call("GET", KEYS[1])
if not state then
    state = "closed"
end
local now = tonumber(ARGV[1])
local timeout = tonumber(ARGV[2])
local half_open_requests = tonumber(ARGV[3])

if state == "closed" then
    return {1, state}
elseif state == "open" then
    local last_failure = tonumber(redis.call("GET", KEYS[4]) or "0")
    if now - last_failure > timeout then
        redis.call("SET", KEYS[1], "half_open")
        redis.call("SET", KEYS[3], "0")
        redis.call("SET", KEYS[5], "0")
        return {1, "half_open"}
    end
    return {0, "open"}
elseif state == "half_open" then
    local count = tonumber(redis.call("GET", KEYS[5]) or "0")
    if count < half_open_requests then
        redis.call("INCR", KEYS[5])
        return {1, "half_open"}
    end
    return {0, "half_open"}
end
return {1, state}
]]

local CB_RECORD_SUCCESS_SCRIPT = [[
local state = redis.call("GET", KEYS[1])
if not state then
    state = "closed"
end
local success_threshold = tonumber(ARGV[1])

if state == "half_open" then
    local success = tonumber(redis.call("INCR", KEYS[3]))
    if success >= success_threshold then
        redis.call("SET", KEYS[1], "closed")
        redis.call("SET", KEYS[2], "0")
        redis.call("SET", KEYS[3], "0")
        redis.call("SET", KEYS[5], "0")
        return {"closed"}
    end
    return {"half_open"}
elseif state == "closed" then
    redis.call("SET", KEYS[2], "0")
    return {"closed"}
end
return {state}
]]

local CB_RECORD_FAILURE_SCRIPT = [[
local state = redis.call("GET", KEYS[1])
if not state then
    state = "closed"
end
local now = tonumber(ARGV[1])
local failure_threshold = tonumber(ARGV[2])

redis.call("SET", KEYS[4], now)

if state == "half_open" then
    redis.call("SET", KEYS[1], "open")
    redis.call("SET", KEYS[5], "0")
    return {"open", 0, "reopen"}
elseif state == "closed" then
    local failures = tonumber(redis.call("INCR", KEYS[2]))
    if failures >= failure_threshold then
        redis.call("SET", KEYS[1], "open")
        return {"open", failures, "open"}
    end
    return {"closed", failures, "closed"}
end
return {state, 0, "unknown"}
]]

-- 修复: 半开状态释放逻辑 - 只在请求完成时调用,而非失败时
local CB_RELEASE_HALF_OPEN_SCRIPT = [[
local state = redis.call("GET", KEYS[1])
if not state then
    state = "closed"
end
if state ~= "half_open" then
    return {state, 0}
end
local current = tonumber(redis.call("GET", KEYS[5]) or "0")
if current > 0 then
    redis.call("DECR", KEYS[5])
    return {state, current - 1}
end
return {state, 0}
]]

-- 获取熔断器状态
function _M.get_state(provider)
    if config.redis and config.redis.enabled then
        local state, err = redis_client.with_redis(function(red)
            local value = red:get(get_state_key(provider))
            return normalize_redis_value(value)
        end)
        if err then
            ngx.log(ngx.WARN, "redis circuit_breaker get_state failed: ", err)
        elseif state then
            return state
        end
    end

    local cache = ngx.shared.circuit_breaker
    if not cache then
        ngx.log(ngx.ERR, "circuit_breaker shared dict not found")
        return CLOSED
    end

    local state = cache:get(get_state_key(provider))
    return state or CLOSED
end

-- 设置熔断器状态
local function set_state(provider, state)
    if config.redis and config.redis.enabled then
        local _, err = redis_client.with_redis(function(red)
            return red:set(get_state_key(provider), state)
        end)
        if not err then
            return
        end
        ngx.log(ngx.WARN, "redis circuit_breaker set_state failed: ", err)
    end

    local cache = ngx.shared.circuit_breaker
    if cache then
        cache:set(get_state_key(provider), state)
    end
end

-- 检查是否应该放行请求
function _M.allow_request(provider)
    if config.redis and config.redis.enabled then
        local cfg = config.circuit_breaker
        local keys = {
            get_state_key(provider),
            get_failure_key(provider),
            get_success_key(provider),
            get_last_failure_key(provider),
            get_half_open_key(provider)
        }
        local res, err = eval_redis(CB_ALLOW_SCRIPT, keys, ngx.now(), cfg.timeout, cfg.half_open_requests)
        if not err and res then
            return tonumber(res[1]) == 1
        end
        ngx.log(ngx.WARN, "redis circuit_breaker allow_request failed: ", err)
    end

    local cache = ngx.shared.circuit_breaker
    if not cache then
        return true
    end

    local state = _M.get_state(provider)
    local cfg = config.circuit_breaker

    if state == CLOSED then
        return true
    elseif state == OPEN then
        -- 检查是否超时,应该进入半开状态
        local last_failure = cache:get(get_last_failure_key(provider)) or 0
        if ngx.now() - last_failure > cfg.timeout then
            set_state(provider, HALF_OPEN)
            cache:set(get_success_key(provider), 0)
            cache:set(get_half_open_key(provider), 0)
            return true
        end
        return false
    elseif state == HALF_OPEN then
        -- 半开状态,限制并发请求数
        local half_open_count = cache:get(get_half_open_key(provider)) or 0
        if half_open_count < cfg.half_open_requests then
            cache:incr(get_half_open_key(provider), 1, 0)
            return true
        end
        return false
    end

    return true
end

-- 记录成功
function _M.record_success(provider)
    if config.redis and config.redis.enabled then
        local cfg = config.circuit_breaker
        local keys = {
            get_state_key(provider),
            get_failure_key(provider),
            get_success_key(provider),
            get_last_failure_key(provider),
            get_half_open_key(provider)
        }
        local res, err = eval_redis(CB_RECORD_SUCCESS_SCRIPT, keys, cfg.success_threshold)
        if not err then
            if res and res[1] == CLOSED then
                ngx.log(ngx.INFO, "Circuit breaker closed for provider: ", provider)
            end
            return
        end
        ngx.log(ngx.WARN, "redis circuit_breaker record_success failed: ", err)
    end

    local cache = ngx.shared.circuit_breaker
    if not cache then
        return
    end

    local state = _M.get_state(provider)
    local cfg = config.circuit_breaker

    if state == HALF_OPEN then
        local success_count = cache:incr(get_success_key(provider), 1, 0)
        if success_count >= cfg.success_threshold then
            -- 恢复正常
            set_state(provider, CLOSED)
            cache:set(get_failure_key(provider), 0)
            cache:set(get_success_key(provider), 0)
            cache:set(get_half_open_key(provider), 0)
            ngx.log(ngx.INFO, "Circuit breaker closed for provider: ", provider)
        end
    elseif state == CLOSED then
        -- 重置失败计数
        cache:set(get_failure_key(provider), 0)
    end
end

-- 记录失败
function _M.record_failure(provider)
    if config.redis and config.redis.enabled then
        local cfg = config.circuit_breaker
        local keys = {
            get_state_key(provider),
            get_failure_key(provider),
            get_success_key(provider),
            get_last_failure_key(provider),
            get_half_open_key(provider)
        }
        local res, err = eval_redis(CB_RECORD_FAILURE_SCRIPT, keys, ngx.now(), cfg.failure_threshold)
        if not err then
            if res and res[1] == OPEN and res[3] == "reopen" then
                ngx.log(ngx.WARN, "Circuit breaker reopened for provider: ", provider)
            elseif res and res[1] == OPEN and res[3] == "open" then
                ngx.log(ngx.WARN, "Circuit breaker opened for provider: ", provider,
                    " failures: ", res[2] or "n/a")
            end
            return
        end
        ngx.log(ngx.WARN, "redis circuit_breaker record_failure failed: ", err)
    end

    local cache = ngx.shared.circuit_breaker
    if not cache then
        return
    end

    local state = _M.get_state(provider)
    local cfg = config.circuit_breaker

    cache:set(get_last_failure_key(provider), ngx.now())

    if state == HALF_OPEN then
        -- 半开状态下失败,重新打开熔断器
        set_state(provider, OPEN)
        cache:set(get_half_open_key(provider), 0)
        ngx.log(ngx.WARN, "Circuit breaker reopened for provider: ", provider)
    elseif state == CLOSED then
        local failures = cache:incr(get_failure_key(provider), 1, 0)
        if failures >= cfg.failure_threshold then
            -- 触发熔断
            set_state(provider, OPEN)
            ngx.log(ngx.WARN, "Circuit breaker opened for provider: ", provider,
                " failures: ", failures)
        end
    end
end

-- 获取熔断器统计信息
function _M.get_stats(provider)
    if config.redis and config.redis.enabled then
        local res, err = redis_client.with_redis(function(red)
            return {
                state = normalize_redis_value(red:get(get_state_key(provider))) or CLOSED,
                failures = tonumber(normalize_redis_value(red:get(get_failure_key(provider)))) or 0,
                success = tonumber(normalize_redis_value(red:get(get_success_key(provider)))) or 0,
                last_failure = tonumber(normalize_redis_value(red:get(get_last_failure_key(provider)))) or 0,
                half_open_inflight = tonumber(normalize_redis_value(red:get(get_half_open_key(provider)))) or 0
            }
        end)
        if not err then
            return res
        end
        ngx.log(ngx.WARN, "redis circuit_breaker get_stats failed: ", err)
    end

    local cache = ngx.shared.circuit_breaker
    if not cache then
        return {
            state = CLOSED,
            failures = 0,
            success = 0,
            last_failure = 0,
            half_open_inflight = 0
        }
    end

    return {
        state = _M.get_state(provider),
        failures = cache:get(get_failure_key(provider)) or 0,
        success = cache:get(get_success_key(provider)) or 0,
        last_failure = cache:get(get_last_failure_key(provider)) or 0,
        half_open_inflight = cache:get(get_half_open_key(provider)) or 0
    }
end

-- 修复: 半开状态释放请求计数 - 确保不会出现负数
function _M.release_half_open_slot(provider)
    if config.redis and config.redis.enabled then
        local keys = {
            get_state_key(provider),
            get_failure_key(provider),
            get_success_key(provider),
            get_last_failure_key(provider),
            get_half_open_key(provider)
        }
        local _, err = eval_redis(CB_RELEASE_HALF_OPEN_SCRIPT, keys)
        if not err then
            return
        end
        ngx.log(ngx.WARN, "redis circuit_breaker release_half_open_slot failed: ", err)
    end

    local cache = ngx.shared.circuit_breaker
    if not cache then
        return
    end

    local state = _M.get_state(provider)
    if state ~= HALF_OPEN then
        return
    end

    local key = get_half_open_key(provider)
    local current = cache:get(key) or 0
    if current > 0 then
        cache:incr(key, -1)
    end
end

return _M
