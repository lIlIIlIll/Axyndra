#!/usr/bin/env python3
"""Two additional actual-package usage contracts; the original 51 stay intact."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import unittest
import check as original


def usage_body(api, streaming, absent):
    def replace_usage(value):
        if not isinstance(value, dict):
            return
        if "usage" in value:
            if absent:
                value.pop("usage")
            else:
                def zero_numbers(found):
                    if isinstance(found, dict):
                        return {key: zero_numbers(item) for key, item in found.items()}
                    if isinstance(found, int) and not isinstance(found, bool):
                        return 0
                    return found
                value["usage"] = zero_numbers(value["usage"])
        for field in ["message", "response"]:
            replace_usage(value.get(field))

    if not streaming:
        value = copy.deepcopy(original.response(api))
        replace_usage(value)
        return original.encoded(value)
    lines = []
    for line in original.stream_response(api).splitlines(keepends=True):
        if line.startswith(b"data: ") and line.strip() != b"data: [DONE]":
            value = json.loads(line[6:])
            replace_usage(value)
            line = b"data: " + original.encoded(value) + b"\n"
        lines.append(line)
    return b"".join(lines)


class ModelUsagePresenceProtocolTests(unittest.TestCase):
    def run_usage_contract(self, absent):
        for api in ["chat", "responses", "messages"]:
            for streaming in [False, True]:
                with self.subTest(api=api, streaming=streaming), original.Peer() as peer:
                    events = peer.run(original.fixture(api, streaming),
                                      usage_body(api, streaming, absent), chunk=1 if streaming else 5)
                    replies = [event["payload"] for event in events if event["kind"] == "reply"]
                    self.assertEqual(len(replies), 1)
                    reply = replies[0]
                    self.assertEqual("".join(block["text"] for block in reply["blocks"]), "answer 雪")
                    self.assertTrue(reply["accepted"])
                    usage = reply["usage"]
                    self.assertEqual(set(usage), {"input", "output", "reasoning", "cache_read",
                                                 "cache_write", "cost_micros", "source", "evidence"})
                    for field in ["input", "output", "reasoning", "cache_read", "cache_write"]:
                        self.assertEqual(usage[field], 0)
                    self.assertIsNone(usage["cost_micros"])
                    if absent:
                        self.assertEqual(usage["source"], "unknown")
                        self.assertIsNone(usage["evidence"])
                    else:
                        self.assertEqual(usage["source"], "provider_stream_final" if streaming else "provider_final")
                        protocol = {"chat": "chat_completions", "responses": "responses", "messages": "messages"}[api]
                        event = {"chat": "finish_reason", "responses": "response.completed",
                                 "messages": "message_stop"}[api] if streaming else "response_body"
                        self.assertEqual(usage["evidence"], {"protocol": protocol, "event": event,
                                                            "response_id": "response-1"})
                    self.assertTrue(reply["terminal"]["message_terminal"])
                    self.assertEqual(sum(row["action"] == "open" for row in peer.requests), 1)
                    self.assertEqual(peer.requests[-1]["action"], "close")
                    self.assertEqual(peer.stderr, b"")

    def test_complete_reply_without_usage_preserves_unknown_accounting(self):
        self.run_usage_contract(True)

    def test_explicit_provider_zero_usage_retains_evidence(self):
        self.run_usage_contract(False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    original.BINARY = args.package.resolve() / "bin/model-providers"
    if not original.BINARY.is_file():
        parser.error("actual independent package is required")
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ModelUsagePresenceProtocolTests))
    summary = {"executed": result.testsRun, "failures": len(result.failures),
               "errors": len(result.errors), "skipped": len(result.skipped),
               "entry_sha256": hashlib.sha256(original.BINARY.read_bytes()).hexdigest()}
    args.summary.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() and result.testsRun == 2 and not result.skipped else 1)
