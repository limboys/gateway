-- admin.lua - 管理端点
local _M = {}
local cjson = require "cjson"
local config = require "config"
local circuit_breaker = require "circuit_breaker"
local rate_limiter = require "rate_limiter"
local metrics = require "metrics"

function _M.circuit_breaker_stats()
    local stats = {}
    for provider, _ in pairs(config.providers) do
        stats[provider] = circuit_breaker.get_stats(provider)
    end

    ngx.header["Content-Type"] = "application/json"
    ngx.status = 200
    ngx.say(cjson.encode(stats))
end

function _M.rate_limit_stats()
    local stats = {}
    for provider, _ in pairs(config.providers) do
        stats[provider] = rate_limiter.get_stats(provider)
    end

    ngx.header["Content-Type"] = "application/json"
    ngx.status = 200
    ngx.say(cjson.encode(stats))
end

return _M
