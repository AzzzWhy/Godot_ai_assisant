#!/usr/bin/env python3
"""本地 mock OpenAI 兼容服务器，用于插件端到端测试（不消费任何真实额度）。

路径约定：
  POST /v1/chat/completions            -> SSE 流式（分两段发送，模拟网络分块）
  POST /v1/chat/completions?mode=json  -> 非流式整包 JSON
  POST /v1/chat/completions?mode=401   -> 401 错误 JSON
"""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        req = json.loads(body) if body else {}
        path = self.path

        # 严格校验路径：客户端必须请求 /v1/chat/completions（曾出现 base_url 路径拼接 bug 导致 404）
        path_only = path.split("?", 1)[0]
        if path_only != "/v1/chat/completions":
            data = json.dumps({"error": {"message": "not found"}}).encode()
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if "mode=401" in path:
            data = json.dumps({"error": {"message": "invalid api key"}}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if "mode=json" in path:
            data = json.dumps({
                "choices": [{"message": {"content": "非流式回复 42", "reasoning_content": ""}}]
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        # 默认：流式，分两段发送 + 延迟，模拟真实网络分块
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        part1 = 'data: {"choices":[{"delta":{"content":"你好，"},"finish_reason":null}]}\n\n'.encode()
        self.wfile.write(part1)
        self.wfile.flush()
        time.sleep(0.25)
        part2 = ('data: {"choices":[{"delta":{"content":"世界！"},"finish_reason":null}]}\n\n'
                 'data: [DONE]\n\n').encode()
        self.wfile.write(part2)
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/v1/models":
            data = json.dumps({"object": "list", "data": [
                {"id": "mock-model-a", "object": "model", "created": 0, "owned_by": "mock"},
                {"id": "mock-model-b", "object": "model", "created": 0, "owned_by": "mock"},
            ]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        data = json.dumps({"error": {"message": "not found"}}).encode()
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    print("MOCK_SERVER listening on 127.0.0.1:8765")
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()