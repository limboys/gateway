# 压力测试指南

## 📊 压测配置说明

### 1. 启用压测模式

在 `.env` 文件中设置:

```bash
STRESS_TEST_MODE=true
```

### 2. 压测模式配置差异

#### 正常模式 vs 压测模式

| 配置项 | 正常模式 | 压测模式 | 说明 |
|--------|---------|---------|------|
| **全局限流** | 1000 QPS / 2000 burst | 10000 QPS / 20000 burst | 10倍提升 |
| **单Provider限流** | 300-400 QPS / 500-800 burst | 5000 QPS / 10000 burst | 12-16倍提升 |
| **单IP限流** | 100 QPS / 200 burst | 5000 QPS / 10000 burst | 50倍提升 |
| **熔断阈值** | 5次失败 | 50次失败 | 10倍容忍度 |
| **熔断恢复** | 2次成功 | 3次成功 | 更快恢复 |
| **熔断超时** | 30秒 | 10秒 | 更快重试 |
| **半开请求** | 3个 | 10个 | 更多探测 |

#### Nginx 连接配置

| 配置项 | 值 | 说明 |
|--------|-----|------|
| worker_connections | 8192 | 每个worker最大连接数 |
| keepalive_timeout | 75s | 连接保活时间 |
| keepalive_requests | 1000 | 每连接最大请求数 |
| lua_shared_dict metrics | 20MB | 指标存储 |
| lua_shared_dict rate_limit | 20MB | 限流数据 |
| lua_shared_dict response_cache | 50MB | 响应缓存 |

## 🚀 压测执行

### 基础压测

```bash
# 默认配置: 20并发, 10秒
python3 test/enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only

# 自定义并发和时长
python3 test/enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only \
  --load-concurrency 100 \
  --load-duration 60
```

### 推荐压测场景

#### 场景1: 轻量压测 (验证基本性能)
```bash
python3 test/enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only \
  --load-concurrency 50 \
  --load-duration 30
```

**预期结果:**
- QPS: 1000-2000
- P95延迟: < 100ms
- P99延迟: < 200ms
- 成功率: > 99%

#### 场景2: 中等压测 (模拟生产负载)
```bash
python3 test/enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only \
  --load-concurrency 200 \
  --load-duration 60
```

**预期结果:**
- QPS: 3000-5000
- P95延迟: < 300ms
- P99延迟: < 500ms
- 成功率: > 98%

#### 场景3: 极限压测 (压力测试)
```bash
python3 test/enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only \
  --load-concurrency 500 \
  --load-duration 120
```

**预期结果:**
- QPS: 7000-9000
- P95延迟: < 800ms
- P99延迟: < 1500ms
- 成功率: > 95%

### 生成详细报告

```bash
python3 test/enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only \
  --load-concurrency 100 \
  --load-duration 60 \
  --report results/load-test-$(date +%Y%m%d-%H%M%S).json
```

## 📈 性能指标解读

### 关键指标

1. **QPS (Queries Per Second)**
   - 表示每秒处理的请求数
   - 压测模式目标: > 5000 QPS

2. **延迟百分位 (Latency Percentiles)**
   - **P50**: 50%的请求延迟低于此值
   - **P95**: 95%的请求延迟低于此值 (关键指标)
   - **P99**: 99%的请求延迟低于此值
   - **P999**: 99.9%的请求延迟低于此值 (极限情况)

3. **成功率 (Success Rate)**
   - 200-399状态码的请求占比
   - 目标: > 95%

4. **限流次数 (Rate Limited)**
   - 429状态码的请求数
   - 压测模式应为0 (如果>0,说明限流配置不够)

### 性能基准

| 性能等级 | QPS | P95延迟 | P99延迟 | 成功率 |
|---------|-----|---------|---------|--------|
| **优秀** | > 8000 | < 100ms | < 200ms | > 99% |
| **良好** | 5000-8000 | < 300ms | < 500ms | > 98% |
| **及格** | 3000-5000 | < 500ms | < 800ms | > 95% |
| **需优化** | < 3000 | > 500ms | > 800ms | < 95% |

## 🔍 问题排查

### 问题1: 限流触发 (Rate Limited > 0)

**现象:**
```
Rate Limited: 100 times
```

**解决:**
1. 确认 `STRESS_TEST_MODE=true` 已设置
2. 重启服务使配置生效:
   ```bash
   docker-compose restart api-proxy
   ```
3. 验证配置:
   ```bash
   docker-compose exec api-proxy env | grep STRESS_TEST_MODE
   ```

### 问题2: 高延迟 (P95 > 500ms)

**可能原因:**
1. **上游服务慢**: 检查 mock-upstream 响应时间
2. **资源不足**: 检查 CPU/内存使用率
3. **连接池耗尽**: 增加 `worker_connections`
4. **Redis 瓶颈**: 检查 Redis 性能

**排查命令:**
```bash
# 查看容器资源使用
docker stats

# 查看 OpenResty 日志
docker-compose logs -f api-proxy | grep -E "error|warn"

# 查看 Redis 性能
docker exec -it api-proxy-redis redis-cli -a "Onekey2026!" INFO stats
```

### 问题3: 成功率低 (< 95%)

**可能原因:**
1. **熔断器触发**: 检查熔断器状态
   ```bash
   curl http://localhost:8080/circuit-breaker-stats
   ```
2. **超时**: 增加测试脚本的 `timeout` 参数
3. **上游不稳定**: 检查 mock-upstream 健康状态

### 问题4: QPS 达不到预期

**优化建议:**

1. **增加并发数**:
   ```bash
   --load-concurrency 500  # 或更高
   ```

2. **优化系统参数** (Linux):
   ```bash
   # 增加文件描述符限制
   ulimit -n 65535
   
   # 优化 TCP 参数
   sysctl -w net.ipv4.tcp_tw_reuse=1
   sysctl -w net.ipv4.tcp_fin_timeout=30
   sysctl -w net.core.somaxconn=8192
   ```

3. **增加 worker 进程**:
   编辑 `conf/nginx.conf`:
   ```nginx
   worker_processes 8;  # 或等于CPU核心数
   ```

4. **禁用不必要的功能**:
   - 关闭详细日志
   - 禁用 Prometheus 指标收集 (压测时)

## 🎯 压测最佳实践

### 1. 预热 (Warm-up)

在正式压测前,先运行低并发请求预热缓存:

```bash
# 预热 30 秒
python3 test/enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only \
  --load-concurrency 10 \
  --load-duration 30
```

### 2. 渐进式加压

不要直接上最大并发,逐步增加:

```bash
# 阶段1: 50并发
--load-concurrency 50 --load-duration 60

# 阶段2: 100并发
--load-concurrency 100 --load-duration 60

# 阶段3: 200并发
--load-concurrency 200 --load-duration 60

# 阶段4: 500并发
--load-concurrency 500 --load-duration 60
```

### 3. 监控关键指标

压测期间实时监控:

```bash
# 终端1: 运行压测
python3 test/enhanced_auto_test.py --load-only

# 终端2: 监控资源
watch -n 1 docker stats

# 终端3: 监控日志
docker-compose logs -f api-proxy

# 终端4: 监控指标
watch -n 1 'curl -s http://localhost:8080/metrics | grep -E "requests_total|latency|active_connections"'
```

### 4. 清理环境

每次压测前清理状态:

```bash
# 清空 Redis
docker exec -it api-proxy-redis redis-cli -a "Onekey2026!" FLUSHDB

# 重启服务
docker-compose restart api-proxy

# 等待服务就绪
sleep 5
```

### 5. 结果对比

保存每次压测结果,便于对比:

```bash
mkdir -p results

python3 test/enhanced_auto_test.py \
  --load-only \
  --load-concurrency 100 \
  --load-duration 60 \
  --report results/load-test-baseline-$(date +%Y%m%d-%H%M%S).json
```

## 📝 压测检查清单

压测前确认:

- [ ] `STRESS_TEST_MODE=true` 已设置
- [ ] 服务已重启并生效
- [ ] Redis 数据已清空
- [ ] 系统资源充足 (CPU < 80%, 内存 < 80%)
- [ ] mock-upstream 服务正常运行
- [ ] 网络稳定,无丢包
- [ ] 已关闭不必要的后台服务

压测中监控:

- [ ] QPS 趋势稳定
- [ ] 延迟百分位在预期范围内
- [ ] 无大量错误日志
- [ ] 无熔断器触发
- [ ] 无限流触发
- [ ] CPU/内存使用平稳

压测后分析:

- [ ] 保存完整日志
- [ ] 生成性能报告
- [ ] 记录系统瓶颈
- [ ] 对比历史数据
- [ ] 总结优化建议

## 🔧 高级优化

### 使用专业压测工具

对于更专业的压测,推荐使用:

#### wrk (推荐)

```bash
# 安装
apt-get install wrk  # Debian/Ubuntu
brew install wrk     # macOS

# 基础压测
wrk -t 8 -c 400 -d 60s http://localhost:8080/zerion/test

# 自定义脚本
wrk -t 8 -c 400 -d 60s -s test/wrk-script.lua http://localhost:8080
```

#### Apache Bench

```bash
ab -n 10000 -c 100 http://localhost:8080/zerion/test
```

#### Locust (Python 分布式压测)

```bash
pip install locust
locust -f test/locustfile.py --host=http://localhost:8080
```

### 分布式压测

对于更高负载,使用多台机器:

```bash
# 机器1
python3 test/enhanced_auto_test.py --load-only --load-concurrency 200

# 机器2
python3 test/enhanced_auto_test.py --load-only --load-concurrency 200

# 机器3
python3 test/enhanced_auto_test.py --load-only --load-concurrency 200
```

## 📚 参考资料

- [OpenResty 性能优化](https://openresty.org/en/performance.html)
- [Nginx 配置最佳实践](https://nginx.org/en/docs/)
- [压测工具对比](https://www.nginx.com/blog/performance-testing-tools/)
