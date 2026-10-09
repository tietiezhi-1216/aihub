#!/usr/bin/env python3
"""Real pinned CLIProxyAPI + Swift SDK against an isolated loopback mock only."""
import argparse
import collections
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent
counts = collections.Counter()
lock = threading.Lock()


class LoopbackServer(ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.socket.getsockname()[1]


class Upstream(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        assert self.path == "/v1/chat/completions"
        assert self.headers.get("Authorization") == "Bearer mock-upstream-key"
        length = int(self.headers.get("Content-Length", "0"))
        assert 0 < length < 100000
        body = json.loads(self.rfile.read(length))
        model = body["model"]
        with lock:
            counts[model] += 1
        if model == "aihub-mock-429":
            status, result = 429, {"error": {"message": "mock-private-error", "type": "rate_limit_error"}}
        else:
            assert model == "aihub-mock-text"
            assert "模拟原文" in json.dumps(body, ensure_ascii=False)
            assert not body.get("tools")
            status, result = 200, {
                "id": "chat_mock", "object": "chat.completion", "created": 1, "model": model,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "模拟代理完成"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6},
            }
        data = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def unused_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/tools/CLIProxyAPI-8.0.17/cli-proxy-api")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("First run python3 scripts/install-cli-proxy.py")
    upstream = LoopbackServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="aihub-proxy-test-") as temporary:
            directory = Path(temporary)
            (directory / "auth").mkdir(mode=0o700)
            port = unused_port()
            upstream_port = upstream.server_address[1]
            # No OAuth records, Home integration, plugins, remote management,
            # discovery, static remote catalog refresh, request logs or retries.
            config = f"""config-version: 8
server:
  host: '127.0.0.1'
  port: {port}
  discovery:
    enabled: false
management:
  allow-remote: false
  secret-key: ''
  disable-control-panel: true
access:
  api-keys: ['aihub-local-test-key']
oauth:
  auth-dir: '{directory / 'auth'}'
routing:
  strategy: fill-first
  retry:
    request-retry: 0
    max-retry-credentials: 1
    max-retry-interval: 0
requests:
  streaming:
    bootstrap-retries: 0
api-keys:
  openai-compatibility:
    - name: aihub-loopback-mock
      base-url: 'http://127.0.0.1:{upstream_port}/v1'
      request-retry: 0
      keys:
        - api-key: mock-upstream-key
          proxy-url: direct
      models:
        - name: aihub-mock-text
          input-modalities: [text]
          output-modalities: [text]
        - name: aihub-mock-image
          output-modalities: [image]
        - name: aihub-mock-429
          output-modalities: [text]
plugins:
  enabled: false
observability:
  logs:
    debug: false
    request-log: false
    logging-to-file: false
  usage:
    usage-statistics-enabled: false
"""
            path = directory / "config.yaml"
            path.write_text(config)
            path.chmod(0o600)
            process_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": temporary, "TMPDIR": temporary, "LANG": "en_US.UTF-8"}
            log_path = ROOT / ".build/cli-proxy-loopback.log"
            with log_path.open("wb") as log:
                process = subprocess.Popen([str(binary), "-config", str(path), "-local-model"], cwd=temporary, env=process_env, stdout=log, stderr=subprocess.STDOUT)
                try:
                    url = f"http://127.0.0.1:{port}/v1"
                    for _ in range(100):
                        if process.poll() is not None:
                            raise RuntimeError("Isolated helper exited; inspect .build/cli-proxy-loopback.log")
                        try:
                            request = urllib.request.Request(url + "/models", headers={"Authorization": "Bearer aihub-local-test-key"})
                            with urllib.request.urlopen(request, timeout=1) as response:
                                if response.status == 200:
                                    break
                        except (urllib.error.URLError, TimeoutError):
                            time.sleep(0.1)
                    else:
                        raise RuntimeError("Isolated helper did not become ready")
                    environment = os.environ.copy()
                    environment["AIHUB_CLI_PROXY_TEST_URL"] = url
                    result = subprocess.run([str(ROOT / "scripts/test.sh"), "--filter", "CLIProxyLoopbackTests"], cwd=ROOT, env=environment, timeout=180)
                    if result.returncode:
                        raise SystemExit(result.returncode)
                    with lock:
                        observed = dict(counts)
                    if observed != {"aihub-mock-text": 1, "aihub-mock-429": 1}:
                        raise RuntimeError("Unexpected upstream request count: " + str(observed))
                    print("PASS: real local helper, fake credentials only; exact request counts", observed)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
    finally:
        upstream.shutdown()
        upstream.server_close()


if __name__ == "__main__":
    main()
