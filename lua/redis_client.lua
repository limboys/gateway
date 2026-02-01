-- redis_client.lua - Redis 连接与操作封装
local _M = {}
local config = require "config"

-- 修复: 添加连接获取的错误处理和重试
local function get_redis()
    local cfg = config.redis
    if not cfg or not cfg.enabled then
        return nil, "redis disabled"
    end

    local redis = require "resty.redis"
    local red = redis:new()
    
    -- 设置超时
    red:set_timeout(cfg.timeout or 1000)

    -- 连接Redis
    local ok, err = red:connect(cfg.host or "127.0.0.1", cfg.port or 6379)
    if not ok then
        return nil, "failed to connect: " .. (err or "unknown error")
    end

    -- 认证
    if cfg.password and cfg.password ~= "" then
        local ok_auth, err_auth = red:auth(cfg.password)
        if not ok_auth then
            red:close()
            return nil, "failed to auth: " .. (err_auth or "unknown error")
        end
    end

    -- 选择数据库
    if cfg.db and cfg.db > 0 then
        local ok_db, err_db = red:select(cfg.db)
        if not ok_db then
            red:close()
            return nil, "failed to select db: " .. (err_db or "unknown error")
        end
    end

    return red, nil
end

-- 修复: 改进连接池管理
local function keepalive(red)
    if not red then
        return
    end
    
    local cfg = config.redis or {}
    local pool_size = cfg.pool_size or 100
    local keepalive_time = cfg.keepalive or 60000
    
    local ok, err = red:set_keepalive(keepalive_time, pool_size)
    if not ok then
        ngx.log(ngx.WARN, "Failed to set keepalive: ", err)
        red:close()
    end
end

-- 修复: 添加更好的错误处理和日志
function _M.with_redis(fn)
    if not fn then
        return nil, "callback function required"
    end
    
    local red, err = get_redis()
    if not red then
        return nil, err
    end

    -- 执行回调函数
    local ok, res1, res2, res3 = pcall(fn, red)
    
    -- 无论成功失败,都要归还连接
    keepalive(red)

    if not ok then
        -- pcall失败,res1是错误消息
        ngx.log(ngx.ERR, "Redis operation failed: ", res1)
        return nil, res1
    end

    -- 返回回调函数的结果
    return res1, res2, res3
end

-- 修复: 添加Redis健康检查
function _M.health_check()
    return _M.with_redis(function(red)
        local res, err = red:ping()
        if not res then
            return false, err
        end
        return res == "PONG", nil
    end)
end

-- 修复: 添加批量操作支持
function _M.pipeline(commands)
    if not commands or #commands == 0 then
        return nil, "commands required"
    end
    
    return _M.with_redis(function(red)
        red:init_pipeline()
        
        for _, cmd in ipairs(commands) do
            local method = cmd[1]
            local args = {}
            for i = 2, #cmd do
                table.insert(args, cmd[i])
            end
            red[method](red, unpack(args))
        end
        
        local results, err = red:commit_pipeline()
        if not results then
            return nil, err
        end
        
        return results, nil
    end)
end

return _M
