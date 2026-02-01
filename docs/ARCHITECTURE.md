# API 代理服务架构设计文档

## 1. 架构概述

### 1.1 整体架构

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │ HTTP/HTTPS
       ▼
┌──────────────────────────────────────────┐
│         OpenResty (Nginx + Lua)          │
│  ┌────────────────────────────────────┐  │
│  │     Request Processing Pipeline     │  │
│  │  1. Rate Limiting                   │  │
│  │  2. Circuit Breaker Check          │  │
│  │  3. Authentication Injection        │  │
│  │  4. Proxy to Upstream              │  │
│  │  5. Response Processing            │  │
│  │  6. Metrics Recording              │  │
│  │  7. Logging                        │  │
│  └────────────────────────────────────┘  │
│                                           │
│  ┌─────────────┐  ┌──────────────────┐  │
│  │ Shared Dict │  │  Lua Modules     │  │
│  │  - Metrics  │  │  - config.lua    │  │
│  │  - Circuit  │  │  - proxy.lua     │  │
│  │  - RateLimit│  │  - logger.lua    │  │
│  │  - Cache    │  │  - metrics.lua   │  │
│  └─────────────┘  │  - circuit_*.lua │  │
│                    │  - rate_*.lua    │  │
│                    │  - redis_*.lua   │  │
│                    └──────────────────┘  │
└───────┬───────────────┬──────────┬───────┘
        │               │          │
        │               │ /metrics │ Redis (可选)
        │               ▼          ▼
        │         ┌──────────────┐ ┌──────────┐
        │         │ Prometheus   │ │  Redis   │
        │         └──────┬───────┘ │ - State  │
        │                │         │ - Cache  │
        │                ▼         │ - Limit  │
        │         ┌──────────────┐ └──────────┘
        │         │   Grafana    │
        │         └──────────────┘
        │
        ▼
┌───────────────────────────────┐
│    Upstream API Services      │
│  ┌─────────┐  ┌────────────┐ │
│  │ Zerion  │  │ CoinGecko  │ │
│  └─────────┘  └────────────┘ │
│  ┌─────────┐                  │
│  │ Alchemy │                  │
│  └─────────┘                  │
└───────────────────────────────┘
```

### 1.2 请求处理流程

```
Client Request
      │
      ▼
┌─────────────────┐
│  Rate Limiter   │ ──► 429 Too Many Requests
└────────┬────────┘
         │ Pass
         ▼
┌─────────────────┐
│Circuit Breaker  │ ──► 503 Service Unavailable
└────────┬────────┘
         │ Allow
         ▼
┌─────────────────┐
│ Router (Prefix) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Auth Injection │
│  - Basic Auth   │
│  - Header Auth  │
│  - URL Auth     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ HTTP Client     │
│ (lua-resty-http)│
└────────┬────────┘
         │
         ▼
    Upstream API
         │
         ▼
┌─────────────────┐
│   Response      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Metrics Update  │
│ - Success/Fail  │
│ - Latency       │
│ - Error Type    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Logging        │
│ - Structured    │
│ - Sanitized     │
└────────┬────────┘
         │
         ▼
   Return to Client
```

### 1.3 技术栈

- **Web Server**: OpenResty (Nginx + LuaJIT)
- **编程语言**: Lua
- **HTTP Client**: lua-resty-http
- **监控**: Prometheus + Grafana
- **容器化**: Docker + Docker Compose
- **日志格式**: JSON (结构化日志)

## 2. 核心模块设计

### 2.1 配置管理模块 (config.lua)

**职责**:
- 管理所有Provider的配置信息
- 加载环境变量中的API密钥
- 提供配置查询接口

**关键配置**:
- Provider信息（upstream、认证方式、超时设置）
- 熔断器参数（失败阈值、恢复阈值、超时时间）
- 限流参数（全局、Provider级别、IP级别）
- 日志参数（最大body大小、敏感字段列表）

### 2.2 代理处理模块 (proxy.lua)

**职责**:
- 处理所有代理请求的核心逻辑
- 协调各个子模块（限流、熔断、认证等）
- 处理请求转发和响应返回
- 实现响应缓存和降级策略

**关键功能**:
- 请求路由匹配
- 认证信息注入（支持Basic Auth、Header、URL三种方式）
- Header过滤和转发
- 请求重试机制（指数退避）
- 错误处理和降级
- 响应缓存（支持本地和 Redis）
- 降级缓存服务（熔断或失败时）

**缓存机制**:
- **缓存对象**: GET/HEAD 请求的成功响应（2xx）和部分 4xx（如404）
- **缓存键**: `cache:{provider}:{method}:{uri}?{args}`
- **缓存内容**: `{status, body, content_type, cached_at}`
- **缓存时长**: 可配置（默认60秒）
- **最大体积**: 256KB（可配置）
- **降级策略**: 
  - 熔断器打开时，优先返回缓存
  - 上游失败时，返回陈旧缓存（最多2倍TTL）
  - 响应带 `X-Degraded: cache` 和 `X-Cache-Age` 头

**重试策略**:
- **幂等方法**: GET、HEAD、PUT、DELETE、OPTIONS 可重试
- **非幂等方法**: POST 不重试（除非明确超时且无响应）
- **指数退避**: `delay * 2^(attempt-1)`，最大2秒
- **可重试错误**: 
  - 连接超时、读取超时
  - 连接失败、连接拒绝
  - HTTP 502、503、504
- **不可重试错误**:
  - SSL 错误
  - HTTP 4xx（客户端错误）
  - 请求体过大

**错误分类**:
- `timeout`: 请求超时
- `connection_refused`: 连接被拒绝
- `connect_failure`: 连接失败
- `ssl_error`: SSL/TLS 错误
- `connection_broken`: 连接中断
- `upstream_4xx`: 上游客户端错误
- `upstream_5xx`: 上游服务器错误
- `circuit_breaker`: 熔断器阻断
- `rate_limit`: 限流
- `degraded_cache`: 降级缓存
- `request_too_large`: 请求体过大

### 2.3 熔断器模块 (circuit_breaker.lua)

**职责**:
- 实现熔断器模式，防止级联故障
- 管理熔断器状态转换
- 提供熔断器统计信息
- 支持本地和 Redis 分布式存储

**状态机设计**:
```
    ┌─────────┐
    │ CLOSED  │ ◄────────┐
    └────┬────┘          │
         │ failures ≥    │ success ≥
         │ threshold     │ threshold
         ▼               │
    ┌─────────┐          │
    │  OPEN   │          │
    └────┬────┘          │
         │ timeout       │
         ▼               │
    ┌─────────┐          │
    │HALF_OPEN│ ─────────┘
    └─────────┘
         │ 释放槽位机制
         ▼
    (请求完成时)
```

**关键参数**:
- `failure_threshold`: 触发熔断的连续失败次数（默认5次）
- `success_threshold`: 半开状态恢复所需成功次数（默认2次）
- `timeout`: 熔断超时时间（默认30秒）
- `half_open_requests`: 半开状态允许的并发请求数（默认3个）

**存储方式**:
- **本地模式**: 使用 `ngx.shared.circuit_breaker`
- **分布式模式**: 使用 Redis + Lua 脚本实现原子操作
  - 优点：支持多实例共享状态
  - 降级：Redis 失败时自动降级到本地模式

**Redis 实现细节**:
- 使用 Lua 脚本保证状态转换的原子性
- 三个关键脚本：
  1. `CB_ALLOW_SCRIPT`: 检查是否放行请求
  2. `CB_RECORD_SUCCESS_SCRIPT`: 记录成功并可能恢复
  3. `CB_RECORD_FAILURE_SCRIPT`: 记录失败并可能熔断
  4. `CB_RELEASE_HALF_OPEN_SCRIPT`: 释放半开状态槽位

**半开状态槽位管理**:
- 半开状态时限制并发请求数，防止雪崩
- 请求开始时占用槽位（`allow_request`）
- 请求完成时释放槽位（`release_half_open_slot`）
- 失败时不释放，成功/超时时释放

### 2.4 限流模块 (rate_limiter.lua)

**职责**:
- 实现多维度限流
- 使用令牌桶算法控制请求速率
- 提供限流统计信息
- 支持本地和 Redis 分布式限流

**限流维度**:
1. **全局限流**: 控制整体QPS（1000 req/s，burst 2000）
2. **Provider限流**: 针对每个Provider单独限流（300-400 req/s）
3. **IP限流**: 防止单个IP滥用（100 req/s per IP）

**算法**: 令牌桶算法（Token Bucket）
- 令牌以固定速率恢复（rate per second）
- 桶容量上限为 burst
- 每个请求消耗一个令牌
- 支持突发流量（burst容量）

**令牌桶实现**:
```lua
-- 计算令牌恢复
elapsed = now - last_time
recovered_tokens = elapsed * rate

-- 更新令牌数（不超过桶容量）
tokens = min(burst, tokens + recovered_tokens)

-- 尝试消费一个令牌
if tokens >= 1 then
    tokens = tokens - 1
    return allow
else
    return deny
end
```

**存储方式**:
- **本地模式**: 使用 `ngx.shared.rate_limit`
  - 格式: `"tokens:last_time"` (浮点数字符串)
  - 过期时间: 60秒
- **分布式模式**: 使用 Redis + Lua 脚本
  - 保证原子性
  - 支持多实例协同限流
  - 降级：Redis 失败时自动降级到本地模式

**Redis 脚本**:
- `RATE_LIMIT_REDIS_SCRIPT`: 原子性的令牌桶操作
  - 输入: key, rate, limit, now, ttl
  - 输出: {allowed, limit, current_used}

### 2.5 监控指标模块 (metrics.lua)

**职责**:
- 收集和存储各类监控指标
- 导出Prometheus格式的指标
- 提供JSON格式的健康状态

**核心指标**:
- `api_proxy_requests_total`: 请求总数（按provider、method分类）
- `api_proxy_requests_success_total`: 成功请求数
- `api_proxy_requests_failure_total`: 失败请求数
- `api_proxy_latency_bucket`: 延迟分桶统计
- `api_proxy_latency_avg_ms`: 平均延迟
- `api_proxy_active_connections`: 活跃连接数
- `api_proxy_requests_by_status`: 按HTTP状态码分类的请求数

### 2.6 日志模块 (logger.lua)

**职责**:
- 生成结构化JSON日志
- 敏感信息脱敏
- 大型body截断
- 请求追踪

**日志类型**:
1. **访问日志**: 记录每个请求的完整信息
2. **错误日志**: 记录所有错误和异常
3. **事件日志**: 记录熔断、限流等重要事件
4. **上游日志**: 记录上游请求和响应

**脱敏规则**:
- Authorization header → `***REDACTED***`
- API Key headers → `***REDACTED***`
- 其他敏感字段可配置

### 2.7 Redis 客户端模块 (redis_client.lua)

**职责**:
- 封装 Redis 连接和操作
- 连接池管理
- 错误处理和重试
- 健康检查

**核心功能**:
- `with_redis(fn)`: 执行 Redis 操作的高阶函数
  - 自动获取连接
  - 执行回调函数
  - 自动归还连接池
  - 统一错误处理
- `health_check()`: Redis 健康检查（PING）
- `pipeline(commands)`: 批量操作支持

**连接池配置**:
- `pool_size`: 连接池大小（默认100）
- `keepalive`: 空闲连接保持时间（默认60秒）
- `timeout`: 操作超时时间（默认1秒）

**错误处理**:
- 连接失败时返回错误信息
- 自动关闭失败的连接
- 使用 pcall 保护操作
- 记录详细的错误日志

**使用示例**:
```lua
local res, err = redis_client.with_redis(function(red)
    return red:get("mykey")
end)

if err then
    ngx.log(ngx.ERR, "Redis error: ", err)
    -- 降级处理
end
```

## 3. Provider配置

### 3.1 Zerion

- **URL前缀**: `/zerion/*`
- **上游地址**: `https://api.zerion.io`
- **认证方式**: Basic Authentication
  - API Key作为username，密码为空
  - 自动编码为 `Authorization: Basic <base64>`
- **超时**: connect=5s, send=10s, read=30s
- **重试**: 2次，间隔100ms

### 3.2 CoinGecko

- **URL前缀**: `/coingecko/*`
- **上游地址**: `https://api.coingecko.com`
- **认证方式**: HTTP Header
  - 添加 `x-cg-pro-api-key: <API_KEY>` header
- **超时**: connect=5s, send=10s, read=30s
- **重试**: 2次，间隔100ms

### 3.3 Alchemy

- **URL前缀**: `/alchemy/*`
- **上游地址**: `https://eth-mainnet.g.alchemy.com`
- **认证方式**: URL路径拼接
  - 请求路径: `/alchemy/v1/method`
  - 转换为: `https://eth-mainnet.g.alchemy.com/v2/<API_KEY>/v1/method`
- **超时**: connect=5s, send=10s, read=30s
- **重试**: 1次，间隔50ms

## 4. 部署架构

### 4.1 容器化部署

```yaml
services:
  api-proxy:
    - OpenResty容器
    - 端口: 8080
    - 挂载配置和日志
    
  prometheus:
    - 监控指标收集
    - 端口: 9090
    - 抓取间隔: 15秒
    
  grafana:
    - 可视化面板
    - 端口: 3000
    - 预配置数据源和Dashboard
```

### 4.2 网络架构

```
Internet ──► Load Balancer ──► API Proxy (8080)
                                    │
                                    ├──► Zerion API
                                    ├──► CoinGecko API
                                    └──► Alchemy API
```

### 4.3 数据持久化

- **日志**: 挂载到宿主机 `./logs` 目录
- **Prometheus数据**: 使用Docker volume
- **Grafana数据**: 使用Docker volume

## 5. 性能优化

### 5.1 连接池

- 使用Nginx upstream的keepalive功能
- 每个upstream保持32个长连接
- 连接超时60秒

### 5.2 内存优化

- Shared Dict大小合理分配
  - metrics: 10MB
  - circuit_breaker: 5MB
  - rate_limit: 10MB
  - response_cache: 50MB（可选，用于本地缓存）
- 日志body截断（最大1KB）
- 缓存响应大小限制（最大256KB）
- 定期清理过期数据
- Redis 连接池复用

### 5.3 并发优化

- Worker进程数: auto（基于CPU核心数）
- 每个worker支持4096并发连接
- 使用epoll事件模型

## 6. 安全设计

### 6.1 API密钥管理

- 通过环境变量注入
- 从不记录到日志（自动脱敏）
- 不在配置文件中硬编码

### 6.2 敏感信息保护

- 所有认证header自动脱敏
- 大型响应body截断
- 访问日志中不记录API密钥

### 6.3 HTTPS支持

- 上游连接支持SSL/TLS
- 可配置SSL验证（生产环境应开启）

## 7. 可扩展性

### 7.1 水平扩展

- 无状态设计，支持多实例部署
- 通过负载均衡器分发流量
- 支持 Redis 分布式状态共享
  - **启用方式**: 设置环境变量 `REDIS_ENABLED=true`
  - **共享状态**: 熔断器状态、限流计数、响应缓存
  - **降级机制**: Redis 失败时自动降级到本地 Shared Dict
  - **优势**: 多实例间共享限流配额、统一熔断决策

**部署模式对比**:

| 模式 | 状态存储 | 适用场景 | 优缺点 |
|------|---------|---------|--------|
| 单机本地 | Shared Dict | 单实例、测试环境 | 简单、无依赖、无法跨实例 |
| 多机本地 | Shared Dict | 多实例独立运行 | 简单、状态隔离、限流不精确 |
| 多机分布式 | Redis | 多实例协同工作 | 精确限流、统一熔断、需要 Redis |

### 7.2 新Provider接入

只需在 `config.lua` 中添加配置：

```lua
new_provider = {
    prefix = "/newapi/",
    upstream = "https://api.example.com",
    auth_type = "header",
    auth_header = "x-api-key",
    api_key_env = "NEW_API_KEY",
    timeout = {...},
    retry = {...}
}
```

### 7.3 功能扩展

模块化设计便于添加新功能：
- 请求/响应转换
- 缓存层
- A/B测试
- 请求签名
- 配额管理

## 8. 运维特性

### 8.1 健康检查

- **Endpoint**: `/health`
- **检查项**: 服务可用性
- **Docker健康检查**: 30秒间隔

### 8.2 指标监控

- **Endpoint**: `/metrics`
- **格式**: Prometheus
- **覆盖**: 请求数、成功率、延迟、错误等

### 8.3 状态查询

- **Endpoint**: `/status`
- **内容**: 熔断器状态、限流统计等
- **格式**: JSON

### 8.4 日志分析

结构化JSON日志支持:
- ELK Stack集成
- 按request_id追踪请求
- 多维度查询和分析

## 9. 故障处理

### 9.1 熔断降级

- 连续失败5次触发熔断
- 熔断后返回503
- 30秒后进入半开状态尝试恢复

### 9.2 限流保护

- 超过限流阈值返回429
- 提供Retry-After header
- 分层限流防止单点过载

### 9.3 超时重试

- 可配置超时时间
- 智能重试机制
- 指数退避（可选）

## 10. 已实现特性和改进方向

### 10.1 已实现

✅ **分布式限流**: 使用 Redis 实现跨实例限流（令牌桶算法）
✅ **请求缓存**: 对 GET/HEAD 请求实现响应缓存层
✅ **降级策略**: 熔断或失败时返回陈旧缓存
✅ **分布式熔断**: 使用 Redis Lua 脚本实现原子操作
✅ **指数退避重试**: 智能重试机制，避免雪崩
✅ **精确错误分类**: 详细的错误类型识别和处理
✅ **半开状态优化**: 槽位管理防止并发冲击
✅ **健康检查**: Redis 和服务健康状态监控

### 10.2 未来改进方向

1. **配置热更新**: 支持动态加载配置，无需重启
2. **智能路由**: 基于健康状态的智能路由和负载均衡
3. **熔断器优化**: 
   - 基于错误率而非绝对次数的熔断
   - 自适应阈值调整
   - 按错误类型区分处理
4. **追踪系统**: 集成 OpenTelemetry 进行分布式追踪
5. **缓存优化**:
   - 支持 Cache-Control 头
   - 智能缓存失效
   - 缓存预热
6. **限流增强**:
   - 滑动窗口算法
   - 配额管理（按用户/API Key）
   - 自适应限流（基于系统负载）
7. **安全增强**:
   - 请求签名验证
   - IP 白名单/黑名单
   - DDoS 防护
