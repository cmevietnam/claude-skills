#!/usr/bin/env python3
"""Loopback Anthropic-Messages mock for the real-dsh section of test-deepseek-review.sh.

Usage: mock-messages.py PORT_FILE LOG_JSONL SCENARIO READ_PATH SENTINEL

Scenarios (every one first asks for a `read` of READ_PATH):
  answer      after the tool_result, answer with a VERDICT line carrying the prompt's nonce
              (only if the tool_result carried SENTINEL; otherwise "SENTINEL NOT SEEN")
  max_tokens  after the tool_result, a partial answer with stop_reason max_tokens
  refusal     after the tool_result, stop_reason refusal
  answer_any  after the tool_result, answer with the VERDICT line whatever the tool_result held
              (READ_PATH may be a directory: real dsh answers it with a tool error)

Each POST is logged with its body (auth headers redacted), the nonce found in the messages, and
whether a tool_result carried SENTINEL. Binds 127.0.0.1 on an ephemeral port written to PORT_FILE.
"""
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG, SCENARIO, READ_PATH, SENTINEL = sys.argv[1:6]
LOCK = threading.Lock()
STATE = {"n": 0}


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


def message(blocks, stop_reason):
    out = [sse("message_start", {"type": "message_start", "message": {
        "id": "msg_mock", "type": "message", "role": "assistant", "model": "deepseek-flash",
        "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": 11, "output_tokens": 1, "cache_read_input_tokens": 3}}})]
    for i, b in enumerate(blocks):
        if b["type"] == "text":
            out.append(sse("content_block_start", {"type": "content_block_start", "index": i,
                           "content_block": {"type": "text", "text": ""}}))
            out.append(sse("content_block_delta", {"type": "content_block_delta", "index": i,
                           "delta": {"type": "text_delta", "text": b["text"]}}))
        elif b["type"] == "tool_use":
            out.append(sse("content_block_start", {"type": "content_block_start", "index": i,
                           "content_block": {"type": "tool_use", "id": b["id"],
                                             "name": b["name"], "input": {}}}))
            out.append(sse("content_block_delta", {"type": "content_block_delta", "index": i,
                           "delta": {"type": "input_json_delta",
                                     "partial_json": json.dumps(b["input"])}}))
        out.append(sse("content_block_stop", {"type": "content_block_stop", "index": i}))
    out.append(sse("message_delta", {"type": "message_delta",
                   "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                   "usage": {"output_tokens": 42}}))
    out.append(sse("message_stop", {"type": "message_stop"}))
    return b"".join(out)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        with LOCK, open(LOG, "a") as f:
            f.write(json.dumps({"method": "GET", "path": self.path}) + "\n")
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        try:
            req = json.loads(body)
        except ValueError:
            req = {"_raw": body.decode(errors="replace")[:2000]}
        msgs = req.get("messages", []) if isinstance(req, dict) else []
        nonces = re.findall(r"VERDICT-([0-9a-f]{16}):", json.dumps(msgs))
        nonce = nonces[-1] if nonces else None
        results = [c for m in msgs if isinstance(m.get("content"), list)
                   for c in m["content"] if c.get("type") == "tool_result"]
        seen = any(SENTINEL in json.dumps(c) for c in results)
        hdrs = {k.lower(): ("<redacted>" if k.lower() in ("x-api-key", "authorization") else v)
                for k, v in self.headers.items()}
        with LOCK:
            STATE["n"] += 1
            with open(LOG, "a") as f:
                f.write(json.dumps({"n": STATE["n"], "method": "POST", "path": self.path,
                                    "headers": hdrs, "body": req, "nonce": nonce,
                                    "sentinel_seen": seen}) + "\n")
        if not results:
            payload = message([{"type": "tool_use", "id": "toolu_mock1", "name": "read",
                                "input": {"file_path": READ_PATH}}], "tool_use")
        elif SCENARIO == "max_tokens":
            payload = message([{"type": "text", "text": "partial answer cut off"}], "max_tokens")
        elif SCENARIO == "refusal":
            payload = message([{"type": "text", "text": "I can't help with that."}], "refusal")
        elif SCENARIO == "answer_any" and nonce:
            payload = message([{"type": "text",
                                "text": f"Mock review: answered without the sentinel.\nVERDICT-{nonce}: NO FINDINGS"}],
                              "end_turn")
        elif seen and nonce:
            payload = message([{"type": "text",
                                "text": f"Mock review: sentinel seen.\nVERDICT-{nonce}: NO FINDINGS"}],
                              "end_turn")
        else:
            payload = message([{"type": "text", "text": "SENTINEL NOT SEEN"}], "end_turn")
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
# Rename only once the port is fully written, so a poller never reads a partial number.
os.replace(PORT_FILE + ".tmp", PORT_FILE)
srv.serve_forever()
