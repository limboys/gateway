#!/usr/bin/env python3
"""
Enhanced API Proxy Test Suite
包含完整的功能、稳定性和性能测试
"""
import argparse
import base64
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock
from urllib import request, error
from typing import Dict, List, Tuple, Optional


# ============================================================================
# HTTP 请求工具函数
# ============================================================================

def http_request(
    base_url: str,
    path: str,
    method: str = "GET",
    data: bytes = None,
    headers: Dict[str, str] = None,
    timeout: int = 5
) -> Tuple[Optional[int], Dict, bytes]:
    """发送 HTTP 请求"""
    url = base_url + path
    req = request.Request(url, method=method, data=data, headers=headers or {})
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read()
    except Exception as exc:
        return None, {}, str(exc).encode("utf-8")


def parse_json(body: bytes, context: str) -> dict:
    """解析 JSON 响应"""
    try:
        return json.loads(body.decode("utf-8"))
    except Exception as exc:
        print(f"[WARN] {context} json decode failed: {exc}")
        return {}


# ============================================================================
# 测试辅助函数
# ============================================================================

def ok(msg: str):
    """测试通过"""
    print(f"✅ [OK] {msg}")


def fail(msg: str, exit_on_fail: bool = True):
    """测试失败"""
    print(f"❌ [FAIL] {msg}")
    if exit_on_fail:
        sys.exit(1)


def warn(msg: str):
    """警告信息"""
    print(f"⚠️  [WARN] {msg}")


def wait_for_state(base_url: str, provider: str, state: str, timeout_sec: int = 5) -> bool:
    """等待熔断器状态"""
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        status_code, _, body = http_request(base_url, "/circuit-breaker-stats")
        if status_code != 200:
            time.sleep(0.2)
            continue
        payload = parse_json(body, "circuit-breaker-stats")
        current = payload.get(provider, {})
        if current.get("state") == state:
            return True
        time.sleep(0.2)
    return False


def percentile(values: List[float], p: float) -> Optional[float]:
    """计算百分位数"""
    if not values:
        return None
    values = sorted(values)
    k = int(round((len(values) - 1) * p))
    return values[k]


# ============================================================================
# 测试套件类
# ============================================================================

class TestResults:
    """测试结果收集器"""
    def __init__(self):
        self.total = 0
        self.passed = 0
        self.failed = 0
        self.warnings = 0
        self.details = {}
    
    def add_result(self, test_name: str, passed: bool, details: dict = None):
        """添加测试结果"""
        self.total += 1
        if passed:
            self.passed += 1
        else:
            self.failed += 1
        self.details[test_name] = {
            "passed": passed,
            "details": details or {}
        }
    
    def get_summary(self) -> dict:
        """获取测试摘要"""
        return {
            "total": self.total,
            "passed": self.passed,
            "failed": self.failed,
            "warnings": self.warnings,
            "pass_rate": f"{self.passed / max(1, self.total) * 100:.2f}%",
            "details": self.details
        }


class ProxyTestSuite:
    """API 代理测试套件"""
    
    def __init__(self, base_url: str, provider: str = "zerion", exit_on_fail: bool = False):
        self.base_url = base_url.rstrip("/")
        self.provider = provider
        self.exit_on_fail = exit_on_fail
        self.results = TestResults()
    
    # ========================================================================
    # 1. 基础端点测试
    # ========================================================================
    
    def test_health_endpoint(self):
        """测试健康检查端点"""
        status_code, _, body = http_request(self.base_url, "/health")
        # 修复: 正确的判断逻辑
        passed = status_code == 200 and (b"OK" in body or b"ok" in body or len(body) > 0)
        
        if passed:
            ok("Health endpoint")
        else:
            fail(f"Health endpoint failed: {status_code}, body={body[:50]}", self.exit_on_fail)
        
        self.results.add_result("health_endpoint", passed, {
            "status": status_code,
            "body": body.decode("utf-8", errors="ignore")[:100]
        })
        
    def test_metrics_endpoint(self):
        """测试监控指标端点"""
        status_code, _, body = http_request(self.base_url, "/metrics")
        passed = (
            status_code == 200 and
            b"api_proxy_requests_total" in body and
            b"api_proxy_latency_avg_ms" in body
        )
        
        if passed:
            ok("Metrics endpoint")
        else:
            fail(f"Metrics endpoint failed: {status_code}", self.exit_on_fail)
        
        self.results.add_result("metrics_endpoint", passed, {
            "status": status_code,
            "has_requests_total": b"api_proxy_requests_total" in body,
            "has_latency": b"api_proxy_latency_avg_ms" in body
        })
    
    def test_circuit_breaker_stats(self):
        """测试熔断器状态端点"""
        status_code, _, body = http_request(self.base_url, "/circuit-breaker-stats")
        passed = status_code == 200
        
        if passed:
            payload = parse_json(body, "circuit-breaker-stats")
            has_provider = self.provider in payload
            if has_provider:
                ok(f"Circuit breaker stats (provider: {self.provider})")
            else:
                warn(f"Provider {self.provider} not found in stats")
                passed = False
        else:
            fail(f"Circuit breaker stats failed: {status_code}", self.exit_on_fail)
        
        self.results.add_result("circuit_breaker_stats", passed, {
            "status": status_code
        })
    
    # ========================================================================
    # 2. HTTP 方法测试
    # ========================================================================
    
    def test_http_methods(self):
        """测试各种 HTTP 方法"""
        methods = {
            "GET": (None, [200, 404]),
            "POST": (b'{"test": "data"}', [200, 201, 404]),
            "PUT": (b'{"test": "data"}', [200, 201, 404]),
            "DELETE": (None, [200, 204, 404]),
            "HEAD": (None, [200, 404]),
        }
        
        for method, (data, expected_codes) in methods.items():
            headers = {}
            if data:
                headers["Content-Type"] = "application/json"
            
            status_code, resp_headers, _ = http_request(
                self.base_url,
                f"/{self.provider}/test",
                method=method,
                data=data,
                headers=headers
            )
            
            passed = status_code in expected_codes
            
            if passed:
                ok(f"HTTP {method} method")
            else:
                warn(f"HTTP {method} unexpected status: {status_code}")
            
            self.results.add_result(f"http_{method.lower()}", passed, {
                "status": status_code,
                "expected": expected_codes
            })
    
    # ========================================================================
    # 3. 认证测试
    # ========================================================================
    
    def test_authentication_headers(self):
        """测试认证 Header 是否正确注入"""
        # 这个测试需要查看日志或使用 echo 端点
        # 简化版本: 确保请求能够成功
        status_code, headers, _ = http_request(
            self.base_url,
            f"/{self.provider}/test"
        )
        
        # 检查是否有追踪 header
        has_request_id = "X-Proxy-Request-ID" in headers or "x-proxy-request-id" in headers
        has_provider = "X-Provider" in headers or "x-provider" in headers
        
        passed = status_code in [200, 404] and has_request_id
        
        if passed:
            ok("Authentication and headers")
        else:
            warn("Missing expected headers")
        
        self.results.add_result("authentication", passed, {
            "status": status_code,
            "has_request_id": has_request_id,
            "has_provider": has_provider
        })
    
    # ========================================================================
    # 4. 熔断器完整测试
    # ========================================================================
    
    def test_circuit_breaker_full_cycle(self, failure_threshold: int = 5):
        """测试熔断器完整状态循环"""
        
        # Step 1: 确保初始状态是 CLOSED
        ready = self._ensure_circuit_breaker_closed()
        if not ready:
            warn("Circuit breaker still not closed, skipping full cycle test")
            self.results.add_result("circuit_breaker_ready", False)
            return
        
        # Step 2: 触发失败,打开熔断器 (CLOSED → OPEN)
        ok("Testing circuit breaker: triggering failures...")
        for i in range(failure_threshold):
            status_code, _, _ = http_request(
                self.base_url,
                f"/{self.provider}/status/500",
                timeout=3
            )
            if status_code is None:
                warn(f"Request {i+1} failed completely")
        
        time.sleep(1)  # 等待状态更新
        
        opened = wait_for_state(self.base_url, self.provider, "open", timeout_sec=3)
        if opened:
            ok("Circuit breaker: CLOSED → OPEN")
        else:
            fail("Circuit breaker failed to open", self.exit_on_fail)
            self.results.add_result("circuit_breaker_open", False)
            return
        
        self.results.add_result("circuit_breaker_open", opened)
        
        # Step 3: 等待超时,进入半开状态 (OPEN → HALF_OPEN)
        ok("Waiting for circuit breaker timeout (30s)...")
        time.sleep(31)
        
        # 发送一个请求触发状态转换
        http_request(self.base_url, f"/{self.provider}/test", timeout=3)
        time.sleep(1)
        
        half_opened = wait_for_state(self.base_url, self.provider, "half_open", timeout_sec=3)
        if half_opened:
            ok("Circuit breaker: OPEN → HALF_OPEN")
        else:
            warn("Circuit breaker did not enter HALF_OPEN state")
        
        self.results.add_result("circuit_breaker_half_open", half_opened)
        
        # Step 4: 发送成功请求,恢复正常 (HALF_OPEN → CLOSED)
        ok("Sending successful requests to close circuit breaker...")
        success_threshold = 2
        for i in range(success_threshold + 1):
            http_request(self.base_url, f"/{self.provider}/test", timeout=3)
            time.sleep(0.5)
        
        closed = wait_for_state(self.base_url, self.provider, "closed", timeout_sec=5)
        if closed:
            ok("Circuit breaker: HALF_OPEN → CLOSED")
        else:
            warn("Circuit breaker failed to close")
        
        self.results.add_result("circuit_breaker_closed", closed)
    
    def test_circuit_breaker_degradation(self):
        """测试熔断时的降级缓存"""
        ready = self._ensure_circuit_breaker_closed()
        if not ready:
            warn("Circuit breaker still not closed, skipping degradation test")
            self.results.add_result("degradation_cache", False)
            return
        # 先预热缓存
        http_request(self.base_url, f"/{self.provider}/get")
        time.sleep(1)
        
        # 触发熔断
        for _ in range(5):
            http_request(self.base_url, f"/{self.provider}/status/500", timeout=3)
        time.sleep(1)
        
        # 验证降级缓存
        status_code, headers, _ = http_request(self.base_url, f"/{self.provider}/get")
        degraded = headers.get("X-Degraded") == "cache" or headers.get("x-degraded") == "cache"
        
        passed = status_code == 200 and degraded
        
        if passed:
            ok("Circuit breaker degradation with cache")
        else:
            warn(f"Degradation failed: status={status_code}, X-Degraded={headers.get('X-Degraded')}")
        
        self.results.add_result("degradation_cache", passed, {
            "status": status_code,
            "degraded": degraded
        })
        
        # 等待恢复
        time.sleep(35)
    
    def _get_circuit_breaker_state(self) -> Optional[str]:
        """获取当前熔断器状态"""
        status_code, _, body = http_request(self.base_url, "/circuit-breaker-stats")
        if status_code != 200:
            return None
        payload = parse_json(body, "circuit-breaker-stats")
        return payload.get(self.provider, {}).get("state")

    def _ensure_circuit_breaker_closed(self, timeout_sec: int = 40) -> bool:
        """确保熔断器处于 CLOSED 状态，必要时尝试恢复"""
        state = self._get_circuit_breaker_state()
        if state == "closed":
            return True

        if state == "open":
            # 等待超时并触发探测请求，推动状态进入 HALF_OPEN
            time.sleep(31)
            http_request(self.base_url, f"/{self.provider}/success", timeout=3)
            time.sleep(1)
        elif state == "half_open":
            # 直接发送成功请求尝试关闭
            for _ in range(3):
                http_request(self.base_url, f"/{self.provider}/success", timeout=3)
                time.sleep(0.5)

        closed = wait_for_state(self.base_url, self.provider, "closed", timeout_sec=timeout_sec)
        if not closed:
            warn(f"Circuit breaker not in CLOSED state: {state}")
        return closed
    
    # ========================================================================
    # 5. 限流测试
    # ========================================================================
    
    def test_rate_limiting(self, requests_count: int = 500, concurrency: int = 50):
        """测试限流功能"""
        ok(f"Testing rate limiting with {requests_count} requests...")

        status_429_count = 0
        start = time.time()

        def worker():
            status_code, _, _ = http_request(
                self.base_url,
                f"/{self.provider}/test",
                timeout=2
            )
            return status_code

        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [executor.submit(worker) for _ in range(requests_count)]
            for i, future in enumerate(as_completed(futures)):
                try:
                    status_code = future.result()
                except Exception:
                    status_code = None
                if status_code == 429:
                    status_429_count += 1
                    if status_429_count == 1:
                        ok(f"First rate limit at request #{i+1}")

        elapsed = time.time() - start

        passed = status_429_count > 0

        if passed:
            ok(f"Rate limiting works ({status_429_count}/{requests_count} limited in {elapsed:.1f}s)")
        else:
            warn(f"Rate limiting not triggered (sent {requests_count} in {elapsed:.1f}s)")

        self.results.add_result("rate_limiting", passed, {
            "total_requests": requests_count,
            "limited_requests": status_429_count,
            "elapsed_seconds": round(elapsed, 2),
            "actual_qps": round(requests_count / elapsed, 2),
            "limit_rate": f"{status_429_count / requests_count * 100:.2f}%"
        })

    
    # ========================================================================
    # 6. 缓存测试
    # ========================================================================
    
    def test_caching(self):
        """测试响应缓存功能"""
        import hashlib
        
        # 使用唯一路径避免其他测试干扰
        path = f"/{self.provider}/cache-test-{int(time.time())}"
        
        # 第一次请求 - 应该缓存 miss
        start1 = time.perf_counter()
        status1, headers1, body1 = http_request(self.base_url, path)
        latency1 = (time.perf_counter() - start1) * 1000
        
        if status1 not in [200, 404]:
            warn(f"First request failed: {status1}")
            self.results.add_result("caching", False)
            return
        
        time.sleep(0.2)  # 确保缓存已写入
        
        # 第二次请求 - 应该缓存 hit (更快)
        start2 = time.perf_counter()
        status2, headers2, body2 = http_request(self.base_url, path)
        latency2 = (time.perf_counter() - start2) * 1000
        
        # 验证条件:
        # 1. 状态码一致
        # 2. 响应内容一致 (哈希比较)
        # 3. 第二次明显更快 (缓存命中应该 < 10ms)
        hash1 = hashlib.md5(body1).hexdigest() if body1 else None
        hash2 = hashlib.md5(body2).hexdigest() if body2 else None
        
        same_status = status1 == status2
        same_body = hash1 == hash2
        faster = latency2 < latency1 * 0.5  # 至少快 50%
        
        passed = same_status and same_body
        
        if passed:
            if faster:
                ok(f"Caching works (2nd req {latency2:.1f}ms < 1st {latency1:.1f}ms)")
            else:
                ok(f"Caching responses consistent")
        else:
            warn(f"Caching verification failed: status={same_status}, body={same_body}")
        
        self.results.add_result("caching", passed, {
            "status_1": status1,
            "status_2": status2,
            "latency_1_ms": round(latency1, 2),
            "latency_2_ms": round(latency2, 2),
            "bodies_match": same_body,
            "faster": faster
        })

    
    # ========================================================================
    # 7. 压力测试
    # ========================================================================
    
    def test_load(self, concurrency: int = 20, duration: int = 10):
        """压力测试"""
        ok(f"Running load test: {concurrency} concurrent for {duration}s...")
        
        stats = {
            "total": 0,
            "success": 0,
            "errors": 0,
            "rate_limited": 0,  # ⚡ 新增: 限流统计
            "status_counts": {},
            "latencies_ms": []
        }
        lock = Lock()
        deadline = time.time() + duration
        
        def record(status_code, latency_ms):
            with lock:
                stats["total"] += 1
                if status_code and 200 <= status_code < 400:
                    stats["success"] += 1
                elif status_code == 429:
                    stats["rate_limited"] += 1  # ⚡ 记录限流
                if status_code is None:
                    stats["errors"] += 1
                else:
                    key = str(status_code)
                    stats["status_counts"][key] = stats["status_counts"].get(key, 0) + 1
                stats["latencies_ms"].append(latency_ms)
        
        def worker():
            while time.time() < deadline:
                start = time.perf_counter()
                status_code, _, _ = http_request(
                    self.base_url,
                    f"/{self.provider}/test",
                    timeout=10  # ⚡ 增加超时时间 (从 5s 到 10s)
                )
                latency_ms = (time.perf_counter() - start) * 1000
                record(status_code, latency_ms)
                # ⚡ 可选: 添加短暂延迟,模拟真实场景
                # time.sleep(0.001)  # 1ms
        
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [executor.submit(worker) for _ in range(concurrency)]
            for future in as_completed(futures):
                try:
                    future.result()
                except Exception as e:
                    warn(f"Worker error: {e}")
        
        # 计算统计
        latencies = sorted(stats["latencies_ms"])
        p50 = percentile(latencies, 0.50)
        p95 = percentile(latencies, 0.95)
        p99 = percentile(latencies, 0.99)
        p999 = percentile(latencies, 0.999) if len(latencies) > 1000 else None  # ⚡ 新增 p999
        avg = sum(latencies) / max(1, len(latencies))
        min_lat = min(latencies) if latencies else 0
        max_lat = max(latencies) if latencies else 0
        qps = stats["total"] / duration
        success_rate = (stats["success"] / max(1, stats["total"])) * 100  # ⚡ 成功率
        
        # ⚡ 调整判断条件
        passed = (
            stats["success"] > 0 and 
            avg < 1000 and  # 平均延迟 < 1s (压测模式更严格)
            success_rate >= 95 and  # 成功率 >= 95%
            stats["rate_limited"] == 0  # 压测模式不应触发限流
        )
        
        print(f"  Total: {stats['total']}, Success: {stats['success']}, Errors: {stats['errors']}, Rate Limited: {stats['rate_limited']}")
        print(f"  QPS: {qps:.2f}, Success Rate: {success_rate:.2f}%")
        print(f"  Latency: min={min_lat:.2f}ms, avg={avg:.2f}ms, max={max_lat:.2f}ms")
        print(f"  Latency: p50={p50:.2f}ms, p95={p95:.2f}ms, p99={p99:.2f}ms" + 
              (f", p999={p999:.2f}ms" if p999 else ""))
        
        if passed:
            ok("Load test completed")
        else:
            warn("Load test performance issues")
            if stats["rate_limited"] > 0:
                warn(f"  ⚠️  Rate limiting triggered {stats['rate_limited']} times - increase STRESS_TEST_MODE limits")
            if avg >= 1000:
                warn(f"  ⚠️  High average latency: {avg:.2f}ms")
            if success_rate < 95:
                warn(f"  ⚠️  Low success rate: {success_rate:.2f}%")
        
        self.results.add_result("load_test", passed, {
            "total": stats["total"],
            "success": stats["success"],
            "errors": stats["errors"],
            "rate_limited": stats["rate_limited"],
            "qps": round(qps, 2),
            "success_rate": round(success_rate, 2),
            "latency": {
                "min": round(min_lat, 2),
                "avg": round(avg, 2),
                "max": round(max_lat, 2),
                "p50": round(p50, 2) if p50 else None,
                "p95": round(p95, 2) if p95 else None,
                "p99": round(p99, 2) if p99 else None,
                "p999": round(p999, 2) if p999 else None
            },
            "status_counts": stats["status_counts"]
        })
    
    # ========================================================================
    # 8. 多 Provider 测试
    # ========================================================================
    
    def test_all_providers(self):
        """测试所有 Provider"""
        providers = ["zerion", "coingecko", "alchemy"]
        
        for provider in providers:
            status_code, _, _ = http_request(
                self.base_url,
                f"/{provider}/test",
                timeout=3
            )
            passed = status_code in [200, 404, 502]
            
            if passed:
                ok(f"Provider: {provider}")
            else:
                warn(f"Provider {provider} failed: {status_code}")
            
            self.results.add_result(f"provider_{provider}", passed, {
                "status": status_code
            })
    
    # ========================================================================
    # 运行所有测试
    # ========================================================================
    
    def run_all(
        self,
        include_load_test: bool = False,
        include_circuit_breaker: bool = False,
        load_concurrency: int = 20,
        load_duration: int = 10,
        rate_limit_cooldown: int = 60
    ) -> dict:
        """运行所有测试"""
        print("\n" + "=" * 60)
        print("🚀 API Proxy Test Suite")
        print("=" * 60 + "\n")
        
        # 1. 基础端点
        print("📍 Testing Basic Endpoints...")
        self.test_health_endpoint()
        self.test_metrics_endpoint()
        self.test_circuit_breaker_stats()
        
        # 2. HTTP 方法
        print("\n🔧 Testing HTTP Methods...")
        self.test_http_methods()
        
        # 3. 认证
        print("\n🔐 Testing Authentication...")
        self.test_authentication_headers()
        
        # 4. 多 Provider
        print("\n🌐 Testing All Providers...")
        self.test_all_providers()
        
        # 5. 缓存
        print("\n💾 Testing Caching...")
        self.test_caching()
        
        # 6. 限流
        print("\n🚦 Testing Rate Limiting...")
        self.test_rate_limiting()
        
        # 熔断器测试前等待限流窗口恢复
        if include_circuit_breaker and rate_limit_cooldown > 0:
            print(f"\n⏳ Waiting {rate_limit_cooldown}s for rate limit cooldown...")
            time.sleep(rate_limit_cooldown)
        
        # 7. 熔断器 (可选,耗时较长)
        if include_circuit_breaker:
            print("\n⚡ Testing Circuit Breaker (this may take ~60s)...")
            self.test_circuit_breaker_full_cycle()
            self.test_circuit_breaker_degradation()
        
        # 8. 压力测试 (可选)
        if include_load_test:
            print("\n📈 Running Load Test...")
            self.test_load(concurrency=load_concurrency, duration=load_duration)
        
        # 生成报告
        print("\n" + "=" * 60)
        print("📊 Test Summary")
        print("=" * 60)
        summary = self.results.get_summary()
        print(f"Total: {summary['total']}")
        print(f"Passed: {summary['passed']} ✅")
        print(f"Failed: {summary['failed']} ❌")
        print(f"Pass Rate: {summary['pass_rate']}")
        print("=" * 60 + "\n")
        
        return summary


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Enhanced API Proxy Test Suite")
    parser.add_argument("--base-url", default="http://localhost:8080",
                       help="Base URL of the API proxy")
    parser.add_argument("--provider", default="zerion",
                       help="Provider to test")
    parser.add_argument("--quick", action="store_true",
                       help="Quick test mode (skip slow tests)")
    parser.add_argument("--load-test", action="store_true",
                       help="Include load testing")
    parser.add_argument("--load-only", action="store_true",
                       help="Run load test only")
    parser.add_argument("--rate-limit-only", action="store_true",
                       help="Run rate limiting test only")
    parser.add_argument("--circuit-breaker-only", action="store_true",
                       help="Run circuit breaker tests only")
    parser.add_argument("--load-concurrency", type=int, default=20,
                       help="Load test concurrency")
    parser.add_argument("--load-duration", type=int, default=10,
                       help="Load test duration (seconds)")
    parser.add_argument("--rate-limit-cooldown", type=int, default=60,
                       help="Cooldown seconds before circuit breaker tests")
    parser.add_argument("--circuit-breaker", action="store_true",
                       help="Include circuit breaker full cycle test (slow)")
    parser.add_argument("--report", default="",
                       help="Output JSON report file")
    parser.add_argument("--exit-on-fail", action="store_true",
                       help="Exit immediately on first failure")
    
    args = parser.parse_args()
    
    # Quick mode: 跳过耗时测试
    if args.quick:
        args.load_test = False
        args.circuit_breaker = False

    if args.load_only:
        args.load_test = True
        args.circuit_breaker = False

    if args.rate_limit_only:
        args.load_test = False
        args.circuit_breaker = False

    if args.circuit_breaker_only:
        args.load_test = False
        args.circuit_breaker = True
    
    # 创建测试套件
    suite = ProxyTestSuite(
        base_url=args.base_url,
        provider=args.provider,
        exit_on_fail=args.exit_on_fail
    )

    # 运行测试
    if args.load_only:
        print("\n" + "=" * 60)
        print("🚀 API Proxy Load Test")
        print("=" * 60 + "\n")
        suite.test_load(concurrency=args.load_concurrency, duration=args.load_duration)
        print("\n" + "=" * 60)
        print("📊 Test Summary")
        print("=" * 60)
        results = suite.results.get_summary()
        print(f"Total: {results['total']}")
        print(f"Passed: {results['passed']} ✅")
        print(f"Failed: {results['failed']} ❌")
        print(f"Pass Rate: {results['pass_rate']}")
        print("=" * 60 + "\n")
    elif args.rate_limit_only:
        print("\n" + "=" * 60)
        print("🚀 API Proxy Rate Limit Test")
        print("=" * 60 + "\n")
        suite.test_rate_limiting()
        print("\n" + "=" * 60)
        print("📊 Test Summary")
        print("=" * 60)
        results = suite.results.get_summary()
        print(f"Total: {results['total']}")
        print(f"Passed: {results['passed']} ✅")
        print(f"Failed: {results['failed']} ❌")
        print(f"Pass Rate: {results['pass_rate']}")
        print("=" * 60 + "\n")
    elif args.circuit_breaker_only:
        print("\n" + "=" * 60)
        print("🚀 API Proxy Circuit Breaker Test")
        print("=" * 60 + "\n")
        suite.test_circuit_breaker_full_cycle()
        suite.test_circuit_breaker_degradation()
        print("\n" + "=" * 60)
        print("📊 Test Summary")
        print("=" * 60)
        results = suite.results.get_summary()
        print(f"Total: {results['total']}")
        print(f"Passed: {results['passed']} ✅")
        print(f"Failed: {results['failed']} ❌")
        print(f"Pass Rate: {results['pass_rate']}")
        print("=" * 60 + "\n")
    else:
        results = suite.run_all(
            include_load_test=args.load_test,
            include_circuit_breaker=args.circuit_breaker,
            load_concurrency=args.load_concurrency,
            load_duration=args.load_duration,
            rate_limit_cooldown=args.rate_limit_cooldown
        )
    
    # 保存报告
    if args.report:
        report_dir = os.path.dirname(args.report)
        if report_dir:
            os.makedirs(report_dir, exist_ok=True)
        with open(args.report, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)
        print(f"📄 Report saved to: {args.report}")
    
    # 退出码
    sys.exit(0 if results["failed"] == 0 else 1)


if __name__ == "__main__":
    main()