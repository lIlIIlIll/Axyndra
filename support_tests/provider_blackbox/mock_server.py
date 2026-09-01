#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def text_events(text, response_id):
    item_id = f"msg_{response_id}"
    complete_item = {
        "type": "message",
        "id": item_id,
        "role": "assistant",
        "status": "completed",
        "content": [
            {
                "type": "output_text",
                "text": text,
                "annotations": [],
            }
        ],
    }
    return [
        {
            "type": "response.created",
            "response": {
                "id": response_id,
                "status": "in_progress",
                "output": [],
            },
        },
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "type": "message",
                "id": item_id,
                "role": "assistant",
                "status": "in_progress",
                "content": [],
            },
        },
        {
            "type": "response.content_part.added",
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "part": {
                "type": "output_text",
                "text": "",
                "annotations": [],
            },
        },
        {
            "type": "response.output_text.delta",
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "delta": text,
        },
        {
            "type": "response.output_text.done",
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "text": text,
        },
        {
            "type": "response.content_part.done",
            "item_id": item_id,
            "output_index": 0,
            "content_index": 0,
            "part": complete_item["content"][0],
        },
        {
            "type": "response.output_item.done",
            "output_index": 0,
            "item_id": item_id,
            "item": complete_item,
        },
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "status": "completed",
                "output": [complete_item],
                "usage": {
                    "input_tokens": 2,
                    "output_tokens": 1,
                },
            },
        },
    ]


def tool_events(call, response_id):
    return [
        {
            "type": "response.created",
            "response": {
                "id": response_id,
                "status": "in_progress",
                "output": [],
            },
        },
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": call,
        },
        {
            "type": "response.function_call_arguments.done",
            "output_index": 0,
            "item_id": call["id"],
            "name": call["name"],
            "arguments": call["arguments"],
        },
        {
            "type": "response.output_item.done",
            "output_index": 0,
            "item_id": call["id"],
            "item": call,
        },
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "status": "completed",
                "output": [call],
                "usage": {
                    "input_tokens": 3,
                    "output_tokens": 1,
                },
            },
        },
    ]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        serialized = json.dumps(request)
        if os.environ.get("AXYNDRA_MOCK_TRACE") == "1":
            print(serialized, file=sys.stderr, flush=True)
        slow = "cancel-smoke" in serialized or "timeout-smoke" in serialized
        if "provider-error" in serialized:
            # Deliberately avoid rate-limit words: classification must be
            # driven by the HTTP status rather than provider-specific prose.
            payload = json.dumps(
                {
                    "error": {
                        "type": "capacity",
                        "message": "please retry later",
                    }
                },
                separators=(",", ":"),
            ).encode()
            self.send_response(429)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return
        status_cases = {
            "authentication-401": (401, "authentication"),
            "authorization-403": (403, "authentication"),
            "request-timeout-408": (408, "timeout"),
            "gateway-timeout-504": (504, "timeout"),
            "provider-failure-500": (500, "provider"),
        }
        for sentinel, (status, label) in status_cases.items():
            if sentinel in serialized:
                payload = json.dumps(
                    {"error": {"type": "opaque", "message": label}},
                    separators=(",", ":"),
                ).encode()
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(payload)))
                self.send_header("connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                return
        if "context-overflow" in serialized:
            payload = json.dumps(
                {
                    "error": {
                        "code": "context_length_exceeded",
                        "message": "maximum context window exceeded",
                    }
                },
                separators=(",", ":"),
            ).encode()
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return
        if not request.get("stream"):
            self.send_error(400, "blackbox expects stream=true")
            return
        if self.path == "/v1/messages":
            message_text = (
                "axyndra-real-smoke-messages"
                if "axyndra-real-smoke-messages" in serialized
                else "messages-ok"
            )
            events = [
                {
                    "type": "message_start",
                    "message": {
                        "id": "msg_blackbox",
                        "content": [],
                        "usage": {"input_tokens": 2},
                    },
                },
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": message_text},
                },
                {"type": "content_block_stop", "index": 0},
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn"},
                    "usage": {"output_tokens": 1},
                },
                {"type": "message_stop"},
            ]
        elif self.path == "/v1/responses":
            read_tool = (
                "tool-blackbox" in serialized
                or "Use the read tool exactly once" in serialized
            )
            write_approval = "approval-proof.txt" in serialized
            if read_tool:
                if "function_call_output" in serialized:
                    successful_read = "tool fixture" in serialized
                    final_text = "tool-loop-bad"
                    if successful_read:
                        final_text = (
                            "axyndra-real-smoke-tool"
                            if "axyndra-real-smoke-tool" in serialized
                            else "tool-loop-ok"
                        )
                    events = text_events(final_text, "resp_tool_done")
                else:
                    call = {
                        "type": "function_call",
                        "id": "fc_blackbox",
                        "call_id": "call_blackbox",
                        "name": "read",
                        "arguments": json.dumps(
                            {
                                "path": (
                                    "tool-proof.txt"
                                    if "Use the read tool exactly once"
                                    in serialized
                                    else "tool.txt"
                                )
                            },
                            separators=(",", ":"),
                        ),
                    }
                    events = tool_events(call, "resp_tool_call")
            elif write_approval:
                if "function_call_output" in serialized:
                    events = text_events(
                        "approval-continue-ok",
                        "resp_approval_done",
                    )
                else:
                    call = {
                        "type": "function_call",
                        "id": "fc_approval",
                        "call_id": "call_approval",
                        "name": "write",
                        "arguments": (
                            '{"path":"../outside/approval-proof.txt",'
                            '"content":"approved"}'
                        ),
                    }
                    events = tool_events(call, "resp_approval")
            else:
                response_text = (
                    "axyndra-real-smoke-responses"
                    if "axyndra-real-smoke-responses" in serialized
                    else "responses-ok"
                )
                events = text_events(response_text, "resp_blackbox")
        else:
            self.send_error(404)
            return

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        for event in events:
            try:
                self.wfile.write(
                    (
                        "data: "
                        + json.dumps(event, separators=(",", ":"))
                        + "\n\n"
                    ).encode()
                )
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            time.sleep(2.0 if slow else 0.03)

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--port-file")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if args.port_file:
        port_file = args.port_file + ".tmp"
        with open(port_file, "w", encoding="utf-8") as stream:
            stream.write(str(server.server_address[1]) + "\n")
        os.replace(port_file, args.port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
