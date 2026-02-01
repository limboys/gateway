# 稳定性设计方案

## 1. 概述

本文档详细说明API代理服务的稳定性保障机制，包括熔断、限流、超时重试和降级策略。

## 2. 熔断器设计

### 2.1 熔断器模式

熔断器用于防止级联故障，当某个服务持续出错时快速失败，避免浪费资源。

#### 状态机

```
                失败次数 ≥ threshold
    ┌─────────┐                      ┌─────────┐
    │         │ ────────────────────>│         │
    │ CLOSED  │                      │  OPEN   │
    │ (正常)  │                      │ (熔断)  │
    │         │<──────────┐          │         │
    └────┬────┘           │          └────┬────┘
         │                │               │
         │                │               │ timeout 时间后
         │                │               │
         │ 成功次数       │               ▼
         │ ≥ threshold    │          ┌─────────┐
         │                └──────────│         │
         │ 继续正常工作              │HALF_OPEN│
         │                           │ (半开)  │
         │                           │         │
         └───────────────────────────└─────────┘
                  失败则重新打开
```

### 2.2 配置参数

```lua
circuit_breaker = {
    failure_threshold = 5,      -- 触发熔断的失败次数
    success_threshold = 2,      -- 恢复所需的成功次数
    timeout = 30,               -- 熔断超时时间(秒)
    half_open_requests = 3      -- 半开状态允许的测试请求数
}
```

### 2.3 失败定义

以下情况被视为失败:
- 连接超时
- 读取超时
- 连接失败
- HTTP 5xx 响应
- 网络错误

**不视为失败**:
- HTTP 4xx 响应 (客户端错误)
- HTTP 2xx/3xx 响应

### 2.4 工作流程

#### CLOSED (正常状态)
```
1. 所有请求正常通过
2. 记录失败次数
3. 失败次数 ≥ failure_threshold → 转为 OPEN
4. 成功请求会重置失败计数器
```

#### OPEN (熔断状态)
```
1. 拒绝所有请求，立即返回 503
2. 不访问上游服务
3. 等待 timeout 时间
4. timeout 后 → 转为 HALF_OPEN
```

#### HALF_OPEN (半开状态)
```
1. 允许有限数量的测试请求 (half_open_requests)
2. 其他请求仍被拒绝
3. 如果连续成功 ≥ success_threshold → 转为 CLOSED
4. 如果任意请求失败 → 立即转为 OPEN
```

### 2.5 实现细节

**存储方式**:

**本地模式** (默认):
```lua
-- 使用 ngx.shared.DICT 存储状态
local cache = ngx.shared.circuit_breaker

-- 状态 key
"cb:state:{provider}"           -- 当前状态
"cb:failures:{provider}"        -- 失败计数
"cb:success:{provider}"         -- 成功计数
"cb:last_failure:{provider}"    -- 最后失败时间
"cb:half_open_count:{provider}" -- 半开状态槽位计数
```

**分布式模式** (启用 Redis):
```lua
-- 使用 Redis 存储，支持多实例共享状态
-- 使用 Lua 脚本保证原子性

-- 三个核心脚本
CB_ALLOW_SCRIPT           -- 检查是否放行请求
CB_RECORD_SUCCESS_SCRIPT  -- 记录成功
CB_RECORD_FAILURE_SCRIPT  -- 记录失败
CB_RELEASE_HALF_OPEN_SCRIPT -- 释放半开槽位
```

**半开状态槽位管理**:
```lua
-- 请求流程
1. allow_request() → 占用槽位（如果在半开状态）
2. 执行上游请求
3. release_half_open_slot() → 释放槽位（无论成功失败）
4. record_success/failure() → 记录结果

-- 槽位管理防止问题
- 防止半开状态时过多并发请求
- 失败时不立即释放，等待超时
- 避免"惊群效应"
```

### 2.6 使用示例

```lua
-- 请求前检查
if not circuit_breaker.allow_request(provider) then
    return 503, "Circuit breaker open"
end

-- 请求后记录结果
if success then
    circuit_breaker.record_success(provider)
else
    circuit_breaker.record_failure(provider)
end
```

### 2.7 监控指标

```promql
# 熔断器状态 (0=closed, 1=open, 2=half_open)
api_proxy_circuit_breaker_state{provider="zerion"}

# 当前失败计数
api_proxy_circuit_breaker_failures{provider="zerion"}
```

## 3. 限流设计

### 3.1 限流维度

实现三级限流保护:

```
┌──────────────────┐
│   Global Limit   │  全局限流 (1000 req/s)
└────────┬─────────┘
         │
    ┌────▼────┐
    │Provider │  Provider 限流 (300-400 req/s)
    │  Limit  │
    └────┬────┘
         │
    ┌────▼────┐
    │IP Limit │  IP 限流 (100 req/s)
    └─────────┘
```

### 3.2 限流算法

使用 **漏桶算法** (Token Bucket):

```
令牌桶:
- 固定速率生成令牌 (rate)
- 桶容量 (burst)
- 每个请求消费一个令牌
- 无令牌则拒绝请求
```

### 3.3 配置参数

```lua
rate_limit = {
    -- 全局限流
    global = {
        rate = 1000,    -- 每秒生成 1000 个令牌
        burst = 2000    -- 桶容量 2000
    },
    
    -- Provider 级别限流
    per_provider = {
        zerion = { 
            rate = 300,     -- 每秒 300 请求
            burst = 500     -- 突发容量 500
        },
        coingecko = { 
            rate = 300, 
            burst = 500 
        },
        alchemy = { 
            rate = 400, 
            burst = 800 
        }
    },
    
    -- IP 级别限流
    per_ip = {
        rate = 100,     -- 每个 IP 每秒 100 请求
        burst = 200     -- 突发容量 200
    }
}
```

### 3.4 实现细节

**令牌桶算法** (正确实现):

```lua
-- 令牌桶算法实现
function check_limit(key, rate, burst)
    now = current_time()
    
    -- 获取当前状态: "tokens:last_time"
    local value = get_state(key)
    local tokens = burst          -- 初始满令牌
    local last_time = now
    
    if value then
        tokens, last_time = parse(value)
    end
    
    -- 计算时间流逝
    elapsed = now - last_time
    
    -- 计算令牌恢复 (以 rate 速率恢复)
    recovered = elapsed * rate
    
    -- 更新令牌数 (不超过桶容量)
    tokens = min(burst, tokens + recovered)
    
    -- 尝试消费一个令牌
    if tokens >= 1 then
        tokens = tokens - 1
        save_state(key, format("%.6f:%.6f", tokens, now))
        return true, burst, burst - tokens
    else
        -- 令牌不足，拒绝请求
        return false, burst, burst
    end
end
```

**存储方式**:

**本地模式**:
```lua
-- 使用 ngx.shared.rate_limit
-- 存储格式: "tokens:last_time" (浮点数)
-- 过期时间: 60秒
```

**分布式模式** (Redis):
```lua
-- 使用 Redis + Lua 脚本保证原子性
-- RATE_LIMIT_REDIS_SCRIPT
-- 输入: key, rate, limit(burst), now, ttl
-- 输出: {allowed, limit, current_used}
```

**降级机制**:
- Redis 失败时自动降级到本地限流
- 记录警告日志但不影响服务
- 本地限流仍能提供基本保护

### 3.5 限流顺序

```
请求到达
   │
   ▼
检查全局限流 ─────> 超限 → 429
   │ 通过
   ▼
检查 Provider 限流 ─> 超限 → 429
   │ 通过
   ▼
检查 IP 限流 ────────> 超限 → 429
   │ 通过
   ▼
继续处理
```

### 3.6 响应处理

限流触发时:
- HTTP 状态码: 429 Too Many Requests
- 响应头: `Retry-After: 60`
- 响应体: `{"error": "Rate limit exceeded", "type": "global|provider|ip"}`

### 3.7 分布式限流 (已实现)

**启用方式**:
```bash
# 环境变量配置
REDIS_ENABLED=true
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_DB=0
REDIS_PASSWORD=your_password  # 可选
```

**实现方案**: 令牌桶 + Redis Lua 脚本

```lua
-- RATE_LIMIT_REDIS_SCRIPT
-- 输入参数
KEYS[1] = "ratelimit:{scope}:{identifier}"
ARGV[1] = rate      -- 每秒恢复令牌数
ARGV[2] = limit     -- 桶容量
ARGV[3] = now       -- 当前时间戳
ARGV[4] = ttl       -- 过期时间

-- Redis 中存储
"{tokens}:{last_time}"

-- 脚本逻辑
1. 获取当前状态（tokens, last_time）
2. 计算令牌恢复: recovered = (now - last_time) * rate
3. 更新令牌: tokens = min(limit, tokens + recovered)
4. 尝试消费令牌
5. 返回结果: {allowed, limit, current_used}
```

**优势**:
- **原子性**: Lua 脚本保证操作原子性
- **精确性**: 多实例共享配额，限流更精确
- **一致性**: 所有实例使用同一个计数器
- **容错性**: Redis 失败时自动降级到本地限流

**多实例场景对比**:

| 场景 | 本地限流 | 分布式限流 |
|------|---------|-----------|
| 配置: 1000 req/s | 每个实例 1000 req/s | 全局共享 1000 req/s |
| 3个实例 | 总计 3000 req/s | 总计 1000 req/s |
| 流量分布不均 | 可能某实例过载 | 全局均衡 |
| 网络分区 | 正常工作 | 降级到本地 |

## 4. 超时和重试设计

### 4.1 超时配置

三级超时控制:

```lua
timeout = {
    connect = 5000,  -- 连接超时 5秒
    send = 10000,    -- 发送超时 10秒
    read = 30000     -- 读取超时 30秒
}
```

#### 超时分类

**连接超时 (connect)**:
- 建立 TCP 连接的时间限制
- 较短超时 (5s) 快速发现网络问题

**发送超时 (send)**:
- 发送请求数据的时间限制
- 中等超时 (10s) 适应不同网络条件

**读取超时 (read)**:
- 接收响应数据的时间限制
- 较长超时 (30s) 适应复杂计算

### 4.2 重试策略

#### 重试配置

```lua
retry = {
    times = 2,      -- 重试次数 (总共最多 3 次尝试)
    delay = 100     -- 重试延迟 (毫秒)
}
```

#### 重试条件

**应该重试**:
- 连接超时
- 读取超时
- 连接失败 (connection refused)
- HTTP 502, 503, 504

**不应重试**:
- HTTP 4xx (客户端错误)
- HTTP 500 (服务器内部错误,可能不是临时的)
- 已成功的请求

#### 幂等性考虑

```
GET, HEAD, OPTIONS, PUT, DELETE → 幂等，可以重试
POST → 非幂等，谨慎重试
```

建议:
- GET 请求: 自动重试
- POST 请求: 仅在明确超时且未收到任何响应时重试

### 4.3 退避策略

#### 指数退避 (已实现)

```lua
-- 当前实现: 指数退避
function calculate_backoff(attempt, base_delay)
    -- delay * 2^(attempt-1)，最大 2s
    local backoff = base_delay * math.pow(2, attempt - 1)
    return math.min(backoff, 2)  -- 最多等待2秒
end

-- 配置 base_delay = 100ms
-- attempt 1: 100ms  (100 * 2^0)
-- attempt 2: 200ms  (100 * 2^1)
-- attempt 3: 400ms  (100 * 2^2)
-- attempt 4: 800ms  (100 * 2^3)
-- attempt 5: 1600ms (100 * 2^4)
-- attempt 6+: 2000ms (达到上限)
```

**优势**:
- 给上游服务恢复时间
- 避免立即重试造成的雪崩
- 符合指数退避最佳实践

#### 抖动 (可选扩展)

```lua
-- 添加随机抖动避免惊群
function calculate_delay_with_jitter(attempt, base_delay)
    local backoff = base_delay * math.pow(2, attempt - 1)
    local jitter = math.random(0, 100) / 1000  -- 0-100ms
    return math.min(backoff + jitter, 2)
end
```

### 4.4 重试实现

```lua
function do_http_request_with_retry(url, options, retry_config)
    local attempts = 0
    local max_attempts = (retry_config.times or 0) + 1
    
    while attempts < max_attempts do
        attempts = attempts + 1
        
        local res, err = http_client:request(url, options)
        
        -- 成功
        if res and res.status < 500 then
            return res, nil
        end
        
        -- 检查是否应该重试
        if not should_retry(err, res) then
            return res, err
        end
        
        -- 最后一次尝试，不再重试
        if attempts >= max_attempts then
            return res, err
        end
        
        -- 等待后重试
        ngx.sleep(retry_config.delay / 1000)
    end
end
```

### 4.5 超时监控

```promql
# 超时错误率
sum(rate(api_proxy_requests_error{error_type="timeout"}[5m])) /
sum(rate(api_proxy_requests_total[5m]))

# 重试次数统计
api_proxy_retry_attempts_total
```

## 5. 降级策略

### 5.1 降级场景

当服务出现问题时，采取以下降级措施:

#### 场景 1: 上游服务不可用

```
熔断器打开 → 返回 503
├─ 返回缓存数据 (如果有)
├─ 返回默认值
└─ 快速失败，不阻塞
```

#### 场景 2: 部分功能异常

```
非核心功能降级
├─ 跳过非必要的处理
├─ 简化响应数据
└─ 返回部分数据
```

#### 场景 3: 过载保护

```
限流触发 → 返回 429
├─ 优先保护核心请求
├─ 降级次要功能
└─ 引导用户稍后重试
```

### 5.2 降级级别

#### Level 0: 正常服务
- 所有功能正常
- 完整的请求处理
- 所有监控和日志

#### Level 1: 轻度降级
- 关闭非核心功能
- 减少日志详细程度
- 放宽部分限流

#### Level 2: 中度降级
- 仅保留核心 Provider
- 启用缓存 (即使过期)
- 简化响应数据

#### Level 3: 重度降级
- 只处理白名单请求
- 返回预设的降级响应
- 最小化资源消耗

### 5.3 缓存策略 (已实现)

**响应缓存配置**:
```lua
-- config.lua
proxy = {
    cache_ttl = 60,              -- 缓存TTL: 60秒
    cache_max_body_size = 256KB  -- 最大缓存体积
}
```

**缓存实现**:
```lua
-- 1. 缓存键生成
function cache_key(provider, method, uri, args)
    return "cache:{provider}:{method}:{uri}?{args}"
end

-- 2. 缓存对象
{
    status = 200,
    body = "...",
    content_type = "application/json",
    cached_at = 1706578800.123
}

-- 3. 缓存条件
- 请求方法: GET 或 HEAD
- 响应状态: 2xx 或 404
- 响应大小: <= cache_max_body_size

-- 4. 存储位置
- 优先使用 Redis (如果启用)
- 降级使用 ngx.shared.response_cache
```

**降级缓存流程**:
```lua
function try_serve_cached_response(provider)
    -- 1. 检查请求方法
    if method != "GET" and method != "HEAD" then
        return false
    end
    
    -- 2. 获取缓存
    local cached = get_cache(key)
    if not cached then
        return false
    end
    
    -- 3. 检查缓存新鲜度
    local cache_age = now - cached.cached_at
    local max_stale = cache_ttl * 2  -- 最多2倍TTL
    
    if cache_age > max_stale then
        return false  -- 太旧，不使用
    end
    
    -- 4. 返回降级响应
    ngx.header["X-Degraded"] = "cache"
    ngx.header["X-Cache-Age"] = cache_age
    ngx.status = cached.status
    ngx.say(cached.body)
    return true
end
```

**降级触发场景**:
1. **熔断器打开**: 
   - 先尝试返回缓存
   - 无缓存则返回 503
   
2. **上游请求失败**:
   - 先尝试返回陈旧缓存
   - 无缓存则返回 502
   
3. **缓存响应特征**:
   - `X-Degraded: cache` - 标识降级响应
   - `X-Cache-Age: {seconds}` - 缓存年龄
   - 原始状态码和响应体

### 5.4 降级响应示例

```json
// 正常响应
{
    "data": {...},
    "metadata": {...}
}

// 降级响应
{
    "data": {...},
    "metadata": {
        "degraded": true,
        "reason": "circuit_breaker",
        "cached_at": "2026-01-29T10:00:00Z"
    }
}
```

## 6. 稳定性检查清单

### 6.1 部署前检查

- [ ] 熔断器参数已配置
- [ ] 限流阈值已设置
- [ ] 超时参数已优化
- [ ] 重试策略已验证
- [ ] 降级方案已就绪
- [ ] 监控告警已配置

### 6.2 运行时监控

- [ ] 错误率 < 1%
- [ ] P99 延迟 < 1s
- [ ] 无熔断器打开
- [ ] 限流触发率 < 5%
- [ ] 重试成功率 > 80%
- [ ] 缓存命中率 > 50%

### 6.3 故障演练

- [ ] 上游服务宕机
- [ ] 网络延迟增加
- [ ] 流量突增 10x
- [ ] 部分 Provider 失败
- [ ] 全局限流触发

## 7. 故障处理流程

### 7.1 检测

```
监控系统检测到异常
    │
    ▼
触发告警
    │
    ▼
运维人员介入
```

### 7.2 定位

```
1. 查看 Dashboard
   - 错误率趋势
   - 延迟分布
   - 熔断器状态

2. 检查日志
   - 错误日志
   - 访问日志
   - 上游响应

3. 分析指标
   - Provider 健康状态
   - 网络连接情况
   - 资源使用率
```

### 7.3 处理

```
根据问题类型采取行动:

上游问题:
- 熔断器自动保护
- 切换备用服务
- 联系上游处理

自身问题:
- 检查配置
- 重启服务
- 回滚版本

流量问题:
- 调整限流参数
- 扩容实例
- 启用降级
```

## 8. 最佳实践

### 8.1 参数调优

```lua
-- 根据实际情况调整

-- 高并发场景
rate_limit.global.rate = 5000
rate_limit.global.burst = 10000

-- 低延迟要求
timeout.connect = 2000
timeout.read = 10000

-- 不稳定网络
retry.times = 3
retry.delay = 200
```

### 8.2 监控告警

```yaml
# 关键告警
- 错误率 > 5% 持续 5 分钟
- P99 延迟 > 2s 持续 5 分钟
- 熔断器打开超过 1 分钟
- 限流触发率 > 20%
```

### 8.3 日常维护

```bash
# 每日检查
- 查看错误率趋势
- 检查熔断器历史
- 分析慢请求

# 每周检查
- 回顾限流触发情况
- 分析重试成功率
- 评估超时参数

# 每月检查
- 容量规划
- 参数优化
- 架构评审
```

## 9. 已实现特性和扩展方向

### 9.1 已实现特性

✅ **分布式熔断器**: 
- 使用 Redis Lua 脚本实现
- 支持多实例共享状态
- 半开状态槽位管理

✅ **分布式限流**: 
- Redis + 令牌桶算法
- 精确的跨实例限流
- 自动降级机制

✅ **降级缓存**: 
- 响应缓存（本地/Redis）
- 熔断或失败时自动降级
- 缓存新鲜度检查

✅ **指数退避重试**: 
- 智能重试策略
- 非幂等方法保护
- 错误类型区分

✅ **精确错误分类**:
- 超时、连接失败、SSL 错误等
- 基于错误类型的不同处理策略

### 9.2 未来扩展方向

#### 智能熔断

```lua
-- 基于错误率而不是绝对次数
if error_rate > threshold then
    open_circuit_breaker()
end

-- 自适应阈值（根据历史数据动态调整）
threshold = calculate_dynamic_threshold(history)

-- 分级熔断（按错误类型区分）
if timeout_rate > 50% then
    partial_circuit_break("timeout_only")
end
```

#### 智能限流

```lua
-- 基于系统负载动态调整
if cpu_usage > 80% then
    reduce_rate_limit()
elseif cpu_usage < 50% then
    increase_rate_limit()
end

-- 基于用户/API Key 的配额管理
if user_tier == "premium" then
    rate_limit = 10000
else
    rate_limit = 1000
end
```

#### 预测性维护

```lua
-- 基于趋势预测
if predict_failure(metrics_history) then
    enable_degradation()
    alert_operators()
end

-- 异常检测
if detect_anomaly(latency_pattern) then
    increase_circuit_breaker_sensitivity()
end
```

#### 高级缓存

```lua
-- 支持 Cache-Control
if cache_control.no_cache then
    bypass_cache()
end

-- 缓存预热
on_startup:
    warm_up_cache(critical_endpoints)

-- 智能失效
on_upstream_update:
    invalidate_cache(affected_keys)
```

## 10. 总结

本稳定性方案通过多层防护确保服务可靠性:

1. **熔断器**: 防止级联故障
2. **限流**: 保护服务过载
3. **超时重试**: 处理临时故障
4. **降级**: 保证核心功能

关键指标:
- 可用性: > 99.9%
- 平均延迟: < 100ms
- 错误率: < 1%
- 恢复时间: < 30s
