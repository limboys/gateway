-- rate_limiter.lua - 限流模块
local _M = {}
local config = require "config"
local redis_client = require "redis_client"

-- 使用令牌桶算法实现限流
-- 基于 ngx.shared.DICT 或 Redis 实现

local function get_limit_key(scope, identifier)
    local safe_identifier = identifier or ""
    if ngx and ngx.escape_uri then
        safe_identifier = ngx.escape_uri(safe_identifier)
    else
        safe_identifier = string.gsub(safe_identifier, "[^%w%-_]", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return string.format("ratelimit:%s:%s", scope, safe_identifier)
end

-- 修复: Redis脚本中的令牌桶算法实现
local RATE_LIMIT_REDIS_SCRIPT = [[
local key = KEYS[1]
local rate = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])

local value = redis.call("GET", key)
local tokens = limit
local last_time = now

if value then
    local sep = string.find(value, ":")
    if sep then
        tokens = tonumber(string.sub(value, 1, sep - 1)) or limit
        last_time = tonumber(string.sub(value, sep + 1)) or now
    end
end

-- 计算时间流逝和令牌恢复
local elapsed = now - last_time
local recovered = elapsed * rate

-- 更新令牌数,不超过最大值
tokens = math.min(limit, tokens + recovered)

-- 尝试消费一个令牌
if tokens >= 1 then
    tokens = tokens - 1
    local new_value = string.format("%.6f:%.6f", tokens, now)
    redis.call("SET", key, new_value, "EX", ttl)
    return {1, limit, limit - tokens}
else
    -- 令牌不足,不更新状态
    return {0, limit, limit - tokens}
end
]]

-- 修复: 本地限流实现 - 使用正确的令牌桶算法
local function check_limit_local(key, rate, burst)
    local cache = ngx.shared.rate_limit
    if not cache then
        ngx.log(ngx.WARN, "rate_limit shared dict not found")
        return true, burst, 0 -- 失败时放行
    end

    local limit = burst or rate
    local now = ngx.now()

    -- 尝试获取当前值
    local value = cache:get(key)
    local tokens = limit  -- 初始满令牌
    local last_time = now

    if value then
        -- 解析存储的值: "tokens:last_time"
        local parts = {}
        for part in string.gmatch(value, "[^:]+") do
            table.insert(parts, part)
        end
        if #parts == 2 then
            tokens = tonumber(parts[1]) or limit
            last_time = tonumber(parts[2]) or now
        end
    end

    -- 计算时间流逝和令牌恢复
    local elapsed = now - last_time
    local recovered = elapsed * rate
    
    -- 更新令牌数,不超过最大值
    tokens = math.min(limit, tokens + recovered)

    -- 尝试消费一个令牌
    if tokens >= 1 then
        tokens = tokens - 1
        local new_value = string.format("%.6f:%.6f", tokens, now)
        local ok, err = cache:set(key, new_value, 60) -- 60秒过期
        if not ok then
            ngx.log(ngx.WARN, "Failed to set rate limit: ", err)
        end
        return true, limit, limit - tokens
    else
        -- 令牌不足
        return false, limit, limit
    end
end

local function check_limit_redis(key, rate, burst)
    local limit = burst or rate
    local now = ngx.now()
    local ttl = 60

    local res, err = redis_client.with_redis(function(red)
        return red:eval(RATE_LIMIT_REDIS_SCRIPT, 1, key, rate, limit, now, ttl)
    end)

    if not res then
        ngx.log(ngx.WARN, "redis rate_limit failed: ", err)
        return nil, err
    end

    local allowed = tonumber(res[1]) == 1
    local limit_value = tonumber(res[2]) or limit
    local current = tonumber(res[3]) or 0
    return allowed, limit_value, current
end

local function check_scope(scope, identifier, rate, burst)
    local key = get_limit_key(scope, identifier)
    
    if config.redis and config.redis.enabled then
        local ok, limit, current = check_limit_redis(key, rate, burst)
        if ok == nil then
            -- Redis失败,降级到本地限流
            ngx.log(ngx.WARN, "redis rate_limit failed, falling back to local")
            return check_limit_local(key, rate, burst)
        end
        return ok, limit, current
    end
    
    return check_limit_local(key, rate, burst)
end

-- 全局限流
function _M.check_global()
    local cfg = config.rate_limit.global
    return check_scope("global", "", cfg.rate, cfg.burst)
end

-- Provider 限流
function _M.check_provider(provider)
    local cfg = config.rate_limit.per_provider[provider]
    if not cfg then
        return true, 0, 0
    end
    return check_scope("provider", provider, cfg.rate, cfg.burst)
end

-- IP 限流
function _M.check_ip(ip)
    local cfg = config.rate_limit.per_ip
    return check_scope("ip", ip, cfg.rate, cfg.burst)
end

-- 综合检查
function _M.check(provider, ip)
    -- 检查全局限流
    local ok, limit, current = _M.check_global()
    if not ok then
        return false, "global", limit, current
    end

    -- 检查Provider限流
    ok, limit, current = _M.check_provider(provider)
    if not ok then
        return false, "provider", limit, current
    end

    -- 检查IP限流
    ok, limit, current = _M.check_ip(ip)
    if not ok then
        return false, "ip", limit, current
    end

    return true
end

-- 修复: 获取限流统计 - 添加错误处理
function _M.get_stats(provider)
    local stats = {}
    
    local function parse_value(value)
        if not value then
            return nil
        end
        local parts = {}
        for part in string.gmatch(value, "[^:]+") do
            table.insert(parts, part)
        end
        if #parts == 2 then
            return tonumber(parts[1]) or 0
        end
        return nil
    end

    if config.redis and config.redis.enabled then
        local ok, err = pcall(function()
            local global_key = get_limit_key("global", "")
            local global_value, err1 = redis_client.with_redis(function(red)
                return red:get(global_key)
            end)
            if err1 then
                ngx.log(ngx.WARN, "Failed to get global rate limit stats: ", err1)
            else
                stats.global_current = parse_value(global_value)
            end

            if provider then
                local provider_key = get_limit_key("provider", provider)
                local provider_value, err2 = redis_client.with_redis(function(red)
                    return red:get(provider_key)
                end)
                if err2 then
                    ngx.log(ngx.WARN, "Failed to get provider rate limit stats: ", err2)
                else
                    stats.provider_current = parse_value(provider_value)
                end
            end
        end)
        
        if not ok then
            ngx.log(ngx.ERR, "Error getting rate limit stats: ", err)
        end
        
        return stats
    end

    local cache = ngx.shared.rate_limit
    if not cache then
        return {}
    end

    -- 全局统计
    local global_key = get_limit_key("global", "")
    local global_value = cache:get(global_key)
    stats.global_current = parse_value(global_value)

    -- Provider统计
    if provider then
        local provider_key = get_limit_key("provider", provider)
        local provider_value = cache:get(provider_key)
        stats.provider_current = parse_value(provider_value)
    end

    return stats
end

return _M
