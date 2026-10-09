#!/usr/bin/env python3
"""Loopback-only test fixture; does not implement speech recognition."""
import argparse
import json
import threading
import time
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
import base64
import socketserver


class LoopbackServer(ThreadingHTTPServer):
    # Concurrent Swift Testing cases can open more than the default five connections.
    request_queue_size = 128

    def server_bind(self):
        # A loopback fixture needs no reverse DNS. VPN resolver stalls must not
        # prevent tests from starting or be mistaken for provider failures.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.socket.getsockname()[1]

lock = threading.Lock()
redirect_target_hits = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_sse(self, frames):
        body = "".join("data: " + (frame if isinstance(frame, str) else json.dumps(frame, ensure_ascii=False)) + "\n\n" for frame in frames).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            for offset in range(0, len(body), 17):
                self.wfile.write(body[offset:offset + 17])
                self.wfile.flush()
                time.sleep(0.002)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        global redirect_target_hits
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/registry/api.json":
            if self.headers.get("Authorization") or self.headers.get("x-api-key"):
                self.send_json({}, 400)
            else:
                self.send_json({"openai": {"models": {"gpt-test": {"name": "GPT Test", "reasoning": True, "reasoning_options": [{"type": "effort", "values": ["low", "high"]}], "modalities": {"input": ["text"], "output": ["text"]}, "cost": {"input": 2, "output": 8}}}}})
        elif url.path == "/accounts/codex/backend-api/codex/models":
            valid = self.headers.get("Authorization") == "Bearer fake-access" and self.headers.get("ChatGPT-Account-Id") == "mock-account"
            self.send_json({"models": [{"slug": "gpt-test-codex", "display_name": "Codex Mock"}]} if valid else {}, 200 if valid else 401)
        elif url.path == "/accounts/grok/v1/models":
            valid = self.headers.get("Authorization") == "Bearer fake-access" and self.headers.get("X-XAI-Token-Auth") == "xai-grok-cli"
            self.send_json({"data": [{"id": "grok-build", "name": "Grok Mock"}]} if valid else {}, 200 if valid else 401)
        elif url.path == "/anthropic/v1/models":
            if self.headers.get("x-api-key") != "fake" or self.headers.get("anthropic-version") != "2023-06-01":
                self.send_json({"error": "wrong authentication"}, 401)
            elif query.get("after_id") == ["claude-test"]:
                self.send_json({"data": [{"id": "claude-second"}], "has_more": False})
            else:
                self.send_json({"data": [{"id": "claude-test", "display_name": "Claude Test"}], "has_more": True, "last_id": "claude-test"})
        elif url.path == "/gemini/v1beta/models":
            if self.headers.get("x-goog-api-key") != "fake":
                self.send_json({"error": "wrong authentication"}, 401)
            elif query.get("pageToken") == ["next"]:
                self.send_json({"models": [{"name": "models/gemini-second", "supportedGenerationMethods": ["generateContent"]}]})
            else:
                self.send_json({"models": [{"name": "models/gemini-test", "displayName": "Gemini Test", "supportedGenerationMethods": ["generateContent"]}], "nextPageToken": "next"})
        elif url.path in ("/openai/v1/models", "/responses/v1/models"):
            valid = self.headers.get("Authorization") == "Bearer fake"
            self.send_json({"data": [{"id": "gpt-test"}]} if valid else {}, 200 if valid else 401)
        elif url.path == "/xiaomi/v1/models":
            valid = self.headers.get("api-key") == "fake"
            self.send_json({"data": [{"id": "mimo-v2.5-pro"}, {"id": "mimo-v2.5-asr"}]} if valid else {}, 200 if valid else 401)
        elif self.path == "/redirect/models":
            self.send_response(302)
            self.send_header("Location", "/redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/redirect-target":
            with lock:
                redirect_target_hits += 1
            self.send_json({"data": []})
        elif self.path == "/stats":
            with lock:
                self.send_json({"redirectTargetHits": redirect_target_hits})
        elif self.path == "/oversized":
            self.send_response(200)
            self.send_header("Content-Length", "10000000")
            self.end_headers()
            try:
                self.wfile.write(b"x" * 1024)
                self.wfile.flush()
                time.sleep(0.5)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path == "/unknown-length":
            self.send_response(200)
            self.end_headers()
            try:
                self.wfile.write(b"x" * 512)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path in ("/v1/models", "/slow/models"):
            if self.path.startswith("/slow"):
                time.sleep(2)
            self.send_json({"data": [{"id": "whisper-1"}, {"id": "gpt-4o-mini"}, {"id": "whisper-1"}]})
        else:
            self.send_json({"error": "unknown route"}, 404)

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 25 * 1024 * 1024:
            self.send_json({"error": "too large"}, 413)
            return
        raw = self.rfile.read(size)
        account_path = urlsplit(self.path).path
        if account_path.startswith("/sdk/"):
            payload = json.loads(raw)
            encoded = json.dumps(payload, ensure_ascii=False)
            api = account_path.split("/")[2]
            if api == "mixed":
                api = "responses" if account_path.endswith("/responses") else "openai"
            key_header = "x-api-key" if api == "anthropic" else "x-goog-api-key" if api == "gemini" else "Authorization"
            expected = "fake" if api in ("anthropic", "gemini") else "Bearer fake"
            valid = self.headers.get(key_header) == expected and "模拟输入" in encoded and "整理" in encoded and not payload.get("tools")
            if parse_qs(urlsplit(self.path).query).get("reasoning_test") == ["1"]:
                if api == "openai":
                    valid = valid and payload.get("reasoning_effort") == "high" and payload.get("max_completion_tokens") == 4096 and "max_tokens" not in payload
                elif api == "responses":
                    valid = valid and payload.get("reasoning") == {"effort": "high"} and payload.get("store") is False
                elif api == "anthropic":
                    valid = valid and payload.get("thinking") == {"type": "adaptive"} and payload.get("output_config", {}).get("effort") == "high" and "temperature" not in payload
                elif api == "gemini":
                    valid = valid and payload.get("generationConfig", {}).get("thinkingConfig") == {"thinkingLevel": "high", "includeThoughts": False}
            if not valid:
                self.send_json({}, 400)
            elif api == "openai":
                self.send_json({"id": "chat_sdk", "object": "chat.completion", "created": 1, "model": "gpt-test", "choices": [{"index": 0, "message": {"role": "assistant", "content": "模拟SDK转换成功"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6}})
            elif api == "responses":
                if payload.get("store") is not False:
                    self.send_json({}, 400)
                else:
                    self.send_json({"id": "resp_sdk", "created_at": 1, "status": "completed", "model": "gpt-test", "output": [{"type": "message", "id": "msg_sdk", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": "模拟SDK转换成功", "annotations": []}]}], "usage": {"input_tokens": 4, "output_tokens": 2, "total_tokens": 6}})
            elif api == "anthropic":
                self.send_json({"id": "msg_sdk", "type": "message", "role": "assistant", "model": "claude-sonnet-4-6", "content": [{"type": "text", "text": "模拟SDK转换成功"}], "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 4, "output_tokens": 2}})
            elif api == "gemini":
                self.send_json({"candidates": [{"index": 0, "content": {"role": "model", "parts": [{"text": "模拟SDK转换成功"}]}, "finishReason": "STOP"}], "usageMetadata": {"promptTokenCount": 4, "candidatesTokenCount": 2, "totalTokenCount": 6}})
            else:
                self.send_json({}, 404)
            return
        if account_path.startswith("/accounts/"):
            payload = json.loads(raw)
            if self.headers.get("Authorization") != "Bearer fake-access":
                self.send_json({}, 401)
            elif account_path == "/accounts/antigravity/v1internal:loadCodeAssist":
                valid = payload == {"metadata": {"ideType": "ANTIGRAVITY"}}
                self.send_json({"cloudaicompanionProject": "mock-project"} if valid else {}, 200 if valid else 400)
            elif account_path == "/accounts/antigravity/v1internal:fetchAvailableModels":
                valid = payload == {} and not self.headers.get("Client-Metadata")
                self.send_json({"models": {
                    "gemini-test": {"displayName": "Gemini Mock", "inputModalities": ["text", "image", "video", "audio"], "outputModalities": ["text"]},
                    "gpt-image-1": {"supportsImageGeneration": True}, "veo-3.1": {},
                    "whisper-1": {}, "gemini-flash-tts": {}, "future-model": {"disabled": True}
                }} if valid else {}, 200 if valid else 400)
            elif account_path == "/accounts/codex/backend-api/codex/responses":
                valid = payload.get("store") is False and payload.get("stream") is True and self.headers.get("ChatGPT-Account-Id") == "mock-account"
                if valid:
                    self.send_sse([{"type": "response.output_text.delta", "delta": "模拟转换成功"}, {"type": "response.completed", "response": {"status": "completed"}}])
                else:
                    self.send_json({}, 400)
            elif account_path == "/accounts/grok/v1/chat/completions":
                valid = payload.get("stream") is True and self.headers.get("x-grok-model-override") == "grok-build"
                if valid:
                    self.send_sse([{"choices": [{"delta": {"content": "模拟转换成功"}}]}, {"choices": [{"delta": {}, "finish_reason": "stop"}]}, "[DONE]"])
                else:
                    self.send_json({}, 400)
            elif account_path == "/accounts/antigravity/v1internal:streamGenerateContent":
                valid = payload.get("project") == "mock-project" and payload.get("request", {}).get("contents", [])[0]["parts"][0]["text"] == "模拟输入"
                thinking = payload.get("request", {}).get("generationConfig", {}).get("thinkingConfig")
                if thinking is not None:
                    valid = False
                if valid:
                    self.send_sse([{"response": {"candidates": [{"content": {"parts": [{"text": "模拟转换成功"}]}, "finishReason": "STOP"}]}}])
                else:
                    self.send_json({}, 400)
            else:
                self.send_json({}, 404)
            return
        if self.path == "/responses/v1/responses":
            payload = json.loads(raw)
            valid = payload.get("input") == "模拟输入" and payload.get("store") is False and self.headers.get("Authorization") == "Bearer fake"
            self.send_json({"status": "completed", "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "模拟转换成功"}]}]} if valid else {}, 200 if valid else 400)
        elif self.path == "/anthropic/v1/messages":
            payload = json.loads(raw)
            valid = payload.get("system") == "整理" and payload.get("max_tokens") == 4096 and self.headers.get("x-api-key") == "fake"
            self.send_json({"content": [{"type": "text", "text": "模拟转换成功"}]} if valid else {}, 200 if valid else 400)
        elif self.path == "/gemini/v1beta/models/gemini-test:generateContent":
            payload = json.loads(raw)
            valid = payload["contents"][0]["parts"][0]["text"] == "模拟输入" and self.headers.get("x-goog-api-key") == "fake"
            self.send_json({"candidates": [{"content": {"parts": [{"text": "模拟转换成功"}]}, "finishReason": "STOP"}]} if valid else {}, 200 if valid else 400)
        elif self.path in ("/openai/v1/chat/completions", "/xiaomi/v1/chat/completions"):
            payload = json.loads(raw)
            header = self.headers.get("api-key") if self.path.startswith("/xiaomi") else self.headers.get("Authorization")
            valid = header == ("fake" if self.path.startswith("/xiaomi") else "Bearer fake")
            content = payload["messages"][-1]["content"]
            if isinstance(content, list):
                valid = valid and base64.b64decode(content[0]["input_audio"]["data"].split(",", 1)[1]) == bytes([0, 1, 255, 13, 10, 42])
                text = "模拟小米识别成功"
            else:
                valid = valid and content == "模拟输入"
                text = "模拟转换成功"
            self.send_json({"choices": [{"message": {"content": text}}]} if valid else {}, 200 if valid else 400)
        elif self.path == "/v1/audio/transcriptions":
            content_type = self.headers.get("Content-Type", "")
            parsed = BytesParser(policy=policy.default).parsebytes(
                ("Content-Type: " + content_type + "\r\nMIME-Version: 1.0\r\n\r\n").encode() + raw
            )
            if not parsed.is_multipart():
                self.send_json({"error": "not multipart"}, 400)
                return
            parts = {part.get_param("name", header="content-disposition"): part for part in parsed.iter_parts()}
            valid = (
                parts.get("file") is not None
                and parts["file"].get_payload(decode=True) == bytes([0, 1, 255, 13, 10, 42])
                and parts["file"].get_filename() == "audio.wav"
                and parts["model"].get_payload(decode=True) == b"whisper-1"
                and parts["language"].get_payload(decode=True) == b"zh"
                and parts["prompt"].get_payload(decode=True) == b"AIHub"
            )
            self.send_json({"text": "模拟识别成功"} if valid else {"error": "invalid multipart"}, 200 if valid else 400)
        elif self.path == "/v1/chat/completions":
            payload = json.loads(raw)
            valid = payload["messages"][-1]["content"] == "模拟识别成功"
            self.send_json({"choices": [{"message": {"content": "模拟转换成功"}}]} if valid else {}, 200 if valid else 400)
        else:
            self.send_json({"error": "unknown route"}, 404)


parser = argparse.ArgumentParser()
parser.add_argument("--port-file", required=True)
args = parser.parse_args()
server = LoopbackServer(("127.0.0.1", 0), Handler)
with open(args.port_file, "w", encoding="utf-8") as file:
    file.write(str(server.server_port))
server.serve_forever()
