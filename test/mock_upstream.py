from flask import Flask, request, jsonify
import os
import time
import random

app = Flask(__name__)

# 模拟成功率（用于测试熔断器）
SUCCESS_RATE = float(os.getenv("SUCCESS_RATE", "1.0"))
request_count = 0

@app.route('/', defaults={'path': ''})
@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'OPTIONS'])
def catch_all(path):
    global request_count
    request_count += 1
    
    # 记录请求
    print(f"Request #{request_count}: {request.method} /{path}")
    
    # 模拟延迟
    delay = random.uniform(0.01, 0.05)
    time.sleep(delay)
    
    # 针对缓存测试路径，返回稳定响应，避免内容波动
    if "cache-test-" in path:
        return jsonify({
            "success": True,
            "path": path,
            "method": request.method
            # 注意: 不返回 request_id 和 timestamp，确保响应内容完全一致，便于缓存测试
        }), 200

    # 根据成功率返回响应
    if random.random() < SUCCESS_RATE:
        return jsonify({
            "success": True,
            "path": path,
            "method": request.method,
            "request_id": request.headers.get('x-onekey-request-id'),
            "timestamp": time.time()
        }), 200
    else:
        return jsonify({
            "error": "Simulated upstream error"
        }), 500

@app.route('/health')
def health():
    return jsonify({"status": "healthy"}), 200

# 模拟固定错误状态码
@app.route('/status/500')
def status_500():
    return jsonify({"error": "Forced 500"}), 500

# 用于测试熔断器的特殊端点
@app.route('/fail')
def fail():
    return jsonify({"error": "Forced failure"}), 500

@app.route('/success')
def success():
    return jsonify({"success": True}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, threaded=True)
