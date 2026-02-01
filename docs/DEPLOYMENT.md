# 部署和运维指南

## 1. 快速开始

### 1.1 前置要求

- Docker 20.10+
- Docker Compose 1.29+
- 至少2GB内存
- Linux/MacOS/Windows + WSL2

### 1.2 一键部署

```bash
# 1. 克隆或下载项目
cd openresty-proxy

# 2. 配置API密钥
cp .env.example .env
# 编辑 .env 文件，填入真实的API密钥

# 3. 启动服务
docker-compose up -d

# 4. 检查服务状态
docker-compose ps

# 5. 查看日志
docker-compose logs -f api-proxy

# 6. 健康检查
curl http://localhost:8080/health
```

### 1.3 验证部署

```bash
# 检查健康状态
curl http://localhost:8080/health

# 查看监控指标
curl http://localhost:8080/metrics

# 查看熔断器状态
curl http://localhost:8080/status

# 访问Grafana (默认用户名/密码: admin/admin)
open http://localhost:3000
```

## 2. 配置说明

### 2.1 环境变量配置

创建 `.env` 文件：

```bash
# API Keys
ZERION_API_KEY=your_zerion_api_key_here
COINGECKO_API_KEY=your_coingecko_api_key_here
ALCHEMY_API_KEY=your_alchemy_api_key_here

# Redis 配置 (可选 - 用于分布式部署)
REDIS_ENABLED=false           # 是否启用Redis (默认false)
REDIS_HOST=redis              # Redis主机地址
REDIS_PORT=6379               # Redis端口
REDIS_DB=0                    # Redis数据库编号
REDIS_PASSWORD=               # Redis密码 (可选)
REDIS_TIMEOUT_MS=1000         # Redis操作超时(毫秒)
REDIS_POOL_SIZE=100           # 连接池大小
REDIS_KEEPALIVE_MS=60000      # 空闲连接保持时间(毫秒)
```

**Redis 使用场景**:
- **单实例部署**: 不需要启用 Redis，使用本地 Shared Dict
- **多实例部署**: 建议启用 Redis，实现跨实例的状态共享
  - 分布式限流（精确的全局限流）
  - 分布式熔断（统一的熔断决策）
  - 响应缓存共享
  
**Redis 降级机制**:
- Redis 连接失败时自动降级到本地 Shared Dict
- 不影响服务可用性，只影响多实例间的状态同步

### 2.2 调整限流参数

编辑 `lua/config.lua`:

```lua
rate_limit = {
    global = {
        rate = 1000,    -- 全局QPS
        burst = 2000    -- 突发容量
    },
    per_provider = {
        zerion = { rate = 300, burst = 500 },
        coingecko = { rate = 300, burst = 500 },
        alchemy = { rate = 400, burst = 800 }
    },
    per_ip = {
        rate = 100,     -- 每IP的QPS
        burst = 200
    }
}
```

### 2.3 调整熔断器参数

编辑 `lua/config.lua`:

```lua
circuit_breaker = {
    failure_threshold = 5,      -- 失败次数阈值
    success_threshold = 2,      -- 恢复所需成功次数
    timeout = 30,               -- 熔断超时时间(秒)
    half_open_requests = 3      -- 半开状态允许的请求数
}
```

### 2.4 调整超时和重试

编辑 `lua/config.lua`:

```lua
providers = {
    zerion = {
        -- ...
        timeout = {
            connect = 5000,  -- 连接超时(ms)
            send = 10000,    -- 发送超时(ms)
            read = 30000     -- 读取超时(ms)
        },
        retry = {
            times = 2,       -- 重试次数（使用指数退避）
            delay = 100      -- 基础重试延迟(ms)
        }
    }
}
```

**重试策略说明**:
- 使用指数退避: `delay * 2^(attempt-1)`
- 最大延迟: 2秒
- 只重试幂等方法（GET、HEAD、PUT、DELETE）
- POST 请求不重试（除非明确超时）

### 2.5 配置响应缓存

编辑 `lua/config.lua`:

```lua
proxy = {
    max_body_size = 10 * 1024 * 1024,  -- 最大请求体: 10MB
    cache_ttl = 60,                     -- 缓存TTL: 60秒
    cache_max_body_size = 256 * 1024    -- 最大缓存体积: 256KB
}
```

**缓存配置说明**:
- `cache_ttl`: 正常缓存的生存时间
  - 降级时最多使用 2 * cache_ttl 的陈旧缓存
- `cache_max_body_size`: 限制可缓存的响应大小
  - 避免缓存占用过多内存
  - 超过此大小的响应不会被缓存

**缓存行为**:
- **正常模式**: 缓存 GET/HEAD 请求的 2xx 和 404 响应
- **降级模式**: 
  - 熔断器打开时返回缓存
  - 上游失败时返回陈旧缓存（最多 2 * TTL）
  - 响应带 `X-Degraded: cache` 头

## 3. 监控和告警

### 3.1 访问Grafana

1. 打开浏览器访问 `http://localhost:3000`
2. 使用默认凭据登录: `admin / admin`
3. 导航到 Dashboards → API Proxy Dashboard

### 3.2 关键监控指标

**请求指标**:
- `api_proxy_requests_total`: 总请求数
- `api_proxy_requests_success_total`: 成功请求数
- `api_proxy_requests_failure_total`: 失败请求数
- `api_proxy_requests_by_status`: 按状态码分类

**性能指标**:
- `api_proxy_latency_avg_ms`: 平均延迟
- `api_proxy_latency_p50_ms`: P50 延迟
- `api_proxy_latency_p95_ms`: P95 延迟
- `api_proxy_latency_p99_ms`: P99 延迟
- `api_proxy_latency_bucket`: 延迟分布

**资源指标**:
- `api_proxy_active_connections`: 活跃连接数

**错误指标**:
- `api_proxy_requests_error_total`: 按错误类型分类
  - timeout, connection_refused, connect_failure
  - ssl_error, connection_broken
  - upstream_4xx, upstream_5xx
  - circuit_breaker, rate_limit
  - degraded_cache, request_too_large

**稳定性指标**:
- `api_proxy_provider_health`: Provider 健康状态
- `api_proxy_circuit_breaker_state`: 熔断器状态
- `api_proxy_circuit_breaker_failures`: 失败计数
- `api_proxy_circuit_breaker_half_open_slots`: 半开槽位

**缓存指标** (已实现):
- `api_proxy_cache_hits_total`: 缓存命中数
- `api_proxy_cache_misses_total`: 缓存未命中数
- `api_proxy_degraded_responses_total`: 降级响应数

**Redis 指标** (如果启用):
- `api_proxy_redis_connected`: Redis 连接状态
- `api_proxy_redis_errors_total`: Redis 错误数

### 3.3 告警规则示例

创建 `monitoring/alerts.yml`:

```yaml
groups:
  - name: api_proxy_alerts
    interval: 30s
    rules:
      # 高错误率告警
      - alert: HighErrorRate
        expr: |
          rate(api_proxy_requests_failure_total[5m]) / 
          rate(api_proxy_requests_total[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate detected"
          
      # 高延迟告警
      - alert: HighLatency
        expr: api_proxy_latency_avg_ms > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High latency detected"
          
      # 熔断器打开告警
      - alert: CircuitBreakerOpen
        expr: api_proxy_circuit_breaker_state{state="open"} == 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Circuit breaker opened"
```

## 4. 日志管理

### 4.1 日志位置

```
./logs/
  ├── access.log      # 访问日志(JSON格式)
  └── error.log       # 错误日志
```

### 4.2 查看实时日志

```bash
# 访问日志
tail -f logs/access.log | jq .

# 错误日志
tail -f logs/error.log

# Docker日志
docker-compose logs -f api-proxy
```

### 4.3 日志分析示例

```bash
# 统计各Provider的请求数
cat logs/access.log | jq -r '.provider' | sort | uniq -c

# 查找慢请求 (>1s)
cat logs/access.log | jq 'select(.latency_ms > 1000)'

# 统计状态码分布
cat logs/access.log | jq -r '.status' | sort | uniq -c

# 查找特定request_id的所有日志
grep "request-id-xxx" logs/access.log | jq .
```

### 4.4 日志轮转配置

创建 `logrotate.conf`:

```
/path/to/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 nginx nginx
    postrotate
        docker-compose exec api-proxy nginx -s reopen
    endscript
}
```

## 5. 性能优化

### 5.1 调整Worker进程数

编辑 `conf/nginx.conf`:

```nginx
worker_processes 4;  # 根据CPU核心数调整
worker_connections 8192;  # 增加并发连接数
```

### 5.2 启用HTTP/2

```nginx
server {
    listen 8080 http2;
    # ...
}
```

### 5.3 调整内存限制

编辑 `docker-compose.yml`:

```yaml
services:
  api-proxy:
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M
```

### 5.4 优化连接池

编辑 `conf/nginx.conf`:

```nginx
upstream zerion_upstream {
    server api.zerion.io:443;
    keepalive 64;  # 增加keepalive连接数
    keepalive_timeout 120s;
}
```

## 6. 安全加固

### 6.1 启用HTTPS

```nginx
server {
    listen 443 ssl http2;
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
}
```

### 6.2 添加速率限制

```nginx
limit_req_zone $binary_remote_addr zone=general:10m rate=100r/s;

server {
    location / {
        limit_req zone=general burst=200 nodelay;
    }
}
```

### 6.3 IP白名单

```nginx
geo $allowed_ip {
    default 0;
    10.0.0.0/8 1;
    192.168.0.0/16 1;
}

server {
    if ($allowed_ip = 0) {
        return 403;
    }
}
```

## 7. 故障排查

### 7.1 常见问题

**问题1: 服务无法启动**

```bash
# 检查端口占用
sudo lsof -i :8080

# 检查Docker日志
docker-compose logs api-proxy

# 检查配置语法
docker-compose exec api-proxy nginx -t
```

**问题2: 上游连接失败**

```bash
# 检查DNS解析
docker-compose exec api-proxy nslookup api.zerion.io

# 检查网络连接
docker-compose exec api-proxy ping -c 3 api.zerion.io

# 查看错误日志
tail -f logs/error.log | grep "upstream"
```

**问题3: 性能下降**

```bash
# 检查资源使用
docker stats

# 查看慢请求
curl http://localhost:8080/metrics | grep latency

# 检查熔断器状态
curl http://localhost:8080/status | jq .
```

**问题4: Redis 连接问题**

```bash
# 检查 Redis 是否运行
docker-compose ps redis

# 测试 Redis 连接
docker-compose exec redis redis-cli ping

# 检查 Redis 日志
docker-compose logs redis

# 查看 Redis 连接数
docker-compose exec redis redis-cli info clients

# 手动测试 Redis 操作
docker-compose exec redis redis-cli
> PING
> GET test_key
> SET test_key "test_value"

# 检查代理日志中的 Redis 错误
docker-compose logs api-proxy | grep -i redis
```

**问题5: 缓存未命中率高**

```bash
# 查看缓存指标
curl http://localhost:8080/metrics | grep cache

# 检查缓存配置
docker-compose exec api-proxy cat /usr/local/openresty/nginx/lua/config.lua | grep -A 5 "proxy ="

# 查看降级响应
curl http://localhost:8080/metrics | grep degraded

# 测试缓存行为
curl -v http://localhost:8080/zerion/v1/test
# 第一次请求（缓存未命中）
curl -v http://localhost:8080/zerion/v1/test
# 第二次请求（应该命中缓存，但只缓存成功响应）
```

### 7.2 诊断工具

```bash
# 检查服务健康
curl -v http://localhost:8080/health

# 查看所有指标
curl http://localhost:8080/metrics

# 检查熔断器和限流状态
curl http://localhost:8080/status | jq '.'

# 检查特定 Provider 状态
curl http://localhost:8080/status | jq '.providers.zerion'

# 测试特定Provider
curl -v http://localhost:8080/zerion/v1/test

# 检查缓存命中率
curl http://localhost:8080/metrics | grep -E "(cache_hits|cache_misses)"

# 检查降级响应
curl http://localhost:8080/metrics | grep degraded

# 检查 Redis 状态（如果启用）
curl http://localhost:8080/metrics | grep redis

# 查看错误分布
curl http://localhost:8080/metrics | grep error_type

# 检查延迟百分位数
curl http://localhost:8080/metrics | grep -E "latency_(p50|p95|p99)"

# 模拟熔断测试
for i in {1..10}; do
  curl http://localhost:8080/coingecko/invalid-endpoint
  sleep 1
done
curl http://localhost:8080/status | jq '.providers.coingecko'

# 测试缓存降级
# 1. 先触发熔断
# 2. 然后访问之前成功缓存的端点
curl -v http://localhost:8080/zerion/v1/test
# 检查响应头中的 X-Degraded 和 X-Cache-Age
```

## 8. 备份和恢复

### 8.1 备份配置

```bash
# 备份配置文件
tar czf config-backup-$(date +%Y%m%d).tar.gz \
    conf/ lua/ monitoring/ .env

# 备份数据
docker-compose exec prometheus tar czf - /prometheus > \
    prometheus-backup-$(date +%Y%m%d).tar.gz
```

### 8.2 恢复服务

```bash
# 停止服务
docker-compose down

# 恢复配置
tar xzf config-backup-20260129.tar.gz

# 恢复数据
docker-compose up -d prometheus
docker cp prometheus-backup.tar.gz prometheus:/
docker-compose exec prometheus tar xzf /prometheus-backup.tar.gz

# 重启服务
docker-compose up -d
```

## 9. 扩展部署

### 9.1 多实例部署（带 Redis）

```yaml
# docker-compose.scale.yml
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3

  api-proxy:
    deploy:
      replicas: 3
    environment:
      - REDIS_ENABLED=true
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    depends_on:
      redis:
        condition: service_healthy
      
  nginx-lb:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx-lb.conf:/etc/nginx/nginx.conf
    depends_on:
      - api-proxy

volumes:
  redis_data:
```

**负载均衡配置** (`nginx-lb.conf`):
```nginx
http {
    upstream api_proxy_backend {
        least_conn;
        server api-proxy-1:8080 max_fails=3 fail_timeout=30s;
        server api-proxy-2:8080 max_fails=3 fail_timeout=30s;
        server api-proxy-3:8080 max_fails=3 fail_timeout=30s;
    }

    server {
        listen 80;
        
        location / {
            proxy_pass http://api_proxy_backend;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}
```

### 9.2 Kubernetes部署

```yaml
# redis-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        command: ["redis-server", "--appendonly", "yes"]
        volumeMounts:
        - name: redis-data
          mountPath: /data
      volumes:
      - name: redis-data
        persistentVolumeClaim:
          claimName: redis-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
---
# api-proxy-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-proxy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-proxy
  template:
    metadata:
      labels:
        app: api-proxy
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: api-proxy
        image: api-proxy:latest
        ports:
        - containerPort: 8080
          name: http
        env:
        # API Keys
        - name: ZERION_API_KEY
          valueFrom:
            secretKeyRef:
              name: api-keys
              key: zerion
        - name: COINGECKO_API_KEY
          valueFrom:
            secretKeyRef:
              name: api-keys
              key: coingecko
        - name: ALCHEMY_API_KEY
          valueFrom:
            secretKeyRef:
              name: api-keys
              key: alchemy
        # Redis 配置
        - name: REDIS_ENABLED
          value: "true"
        - name: REDIS_HOST
          value: "redis"
        - name: REDIS_PORT
          value: "6379"
        - name: REDIS_DB
          value: "0"
        - name: REDIS_TIMEOUT_MS
          value: "1000"
        - name: REDIS_POOL_SIZE
          value: "100"
        - name: REDIS_KEEPALIVE_MS
          value: "60000"
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: api-proxy
spec:
  selector:
    app: api-proxy
  ports:
  - port: 80
    targetPort: 8080
  type: LoadBalancer
---
# hpa.yaml (水平自动扩展)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-proxy-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-proxy
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

**创建 Secret**:
```bash
kubectl create secret generic api-keys \
  --from-literal=zerion=your_zerion_key \
  --from-literal=coingecko=your_coingecko_key \
  --from-literal=alchemy=your_alchemy_key
```

## 10. 维护任务清单

### 10.1 日常维护

- [ ] 检查服务健康状态
- [ ] 查看错误日志
- [ ] 监控关键指标
- [ ] 检查磁盘使用率

### 10.2 周期维护

**每周**:
- [ ] 备份配置文件
- [ ] 查看性能趋势
- [ ] 清理旧日志

**每月**:
- [ ] 更新依赖包
- [ ] 检查安全漏洞
- [ ] 性能优化评估

**每季度**:
- [ ] 容量规划
- [ ] 架构评审
- [ ] 灾难恢复演练

## 11. 升级指南

### 11.1 滚动升级

```bash
# 1. 拉取新代码
git pull origin main

# 2. 构建新镜像
docker-compose build

# 3. 滚动更新
docker-compose up -d --no-deps --build api-proxy

# 4. 验证新版本
curl http://localhost:8080/health

# 5. 如有问题，回滚
docker-compose down
docker-compose up -d
```

### 11.2 零停机升级

使用蓝绿部署或者Kubernetes的滚动更新机制。

## 12. 联系和支持

- **问题反馈**: 通过GitHub Issues
- **紧急联系**: 运维团队
- **文档更新**: 及时更新本文档
