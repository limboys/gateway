# 监控方案设计

## 1. 监控目标

需要能够回答以下关键问题:

1. ✅ 每个 Provider 的请求量是多少？成功率如何？
2. ✅ 请求延迟分布情况？P50/P95/P99 是多少？
3. ✅ 当前有多少活跃连接？
4. ✅ 各类错误（超时、连接失败等）的发生频率？
5. ✅ 各 Provider 的健康状态如何？

## 2. 监控架构

```
┌─────────────────┐
│  API Proxy      │
│  (OpenResty)    │
│                 │
│  ┌───────────┐  │
│  │ Metrics   │  │──┐
│  │ Module    │  │  │
│  └───────────┘  │  │
│        │        │  │
│        ▼        │  │
│  ┌───────────┐  │  │
│  │ Shared    │  │  │
│  │ Dict      │  │  │ HTTP GET /metrics
│  └───────────┘  │  │
└─────────────────┘  │
                     │
                     ▼
              ┌─────────────┐
              │ Prometheus  │
              │  - Scrape   │
              │  - Store    │
              │  - Query    │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │  Grafana    │
              │  Dashboard  │
              └─────────────┘
```

## 2.1 多副本部署与聚合

多副本时每个实例都会暴露独立的 `/metrics`，Prometheus 需要抓取所有实例，并在查询时聚合。

**Prometheus 抓取多实例示例**:

```yaml
scrape_configs:
  - job_name: 'api-proxy'
    static_configs:
      - targets:
          - 'api-proxy-1:8080'
          - 'api-proxy-2:8080'
          - 'api-proxy-3:8080'
```

**聚合查询示例**:

```promql
# 全局 QPS
sum(rate(api_proxy_requests_total[5m]))

# 按 Provider 聚合 QPS
sum by (provider) (rate(api_proxy_requests_total[5m]))

# 忽略实例维度
sum without (instance) (rate(api_proxy_requests_total[5m]))
```

## 3. 指标设计

### 3.1 请求指标 (Request Metrics)

#### 总请求数
```
指标名: api_proxy_requests_total
类型: Counter
标签: provider, method
说明: 每个 Provider 按 HTTP 方法分类的总请求数
```

**用途**:
- 计算 QPS: `rate(api_proxy_requests_total[5m])`
- 按 Provider 统计: `sum by (provider) (api_proxy_requests_total)`
- 按方法统计: `sum by (method) (api_proxy_requests_total)`

#### 成功请求数
```
指标名: api_proxy_requests_success_total
类型: Counter
标签: provider
说明: 成功请求数 (HTTP 2xx)
```

**用途**:
- 计算成功率:
  ```promql
  sum(rate(api_proxy_requests_success_total[5m])) by (provider) /
  sum(rate(api_proxy_requests_total[5m])) by (provider) * 100
  ```

#### 失败请求数
```
指标名: api_proxy_requests_failure_total
类型: Counter
标签: provider
说明: 失败请求数 (HTTP 4xx, 5xx, 超时等)
```

**用途**:
- 计算失败率
- 告警触发条件

#### 按状态码分类
```
指标名: api_proxy_requests_by_status
类型: Counter
标签: provider, method, status
说明: 按 HTTP 状态码分类的请求数
```

**用途**:
- 状态码分布分析
- 识别特定错误模式

### 3.2 延迟指标 (Latency Metrics)

#### 延迟分桶
```
指标名: api_proxy_latency_bucket
类型: Histogram (模拟)
标签: provider, le (less than or equal)
分桶: <10ms, <50ms, <100ms, <500ms, <1000ms, >1000ms
说明: 延迟分布统计
```

**用途**:
- 计算百分位数 (近似):
  ```promql
  # P50: 中位数 (50% 的请求延迟)
  histogram_quantile(0.50, rate(api_proxy_latency_bucket[5m]))
  
  # P95: 95% 的请求延迟
  histogram_quantile(0.95, rate(api_proxy_latency_bucket[5m]))
  
  # P99: 99% 的请求延迟
  histogram_quantile(0.99, rate(api_proxy_latency_bucket[5m]))
  ```

#### 平均延迟
```
指标名: api_proxy_latency_avg_ms
类型: Gauge
标签: provider
说明: 滑动窗口平均延迟 (毫秒)
```

**用途**:
- 实时监控延迟趋势
- 告警阈值判断

**计算方法**:
```lua
avg_latency = total_latency_sum / total_request_count
```

### 3.3 资源指标 (Resource Metrics)

#### 活跃连接数
```
指标名: api_proxy_active_connections
类型: Gauge
标签: provider
说明: 当前与各 Provider 的活跃连接数
```

**用途**:
- 监控连接池使用情况
- 识别连接泄漏
- 容量规划

**更新时机**:
- 建立连接时 +1
- 关闭连接时 -1

### 3.4 错误指标 (Error Metrics)

#### 按错误类型分类
```
指标名: api_proxy_requests_error_total
类型: Counter
标签: provider, error_type
错误类型:
  - timeout: 请求超时
  - connection_refused: 连接被拒绝
  - connect_failure: 连接失败
  - connection_broken: 连接中断
  - ssl_error: SSL/TLS 错误
  - upstream_5xx: 上游 5xx 错误
  - upstream_4xx: 上游 4xx 错误
  - circuit_breaker: 熔断器阻断
  - rate_limit: 限流
  - degraded_cache: 降级缓存响应
  - request_too_large: 请求体过大
```

**用途**:
- 错误类型分析
- 定位故障原因
- 按错误类型告警

### 3.5 缓存指标 (Cache Metrics)

#### 缓存命中统计
```
指标名: api_proxy_cache_hits_total
类型: Counter
标签: provider, cache_type
说明: 缓存命中次数
cache_type: fresh, stale, degraded
```

#### 缓存未命中统计
```
指标名: api_proxy_cache_misses_total
类型: Counter
标签: provider
说明: 缓存未命中次数
```

#### 降级响应统计
```
指标名: api_proxy_degraded_responses_total
类型: Counter
标签: provider, reason
说明: 降级响应次数
reason: circuit_breaker, upstream_error
```

**用途**:
- 缓存效率分析
- 降级频率监控
- 容量规划

### 3.6 健康状态指标

#### Provider 健康状态
```
指标名: api_proxy_provider_health
类型: Gauge
标签: provider, state
值: 1=healthy(closed), 0.5=half_open, 0=unhealthy(open)
说明: Provider 整体健康状态
```

#### 熔断器状态详情
```
指标名: api_proxy_circuit_breaker_state
类型: Gauge
标签: provider
值: 0=closed, 1=open, 2=half_open
说明: 熔断器当前状态
```

#### 熔断器失败计数
```
指标名: api_proxy_circuit_breaker_failures
类型: Gauge
标签: provider
说明: 当前失败计数
```

#### 熔断器半开槽位
```
指标名: api_proxy_circuit_breaker_half_open_slots
类型: Gauge
标签: provider
说明: 半开状态当前占用的槽位数
```

### 3.7 Redis 指标 (可选)

#### Redis 连接状态
```
指标名: api_proxy_redis_connected
类型: Gauge
值: 1=connected, 0=disconnected
说明: Redis 连接状态
```

#### Redis 操作失败
```
指标名: api_proxy_redis_errors_total
类型: Counter
标签: operation
说明: Redis 操作失败次数
operation: get, set, eval, ping
```

## 4. 查询示例 (PromQL)

### 4.1 请求量相关

```promql
# 总 QPS
sum(rate(api_proxy_requests_total[5m]))

# 各 Provider QPS
sum by (provider) (rate(api_proxy_requests_total[5m]))

# 各 Provider 各方法 QPS
sum by (provider, method) (rate(api_proxy_requests_total[5m]))

# Top 5 请求量最大的 Provider
topk(5, sum by (provider) (rate(api_proxy_requests_total[5m])))
```

### 4.2 成功率相关

```promql
# 整体成功率
sum(rate(api_proxy_requests_success_total[5m])) /
sum(rate(api_proxy_requests_total[5m])) * 100

# 各 Provider 成功率
sum by (provider) (rate(api_proxy_requests_success_total[5m])) /
sum by (provider) (rate(api_proxy_requests_total[5m])) * 100

# 成功率低于 95% 的 Provider
(sum by (provider) (rate(api_proxy_requests_success_total[5m])) /
 sum by (provider) (rate(api_proxy_requests_total[5m])) * 100) < 95
```

### 4.3 延迟相关

```promql
# 平均延迟
avg by (provider) (api_proxy_latency_avg_ms)

# P50 延迟 (近似)
histogram_quantile(0.50, 
  sum by (provider, le) (rate(api_proxy_latency_bucket[5m])))

# P95 延迟
histogram_quantile(0.95, 
  sum by (provider, le) (rate(api_proxy_latency_bucket[5m])))

# P99 延迟
histogram_quantile(0.99, 
  sum by (provider, le) (rate(api_proxy_latency_bucket[5m])))

# 延迟趋势 (1小时)
avg_over_time(api_proxy_latency_avg_ms[1h])

# 延迟超过 1s 的请求占比
sum by (provider) (api_proxy_latency_bucket{le=">1000"}) /
sum by (provider) (api_proxy_latency_bucket{le="+Inf"}) * 100
```

### 4.4 连接数相关

```promql
# 各 Provider 活跃连接
api_proxy_active_connections

# 连接数趋势
rate(api_proxy_active_connections[5m])

# 连接数峰值
max_over_time(api_proxy_active_connections[1h])
```

### 4.5 错误分析

```promql
# 错误率
sum(rate(api_proxy_requests_failure_total[5m])) /
sum(rate(api_proxy_requests_total[5m])) * 100

# 各类错误发生频率
sum by (error_type) (rate(api_proxy_requests_error[5m]))

# 超时错误占比
sum(rate(api_proxy_requests_error{error_type="timeout"}[5m])) /
sum(rate(api_proxy_requests_total[5m])) * 100

# 熔断触发次数
sum(increase(api_proxy_requests_error{error_type="circuit_breaker"}[1h]))
```

### 4.6 健康状态

```promql
# 熔断状态 (1=打开, 0=关闭)
api_proxy_circuit_breaker_state == 1

# 半开状态的 Provider
api_proxy_circuit_breaker_state == 2

# 失败次数接近阈值
api_proxy_circuit_breaker_failures > 3

# Provider 整体健康状态
api_proxy_provider_health < 1

# 不健康的 Provider 列表
api_proxy_provider_health{state="open"}
```

### 4.7 缓存分析

```promql
# 缓存命中率
sum(rate(api_proxy_cache_hits_total[5m])) /
(sum(rate(api_proxy_cache_hits_total[5m])) + 
 sum(rate(api_proxy_cache_misses_total[5m]))) * 100

# 各 Provider 缓存命中率
sum by (provider) (rate(api_proxy_cache_hits_total[5m])) /
(sum by (provider) (rate(api_proxy_cache_hits_total[5m])) + 
 sum by (provider) (rate(api_proxy_cache_misses_total[5m]))) * 100

# 降级响应率
sum(rate(api_proxy_degraded_responses_total[5m])) /
sum(rate(api_proxy_requests_total[5m])) * 100

# 降级原因分布
sum by (reason) (rate(api_proxy_degraded_responses_total[5m]))
```

### 4.8 Redis 监控

```promql
# Redis 连接状态
api_proxy_redis_connected

# Redis 错误率
sum(rate(api_proxy_redis_errors_total[5m]))

# 按操作类型的错误率
sum by (operation) (rate(api_proxy_redis_errors_total[5m]))
```

## 5. Grafana Dashboard 设计

### 5.1 Overview 面板

**Row 1: 核心指标**
- Total QPS (当前/平均/峰值)
- Success Rate (百分比)
- Average Latency (毫秒)
- Active Connections (当前)

**Row 2: Provider 对比**
- QPS by Provider (时间序列图)
- Success Rate by Provider (饼图)
- Latency Distribution (热力图)

**Row 3: 错误分析**
- Error Rate Trend (时间序列)
- Error Type Distribution (柱状图)
- Top Errors (表格)

### 5.2 Performance 面板

**延迟分析**
- P50/P95/P99 Latency (时间序列)
- Latency Heatmap (热力图)
- Latency Distribution by Provider

**资源使用**
- Active Connections by Provider
- Request Queue Length
- Worker CPU/Memory Usage

### 5.3 Reliability 面板

**熔断器监控**
- Circuit Breaker State (状态指示器)
- Failure Count Trend
- Half-Open Slots Usage
- Recovery Events

**限流监控**
- Rate Limit Hit Rate
- Rejected Requests
- Rate Limit by Dimension (Global/Provider/IP)

**缓存监控**
- Cache Hit Rate (时间序列)
- Cache Hit/Miss Ratio (饼图)
- Degraded Response Rate
- Cache Age Distribution

**Redis 监控** (如果启用)
- Redis Connection Status
- Redis Error Rate
- Redis Operations Distribution

### 5.4 Alert 面板

**告警规则**
- High Error Rate (>10% for 5min)
- High Latency (P99 >1s for 5min)
- Circuit Breaker Open
- Service Degradation

## 6. 告警规则

### 6.1 可用性告警

```yaml
# 高错误率
- alert: HighErrorRate
  expr: |
    (sum(rate(api_proxy_requests_failure_total[5m])) by (provider) /
     sum(rate(api_proxy_requests_total[5m])) by (provider)) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "{{ $labels.provider }}: 高错误率 {{ $value | humanizePercentage }}"

# 服务完全不可用
- alert: ServiceDown
  expr: |
    sum(rate(api_proxy_requests_total[5m])) by (provider) == 0
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "{{ $labels.provider }}: 服务无响应"
```

### 6.2 性能告警

```yaml
# 高延迟
- alert: HighLatency
  expr: |
    api_proxy_latency_avg_ms > 1000
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "{{ $labels.provider }}: 平均延迟过高 {{ $value }}ms"

# P99 延迟过高
- alert: HighP99Latency
  expr: |
    histogram_quantile(0.99, 
      rate(api_proxy_latency_bucket[5m])) > 2000
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "P99延迟超过2秒"
```

### 6.3 稳定性告警

```yaml
# 熔断器打开
- alert: CircuitBreakerOpen
  expr: |
    api_proxy_circuit_breaker_state == 1
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "{{ $labels.provider }}: 熔断器已打开"

# 限流频繁触发
- alert: FrequentRateLimiting
  expr: |
    rate(api_proxy_requests_error_total{error_type="rate_limit"}[5m]) > 10
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "限流频繁触发 ({{ $value }}/s)"

# 高降级率
- alert: HighDegradationRate
  expr: |
    sum(rate(api_proxy_degraded_responses_total[5m])) /
    sum(rate(api_proxy_requests_total[5m])) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "降级响应率过高 {{ $value | humanizePercentage }}"

# 缓存命中率过低
- alert: LowCacheHitRate
  expr: |
    sum(rate(api_proxy_cache_hits_total[5m])) /
    (sum(rate(api_proxy_cache_hits_total[5m])) + 
     sum(rate(api_proxy_cache_misses_total[5m]))) < 0.3
  for: 10m
  labels:
    severity: info
  annotations:
    summary: "缓存命中率过低 {{ $value | humanizePercentage }}"

# Redis 连接断开
- alert: RedisDisconnected
  expr: |
    api_proxy_redis_connected == 0
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Redis 连接断开，已降级到本地模式"

# Redis 错误率高
- alert: HighRedisErrorRate
  expr: |
    sum(rate(api_proxy_redis_errors_total[5m])) > 10
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Redis 错误率过高 ({{ $value }}/s)"
```

## 7. 监控数据保留

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# 数据保留策略
storage:
  tsdb:
    retention.time: 15d      # 保留15天
    retention.size: 10GB     # 或 10GB
```

## 8. 监控最佳实践

### 8.1 指标命名规范

- 使用下划线分隔: `api_proxy_requests_total`
- 后缀表示类型: `_total` (counter), `_count` (counter)
- 单位作为后缀: `_ms`, `_bytes`, `_seconds`

### 8.2 标签使用

- 避免高基数标签 (如 request_id, timestamp)
- 使用有意义的标签值
- 标签数量控制在 3-5 个

### 8.3 查询优化

- 使用 `rate()` 而不是 `irate()` 计算速率
- 合理选择时间窗口 (通常 5m)
- 使用 `sum by` 聚合减少序列数

### 8.4 告警策略

- 设置合理的 `for` 持续时间避免抖动
- 使用分级告警 (warning/critical)
- 告警消息包含足够的上下文信息

## 9. 扩展方案

### 9.1 分布式追踪

集成 OpenTelemetry 实现全链路追踪:
- 为每个请求生成 trace_id
- 记录关键操作的 span
- 导出到 Jaeger/Zipkin

### 9.2 实时日志分析

集成 ELK Stack:
- Filebeat 采集日志
- Logstash 处理和转换
- Elasticsearch 存储
- Kibana 可视化

### 9.3 自定义指标

根据业务需求添加:
- API 调用成本统计
- 数据传输量统计
- 缓存命中率
- 特定错误码统计

## 10. 监控检查清单

### 基础监控
- [x] 请求量监控 (QPS, 按 Provider/Method 分类)
- [x] 成功率监控 (整体和分 Provider)
- [x] 延迟监控 (平均值和百分位数 P50/P95/P99)
- [x] 活跃连接监控
- [x] 错误类型统计（12种错误类型）
- [x] HTTP 状态码分布

### 稳定性监控
- [x] 熔断器状态监控（closed/open/half_open）
- [x] 熔断器失败计数
- [x] 半开状态槽位使用情况
- [x] 限流事件监控（三级限流）
- [x] Provider 健康状态

### 缓存监控
- [x] 缓存命中率统计
- [x] 缓存命中/未命中计数
- [x] 降级响应统计（按原因分类）
- [x] 缓存年龄分布

### Redis 监控（可选）
- [x] Redis 连接状态
- [x] Redis 操作错误率
- [x] Redis 降级事件

### 系统监控
- [x] Prometheus 集成
- [x] Grafana Dashboard（4个面板）
- [x] 告警规则配置（8个告警）
- [x] 日志结构化（JSON格式）
- [x] 健康检查端点 (/health, /metrics, /status)

### 可观测性
- [x] 请求 ID 追踪
- [x] 结构化日志（6种事件类型）
- [x] 敏感信息脱敏
- [x] 上游请求/响应日志
