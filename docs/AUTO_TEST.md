# 测试脚本使用指南

---

## 🚀 快速开始

### 1. 脚本使用

```bash
# 快速模式(跳过耗时测试)
python3 enhanced_auto_test.py --base-url http://localhost:8080 --quick

# 基础测试(不含熔断/压测)
python3 enhanced_auto_test.py --base-url http://localhost:8080

# 完整测试(包含熔断器和压力测试)
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --circuit-breaker \
  --load-test \
  --report full-test-report.json

# 仅压力测试 压测请移步到LOAD_TEST.md
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-only \
  --load-concurrency 20 \
  --load-duration 10

# 仅限流测试
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --rate-limit-only

# 仅熔断测试
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --circuit-breaker-only

# 测试特定 Provider
python3 enhanced_auto_test.py --provider coingecko

# 自定义压测参数(用于完整测试)
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --load-test \
  --load-concurrency 50 \
  --load-duration 20

# 熔断测试前等待限流窗口恢复(默认 60s)
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --circuit-breaker \
  --rate-limit-cooldown 60

# 失败时立即退出
python3 enhanced_auto_test.py --exit-on-fail

# 生成报告
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --report report.json
```

---

## 📊 脚本测试

### 1. HTTP 方法测试

**测试内容**:
- GET 请求
- POST 请求(带 Body)
- PUT 请求(带 Body)
- DELETE 请求
- HEAD 请求

**示例输出**:
```
✅ [OK] HTTP GET method
✅ [OK] HTTP POST method
✅ [OK] HTTP PUT method
✅ [OK] HTTP DELETE method
✅ [OK] HTTP HEAD method
```

---

### 2. 认证和 Header 测试

**测试内容**:
- 追踪 Header (X-Proxy-Request-ID)
- Provider Header (X-Provider)
- 认证信息注入验证


**示例输出**:
```
✅ [OK] Authentication and headers
```

---

### 3. 熔断器完整状态机测试

**测试流程**:
```
CLOSED (初始) 
    ↓ 触发5次失败
OPEN (熔断打开)
    ↓ 等待30秒超时
HALF_OPEN (半开探测)
    ↓ 发送2次成功请求
CLOSED (恢复正常)
```

**示例输出**:
```
✅ [OK] Testing circuit breaker: triggering failures...
✅ [OK] Circuit breaker: CLOSED → OPEN
✅ [OK] Waiting for circuit breaker timeout (30s)...
✅ [OK] Circuit breaker: OPEN → HALF_OPEN
✅ [OK] Sending successful requests to close circuit breaker...
✅ [OK] Circuit breaker: HALF_OPEN → CLOSED
```

**注意**: 这个测试需要约 60 秒,使用 `--circuit-breaker` 参数启用

---

### 4. 多 Provider 测试

**测试内容**:
- Zerion
- CoinGecko
- Alchemy

**示例输出**:
```
✅ [OK] Provider: zerion
✅ [OK] Provider: coingecko
✅ [OK] Provider: alchemy
```

---

### 5. 缓存验证测试

**测试内容**:
- 正常缓存(连续请求一致性)
- 降级缓存(熔断时)


**示例输出**:
```
✅ [OK] Caching (responses consistent)
✅ [OK] Circuit breaker degradation with cache
```

---

### 6. 增强的限流测试

**测试内容**:
- 发送 150 个请求
- 统计 429 响应数量
- 计算限流比率


**示例输出**:
```
✅ [OK] Testing rate limiting with 150 requests...
✅ [OK] Rate limiting detected (45 / 150 requests limited)
```

---

### 7. 详细的测试报告

**报告格式**:
```json
{
  "total": 20,
  "passed": 18,
  "failed": 2,
  "warnings": 0,
  "pass_rate": "90.00%",
  "details": {
    "health_endpoint": {
      "passed": true,
      "details": {
        "status": 200
      }
    },
    "http_get": {
      "passed": true,
      "details": {
        "status": 200,
        "expected": [200, 404]
      }
    },
    "circuit_breaker_open": {
      "passed": true,
      "details": {}
    },
    "load_test": {
      "passed": true,
      "details": {
        "total": 2340,
        "success": 2295,
        "qps": 234.0,
        "latency": {
          "avg": 85.23,
          "p50": 75.12,
          "p95": 150.45,
          "p99": 200.67
        }
      }
    }
  }
}
```

---

## 🎯 使用场景

### 场景 1: 日常开发测试

**目的**: 快速验证基本功能

**命令**:
```bash
python3 enhanced_auto_test.py --base-url http://localhost:8080
```

**耗时**: ~10 秒

**覆盖**:
- 健康检查
- 监控指标
- HTTP 方法
- 认证
- 多 Provider
- 缓存
- 限流

---

### 场景 2: PR 合并前测试

**目的**: 全面验证功能

**命令**:
```bash
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --circuit-breaker \
  --report pr-test-report.json
```

**耗时**: ~70 秒

**额外覆盖**:
- 熔断器完整状态机
- 降级缓存

---

### 场景 3: 发布前性能测试

**目的**: 压力测试 + 全面验证

**命令**:
```bash
python3 enhanced_auto_test.py \
  --base-url http://localhost:8080 \
  --circuit-breaker \
  --load-test \
  --report release-test-report.json
```

**耗时**: ~80 秒

**额外覆盖**:
- 压力测试
- QPS 统计
- 延迟分布

---

### 场景 4: 生产环境冒烟测试

**目的**: 快速验证部署成功

**命令**:
```bash
python3 enhanced_auto_test.py \
  --base-url https://api-proxy.production.com \
  --exit-on-fail
```

**特点**:
- 遇到第一个失败立即退出
- 快速反馈
- 适合 CI/CD

---

## 📈 性能基准

### 预期测试结果

| 指标 | 预期值 | 警告阈值 | 失败阈值 |
|------|--------|---------|---------|
| 通过率 | >95% | <90% | <80% |
| 平均延迟 | <100ms | >500ms | >1000ms |
| P95 延迟 | <200ms | >1000ms | >2000ms |
| QPS | >100 | <50 | <20 |
| 错误率 | <1% | >5% | >10% |

---

## 🐛 故障排查

### 问题 1: 健康检查失败

**错误**:
```
❌ [FAIL] Health endpoint failed: None
```

**原因**: 服务未启动或端口错误

**解决**:
```bash
# 检查服务状态
docker-compose ps

# 检查端口
curl http://localhost:8080/health

# 查看日志
docker-compose logs proxy
```

---

### 问题 2: 熔断器测试失败

**错误**:
```
⚠️  [WARN] Circuit breaker did not enter HALF_OPEN state
```

**原因**: 
1. 超时配置不是 30 秒
2. 熔断器未正确实现

**解决**:
1. 检查配置: `config.circuit_breaker.timeout = 30`
2. 查看熔断器日志
3. 检查 Redis 连接(如果启用)

---

### 问题 3: 限流未触发

**错误**:
```
⚠️  [WARN] Rate limiting not triggered
```

**原因**:
1. 限流配置过高
2. 测试模式放大了限流阈值

**解决**:
```bash
# 检查环境变量
echo $STRESS_TEST_MODE

# 调整请求数量
python3 enhanced_auto_test.py --base-url http://localhost:8080
# 在代码中修改: requests_count=500
```

---

### 问题 4: 压力测试性能差

**现象**:
```
QPS: 15.23
Latency: avg=3500ms
```

**原因**:
1. 上游服务慢
2. 资源不足
3. 配置问题

**排查**:
```bash
# 检查资源使用
docker stats

# 检查上游延迟
curl -w "@curl-format.txt" http://localhost:8080/zerion/test

# 查看监控
curl http://localhost:8080/metrics | grep latency
```

---

## 📝 扩展测试

### 添加自定义测试

```python
class CustomTestSuite(ProxyTestSuite):
    """自定义测试套件"""
    
    def test_custom_feature(self):
        """测试自定义功能"""
        # 你的测试逻辑
        status_code, headers, body = http_request(
            self.base_url,
            "/custom-endpoint"
        )
        
        passed = status_code == 200
        
        if passed:
            ok("Custom feature test")
        else:
            fail("Custom feature test failed")
        
        self.results.add_result("custom_feature", passed, {
            "status": status_code
        })

# 使用
suite = CustomTestSuite(base_url="http://localhost:8080")
suite.run_all()
```

---

## 🎓 最佳实践

### 1. 测试隔离

- 每个测试独立运行
- 使用 `setUp` 和 `tearDown`
- 避免测试间依赖

### 2. 并行测试

```bash
# 使用 pytest-xdist
pytest -n 4 test_proxy.py
```

### 3. 环境管理

```bash
# 使用 .env 文件
export BASE_URL=http://localhost:8080
export PROVIDER=zerion

python3 enhanced_auto_test.py --base-url $BASE_URL --provider $PROVIDER
```

### 4. 持续监控

```bash
# 定时运行测试
*/30 * * * * cd /app && python3 enhanced_auto_test.py --report /reports/$(date +\%Y\%m\%d_\%H\%M).json
```

---

## 🔗 相关资源

- **原始脚本**: `auto_test.py`
- **增强脚本**: `enhanced_auto_test.py`
- **改进建议**: `test-improvement-analysis.md`
- **API 文档**: 查看 Swagger/OpenAPI 规范

---

**总结**: 增强脚本提供了更全面的测试覆盖,建议在开发和 CI/CD 中使用。原始脚本适合快速验证基本功能。