#!/usr/bin/env python3
"""Offline integration checks. No provider, tunnel or live webhook calls."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock

spec = importlib.util.spec_from_file_location("bist_bobot", Path(__file__).resolve().parents[1] / "scripts/bist-bobot.py")
bridge_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge_module)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sent = []
        def deliver(url, secret, sid, event_id, body):
            event = json.loads(body)
            self.sent.append((sid, event_id, event))
            return 200, json.dumps({"challenge": event.get("challenge")}).encode()
        self.bridge = bridge_module.Bridge(self.root, deliver)
        self.job_id = str(uuid.uuid4())
        self.claim = str(uuid.uuid4())
        self.execution = self.claim
        self.job = {"id": self.job_id, "taskID": str(uuid.uuid4()), "title": "Unicode 🧡", "details": "Exact task snapshot",
                    "state": "queued", "revision": 0, "createdAt": time.time(), "updatedAt": time.time(), "progress": "", "questions": []}
        bridge_module.write_file(self.root / "bobot-jobs.json", {"version": 1, "jobs": [self.job]})
        self.params = {"name": bridge_module.EVENT, "arguments": {}, "delivery": {"mode": "webhook", "url": "https://example.com/callback", "secret": "whsec_" + base64.b64encode(b"x" * 32).decode()}}

    def update(self, state, message="Progress", **extra):
        job = self.bridge.tool("read_job", {"job_id": self.job_id})
        return self.bridge.tool("update_job", {"job_id": self.job_id, "claim_id": self.claim, "execution_id": self.execution, "revision": job["revision"], "state": state, "message": message, **extra})

    def test_assignment_question_answer_completion(self):
        self.bridge.subscribe(self.params)
        self.bridge.tick()
        event = self.sent[-1][2]
        self.assertEqual(event["data"], {"job_id": self.job_id, "revision": 0, "reason": "assigned"})
        claimed = self.bridge.tool("claim_job", {"job_id": self.job_id, "claim_id": self.claim})
        self.assertEqual(claimed["state"], "working")
        self.update("waiting", "Which source?")
        with self.assertRaises(ValueError):
            self.update("completed", "Cannot finish before answer")
        # Same locked/atomic file update used by the native answer action.
        with bridge_module.locked(self.root, "bobot-jobs"):
            value = bridge_module.ledger(self.root)
            job = value["jobs"][0]
            job["questions"][0]["answer"] = "This one 🧡"
            job["state"] = "ready"
            job["revision"] += 1
            bridge_module.write_file(self.root / "bobot-jobs.json", value)
        self.bridge.tick()
        self.assertEqual(self.sent[-1][2]["data"]["reason"], "answered")
        self.assertNotEqual(event["eventId"], self.sent[-1][2]["eventId"])
        restarted = bridge_module.Bridge(self.root)
        self.assertEqual(restarted.tool("read_job", {"job_id": self.job_id})["questions"][0]["answer"], "This one 🧡")
        self.execution = str(uuid.uuid4())
        ready = self.bridge.tool("read_job", {"job_id": self.job_id})
        self.bridge.tool("resume_job", {"job_id": self.job_id, "claim_id": self.claim, "answer_revision": ready["revision"], "execution_id": self.execution})
        with self.assertRaises(ValueError):
            self.bridge.tool("resume_job", {"job_id": self.job_id, "claim_id": self.claim, "answer_revision": ready["revision"], "execution_id": str(uuid.uuid4())})
        self.update("working", "Using your answer")
        result = self.update("completed", "Output ready", result_url="https://example.com/output")
        self.assertEqual(result["resultURL"], "https://example.com/output")
        self.assertEqual(result["state"], "completed")
        with self.assertRaises(ValueError):
            self.update("working", "Must not restart")
        self.assertFalse((self.root / "state.json").exists())

    def test_claim_retries_and_wrong_worker(self):
        args = {"job_id": self.job_id, "claim_id": self.claim}
        first = self.bridge.tool("claim_job", args)
        self.assertEqual(first, self.bridge.tool("claim_job", args))
        with self.assertRaises(ValueError):
            self.bridge.tool("claim_job", {**args, "claim_id": str(uuid.uuid4())})
        with self.assertRaises(ValueError):
            self.bridge.tool("update_job", {**args, "execution_id": self.claim, "revision": 0, "state": "completed", "message": "stale"})

    def test_cancellation_wins_over_late_callback(self):
        self.bridge.tool("claim_job", {"job_id": self.job_id, "claim_id": self.claim})
        value = bridge_module.ledger(self.root)
        value["jobs"][0]["state"] = "cancelled"
        value["jobs"][0]["revision"] += 1
        bridge_module.write_file(self.root / "bobot-jobs.json", value)
        with self.assertRaises(ValueError):
            self.update("completed", "Late result")
        self.assertEqual(bridge_module.ledger(self.root)["jobs"][0]["state"], "cancelled")

    def test_subscription_restart_refresh_unsubscribe(self):
        first = self.bridge.subscribe(self.params)
        self.bridge.tick()
        count = len(self.sent)
        restarted = bridge_module.Bridge(self.root, self.bridge.deliver)
        restarted.tick()
        self.assertEqual(len(self.sent), count, "Accepted event is not redelivered after restart")
        refreshed = restarted.subscribe(self.params)
        self.assertEqual(first["id"], refreshed["id"])
        restarted.tick()
        self.assertEqual(len(self.sent), count + 1, "Refresh verifies callback but preserves receipts")
        restarted.rpc({"method": "events/unsubscribe", "params": self.params})
        restarted.tick()
        self.assertFalse(json.loads((self.root / "bobot-connection.json").read_text())["subscribed"])

    def test_expired_subscription_does_not_deliver(self):
        result = self.bridge.subscribe({**self.params, "ttlMs": 1})
        values = self.bridge.subscriptions()
        values[result["id"]]["expires"] = time.time() - 1
        bridge_module.write_file(self.root / ".bobot-subscriptions.json", values)
        self.bridge.tick()
        self.assertEqual(len(self.sent), 1)

    def test_failed_verification_keeps_secrets_out_of_result(self):
        self.bridge.deliver = lambda *args: (200, b'{"challenge":"wrong"}')
        with self.assertRaises(ValueError):
            self.bridge.subscribe(self.params)
        self.assertFalse(self.bridge.subscriptions())

    def test_transient_retry_and_permanent_stop(self):
        result = self.bridge.subscribe(self.params)
        self.bridge.deliver = lambda *args: (503, b"")
        self.bridge.tick()
        values = self.bridge.subscriptions()
        receipt = next(iter(values[result["id"]]["receipts"].values()))
        self.assertFalse(receipt["accepted"])
        self.assertEqual(receipt["attempts"], 1)
        receipt["next"] = 0
        bridge_module.write_file(self.root / ".bobot-subscriptions.json", values)
        self.bridge.deliver = lambda *args: (410, b"")
        self.bridge.tick()
        receipt = next(iter(self.bridge.subscriptions()[result["id"]]["receipts"].values()))
        self.assertTrue(receipt["stopped"])

    def test_callback_blocks_private_dns_and_invalid_urls_before_connect(self):
        key = self.params["delivery"]["secret"]
        for url in ("http://example.com", "https://user:password@example.com", "https://example.com:444"):
            with self.assertRaises(ValueError):
                bridge_module.callback(url, key, "s", "e", b"{}")
        with mock.patch.object(bridge_module.socket, "getaddrinfo", return_value=[(2, 1, 6, "", ("127.0.0.1", 443))]), mock.patch.object(bridge_module.socket, "create_connection") as connect:
            with self.assertRaises(ValueError):
                bridge_module.callback("https://example.com", key, "s", "e", b"{}")
            connect.assert_not_called()

    def test_callback_signs_exact_body_and_pins_public_ip(self):
        raw = mock.Mock()
        wrapped = mock.Mock()
        response = mock.Mock(status=200)
        response.read.return_value = b"{}"
        connection = mock.Mock()
        connection.getresponse.return_value = response
        import hashlib
        import hmac
        with mock.patch.object(bridge_module.socket, "getaddrinfo", return_value=[(2, 1, 6, "", ("8.8.8.8", 443))]), mock.patch.object(bridge_module.socket, "create_connection", return_value=raw) as connect, mock.patch.object(bridge_module.ssl, "create_default_context") as ssl_context, mock.patch.object(bridge_module.http.client, "HTTPSConnection", return_value=connection):
            ssl_context.return_value.wrap_socket.return_value = wrapped
            bridge_module.callback("https://example.com/callback", self.params["delivery"]["secret"], "s", "evt", b'{"exact":true}')
            self.assertEqual(connect.call_args.args[0], ("8.8.8.8", 443))
            self.assertEqual(ssl_context.return_value.wrap_socket.call_args.kwargs["server_hostname"], "example.com")
            headers = connection.request.call_args.kwargs["headers"]
            signature = base64.b64encode(hmac.new(b"x" * 32, ("evt." + headers["webhook-timestamp"] + ".").encode() + b'{"exact":true}', hashlib.sha256).digest()).decode()
            self.assertEqual(headers["webhook-signature"], "v1," + signature)

    def test_malformed_and_symlink_queues_are_preserved(self):
        file = self.root / "bobot-jobs.json"
        file.write_text("broken")
        with self.assertRaises(ValueError):
            self.bridge.tool("list_jobs", {})
        self.assertEqual(file.read_text(), "broken")
        file.unlink()
        target = self.root / "target"
        target.write_text("private")
        file.symlink_to(target)
        with self.assertRaises(OSError):
            self.bridge.tool("list_jobs", {})
        self.assertEqual(target.read_text(), "private")

    def test_stdio_discovery_and_error_redaction(self):
        requests = [{"jsonrpc": "2.0", "id": 1, "method": "server/discover"},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                    {"jsonrpc": "2.0", "id": 3, "method": "events/list"},
                    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "list_jobs", "arguments": {}}}]
        result = subprocess.run([sys.executable, str(spec.origin), "--data-dir", str(self.root)], input="\n".join(json.dumps(r) for r in requests) + "\n", text=True, capture_output=True, check=True)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), 4)
        self.assertEqual(responses[0]["result"]["supportedVersions"], [bridge_module.VERSION])
        self.assertEqual(len(responses[1]["result"]["tools"]), 5)
        self.assertEqual(responses[2]["result"]["events"][0]["name"], bridge_module.EVENT)
        self.assertIn(self.job_id, responses[3]["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
