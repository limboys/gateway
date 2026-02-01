-- config.lua - 配置管理模块
local _M = {}

-- 环境变量辅助函数
local function env_string(name, default)
    local value = os.getenv(name)
    if not value or value == "" then
        return default
    end
    return value
end

local function env_number(name, default)
    local value = os.getenv(name)
    if not value or value == "" then
        return default
    end
    local num = tonumber(value)
    if not num then
        ngx.log(ngx.WARN, "Invalid number for env var ", name, ": ", value, ", using default: ", default)
        return default
    end
    return num
end

local function env_bool(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    value = string.lower(value)
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

local STRESS_TEST_MODE = env_bool("STRESS_TEST_MODE", false)

-- Provider 配置
_M.providers = {
    zerion = {
        prefix = "/zerion/",
        -- upstream = "https://api.zerion.io", -- 备份：真实上游
        upstream = "http://mock-upstream",
        auth_type = "basic",
        api_key_env = "ZERION_API_KEY",
        ssl_verify = true,
        timeout = {
            connect = 5000, -- 5s
            send = 10000,   -- 10s
            read = 30000    -- 30s
        },
        retry = {
            times = 2,
            delay = 100 -- ms
        }
    },
    coingecko = {
        prefix = "/coingecko/",
        -- upstream = "https://api.coingecko.com", -- 备份：真实上游
        upstream = "http://mock-upstream",
        auth_type = "header",
        auth_header = "x-cg-pro-api-key",
        api_key_env = "COINGECKO_API_KEY",
        ssl_verify = true,
        timeout = {
            connect = 5000,
            send = 10000,
            read = 30000
        },
        retry = {
            times = 2,
            delay = 100
        }
    },
    alchemy = {
        prefix = "/alchemy/",
        -- upstream = "https://eth-mainnet.g.alchemy.com", -- 备份：真实上游
        upstream = "http://mock-upstream",
        auth_type = "url",
        api_key_env = "ALCHEMY_API_KEY",
        ssl_verify = true,
        timeout = {
            connect = 5000,
            send = 10000,
            read = 30000
        },
        retry = {
            times = 1,
            delay = 50
        }
    }
}

-- 熔断器配置
_M.circuit_breaker = {
    failure_threshold = 5, -- 失败次数阈值
    success_threshold = 2, -- 恢复所需成功次数
    timeout = 30,          -- 熔断超时时间(秒)
    half_open_requests = 3 -- 半开状态允许的请求数
}

-- 限流配置
_M.rate_limit = {
    global = {
        rate = 1000, -- 每秒请求数
        burst = 2000 -- 突发容量
    },
    per_provider = {
        zerion = { rate = 300, burst = 500 },
        coingecko = { rate = 300, burst = 500 },
        alchemy = { rate = 400, burst = 800 }
    },
    per_ip = {
        rate = 100, -- 每个IP每秒请求数
        burst = 200
    }
}

-- 日志配置
_M.logging = {
    max_body_size = 1024, -- 记录的最大body大小(bytes)
    sensitive_headers = { -- 需要脱敏的headers
        "authorization",
        "x-api-key",
        "x-cg-pro-api-key"
    }
}

-- 监控配置
_M.metrics = {
    enabled = true,
    endpoint = "/metrics"
}

-- Redis 配置(分布式状态)
_M.redis = {
    enabled = env_bool("REDIS_ENABLED", false),
    host = env_string("REDIS_HOST", "redis"),
    port = env_number("REDIS_PORT", 6379),
    db = env_number("REDIS_DB", 0),
    password = env_string("REDIS_PASSWORD", ""),
    timeout = env_number("REDIS_TIMEOUT_MS", 1000),
    pool_size = env_number("REDIS_POOL_SIZE", 100),
    keepalive = env_number("REDIS_KEEPALIVE_MS", 60000)
}

-- 代理配置
_M.proxy = {
    max_body_size = 10 * 1024 * 1024, -- 10MB
    cache_ttl = 60,                    -- 缓存TTL(秒)
    cache_max_body_size = 256 * 1024   -- 最大可缓存响应体大小(256KB)
}

-- 压测模式：放大阈值以减少压测干扰
if STRESS_TEST_MODE then
    -- 限流大幅提升,支持高并发压测
    _M.rate_limit.global = { rate = 10000, burst = 20000 }
    _M.rate_limit.per_provider = {
        zerion = { rate = 5000, burst = 10000 },
        coingecko = { rate = 5000, burst = 10000 },
        alchemy = { rate = 5000, burst = 10000 }
    }
    _M.rate_limit.per_ip = { rate = 5000, burst = 10000 }  -- 压测时不限制单IP

    -- 熔断器更宽松,避免压测触发
    _M.circuit_breaker.failure_threshold = 50  -- 提高到50次
    _M.circuit_breaker.success_threshold = 3   -- 降低恢复要求
    _M.circuit_breaker.timeout = 10            -- 缩短超时时间,快速恢复
    _M.circuit_breaker.half_open_requests = 10 -- 增加探测请求数
    
    ngx.log(ngx.WARN, "⚡ STRESS_TEST_MODE enabled: rate limits and circuit breaker relaxed")
end

-- 从环境变量加载API密钥
function _M.load_api_keys()
    local keys = {}
    for name, provider_config in pairs(_M.providers) do
        local key = nil
        
        -- 修复: 优先从ngx.var读取,因为nginx.conf中已经声明了env
        if ngx and ngx.var then
            key = ngx.var[provider_config.api_key_env]
        end
        
        -- 如果ngx.var没有,尝试从os.getenv读取
        if not key or key == "" then
            key = os.getenv(provider_config.api_key_env)
        end
        
        if key and key ~= "" then
            keys[name] = key
        else
            -- 修复: 只在需要认证时才警告
            if provider_config.auth_type ~= "none" then
                ngx.log(ngx.WARN, "API key not found for provider: ", name, 
                       " (env: ", provider_config.api_key_env, ")")
            end
        end
    end
    return keys
end

-- 获取Provider配置
function _M.get_provider(path)
    if not path then
        return nil, nil
    end
    
    for name, provider_config in pairs(_M.providers) do
        local prefix = provider_config.prefix
        
        -- 修复: 支持带或不带尾部斜杠的匹配
        local prefix_no_slash = prefix
        if string.sub(prefix, -1) == "/" then
            prefix_no_slash = string.sub(prefix, 1, -2)
        end
        
        -- 检查路径是否匹配前缀
        if string.sub(path, 1, #prefix) == prefix or path == prefix_no_slash then
            return name, provider_config
        end
    end
    
    return nil, nil
end

-- 修复: 添加配置验证函数
function _M.validate()
    local errors = {}
    
    -- 验证Provider配置
    for name, provider_config in pairs(_M.providers) do
        if not provider_config.upstream then
            table.insert(errors, "Provider " .. name .. " missing upstream")
        end
        if not provider_config.prefix then
            table.insert(errors, "Provider " .. name .. " missing prefix")
        end
        if not provider_config.auth_type then
            table.insert(errors, "Provider " .. name .. " missing auth_type")
        end
    end
    
    -- 验证熔断器配置
    if _M.circuit_breaker.failure_threshold < 1 then
        table.insert(errors, "circuit_breaker.failure_threshold must be >= 1")
    end
    if _M.circuit_breaker.success_threshold < 1 then
        table.insert(errors, "circuit_breaker.success_threshold must be >= 1")
    end
    if _M.circuit_breaker.timeout < 1 then
        table.insert(errors, "circuit_breaker.timeout must be >= 1")
    end
    
    -- 验证限流配置
    if _M.rate_limit.global.rate < 1 then
        table.insert(errors, "rate_limit.global.rate must be >= 1")
    end
    
    if #errors > 0 then
        return false, errors
    end
    
    return true, nil
end

return _M
