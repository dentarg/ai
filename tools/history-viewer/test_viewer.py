#!/usr/bin/env python3
"""Tests for the history-viewer agent session support.

Run from this directory:

    python3 -m unittest test_viewer -v
"""
import json
import tempfile
import unittest
from pathlib import Path

import viewer


def write_rollout(events: list[dict]) -> Path:
    """Write events as a Codex-style jsonl to a temp file and return its path."""
    tmp = tempfile.NamedTemporaryFile(
        mode="w", suffix=".jsonl", delete=False, encoding="utf-8")
    for e in events:
        tmp.write(json.dumps(e) + "\n")
    tmp.close()
    return Path(tmp.name)


def write_pi_session(events: list[dict]) -> Path:
    """Write events as a Pi session jsonl to a temporary file."""
    return write_rollout(events)


class SummarizeCodexSession(unittest.TestCase):
    def test_metadata_tokens_and_cost(self):
        events = [
            {"timestamp": "2026-06-08T20:00:00Z", "type": "session_meta",
             "payload": {"id": "abc-123", "cwd": "/app", "cli_version": "0.136.0",
                         "git": {"branch": "my-branch",
                                 "repository_url": "git@github.com:acme/widgets.git"}}},
            {"timestamp": "2026-06-08T20:00:01Z", "type": "turn_context",
             "payload": {"model": "gpt-5.5"}},
            {"timestamp": "2026-06-08T20:00:02Z", "type": "event_msg",
             "payload": {"type": "user_message", "message": "hello there"}},
            {"timestamp": "2026-06-08T20:00:03Z", "type": "event_msg",
             "payload": {"type": "agent_message", "message": "hi"}},
            {"timestamp": "2026-06-08T20:00:09Z", "type": "event_msg",
             "payload": {"type": "token_count", "info": {"total_token_usage": {
                 "input_tokens": 1000, "cached_input_tokens": 400,
                 "output_tokens": 200}}}},
        ]
        path = write_rollout(events)
        try:
            s = viewer.summarize_codex_session(path)
        finally:
            path.unlink()

        self.assertEqual(s["sessionId"], "abc-123")
        self.assertEqual(s["gitBranch"], "my-branch")
        self.assertEqual(s["repo"], "widgets")  # from repo url, not cwd basename
        self.assertEqual(s["firstPrompt"], "hello there")
        self.assertEqual(s["models"], ["gpt-5.5"])
        self.assertEqual((s["userMessages"], s["assistantMessages"], s["messages"]),
                         (1, 1, 2))
        # OpenAI input includes the cached portion; we split it out.
        self.assertEqual(s["tokens"]["input_tokens"], 600)
        self.assertEqual(s["tokens"]["cache_read_tokens"], 400)
        self.assertEqual(s["tokens"]["output_tokens"], 200)
        # gpt-5.5: 600*5 + 400*0.5 + 200*30 = 9200 micro-USD.
        self.assertAlmostEqual(s["cost"], 0.0092, places=6)
        self.assertEqual(s["costByModel"], {"gpt-5.5": 0.0092})

    def test_current_response_item_schema(self):
        events = [
            {"timestamp": "2026-09-01T00:00:00Z", "type": "session_meta",
             "payload": {"session_id": "current-123",
                         "cwd": "/tmp/codex-host-cwd.test/docker-image",
                         "cli_version": "0.151.0"}},
            {"timestamp": "2026-09-01T00:00:01Z", "type": "turn_context",
             "payload": {"model": "gpt-5.6-luna"}},
            {"timestamp": "2026-09-01T00:00:02Z", "type": "response_item",
             "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text",
                                      "text": "# AGENTS.md instructions\ninternal context"}]}},
            {"timestamp": "2026-09-01T00:00:03Z", "type": "response_item",
             "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text", "text": "fix the viewer"}]}},
            {"timestamp": "2026-09-01T00:00:04Z", "type": "response_item",
             "payload": {"type": "message", "role": "assistant",
                         "content": [{"type": "output_text", "text": "done"}]}},
        ]
        path = write_rollout(events)
        try:
            s = viewer.summarize_codex_session(path)
        finally:
            path.unlink()

        self.assertEqual(s["sessionId"], "current-123")
        self.assertEqual(s["cwd"], "/tmp/codex-host-cwd.test/docker-image")
        self.assertEqual(s["name"], "docker-image")
        self.assertEqual(s["firstPrompt"], "fix the viewer")
        self.assertEqual((s["userMessages"], s["assistantMessages"], s["messages"]),
                         (1, 1, 2))


class CodexToTranscript(unittest.TestCase):
    def test_turn_grouping(self):
        raw = [
            {"type": "session_meta", "payload": {"id": "abc"}},
            {"type": "turn_context", "payload": {"model": "gpt-5.5"}},
            {"type": "event_msg", "payload": {"type": "user_message",
                                              "message": "do the thing"}},
            # Raw context items that must be dropped, not rendered.
            {"type": "response_item", "payload": {"type": "message", "role": "developer",
                                                  "content": [{"type": "input_text", "text": "instructions"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                  "content": [{"type": "input_text", "text": "env"}]}},
            {"type": "response_item", "payload": {"type": "reasoning",
                                                  "encrypted_content": "xxx", "summary": []}},
            # agent_message duplicates the assistant message below — dropped.
            {"type": "event_msg", "payload": {"type": "agent_message", "message": "Working on it."}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                  "content": [{"type": "output_text", "text": "Working on it."}]}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "exec_command",
                                                  "arguments": "{\"cmd\": \"ls\"}", "call_id": "c1"}},
            {"type": "response_item", "payload": {"type": "function_call_output",
                                                  "call_id": "c1", "output": "file.txt"}},
            {"type": "event_msg", "payload": {"type": "token_count",
                                              "info": {"total_token_usage": {"input_tokens": 1}}}},
        ]
        ev = viewer.codex_to_transcript(raw)
        kinds = [e["type"] for e in ev]

        # One real user prompt, one grouped assistant turn, one tool-result group.
        users = [e for e in ev if e["type"] == "user"]
        assistants = [e for e in ev if e["type"] == "assistant"]
        self.assertEqual(len(assistants), 1)

        prompt = next(e for e in users if isinstance(e["message"]["content"], str))
        self.assertEqual(prompt["message"]["content"], "do the thing")

        turn = assistants[0]
        self.assertEqual(turn["message"]["model"], "gpt-5.5")
        blocks = turn["message"]["content"]
        self.assertEqual([b["type"] for b in blocks], ["thinking", "text", "tool_use"])
        self.assertEqual(blocks[0]["thinking"], viewer.CODEX_REASONING_PLACEHOLDER)
        self.assertEqual(blocks[1]["text"], "Working on it.")
        # function_call arguments parsed from JSON string into an object.
        self.assertEqual(blocks[2]["name"], "exec_command")
        self.assertEqual(blocks[2]["input"], {"cmd": "ls"})

        result_group = next(e for e in users if isinstance(e["message"]["content"], list))
        result = result_group["message"]["content"][0]
        self.assertEqual(result["type"], "tool_result")
        self.assertEqual(result["content"], "file.txt")

        # The dropped context strings never appear in any rendered block.
        self.assertNotIn("instructions", json.dumps(ev))
        self.assertNotIn("env", json.dumps(ev))

    def test_current_response_item_messages(self):
        raw = [
            {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                      "content": [{"type": "input_text",
                                                                   "text": "# AGENTS.md instructions\ncontext"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                      "content": [{"type": "input_text",
                                                                   "text": "show the prompt"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                      "content": [{"type": "output_text",
                                                                   "text": "here it is"}]}},
            {"type": "response_item", "payload": {"type": "custom_tool_call",
                                                      "name": "exec", "input": "ls"}},
            {"type": "response_item", "payload": {"type": "custom_tool_call_output",
                                                      "output": "file.txt"}},
        ]
        ev = viewer.codex_to_transcript(raw)

        users = [e for e in ev if e["type"] == "user"]
        prompts = [e["message"]["content"] for e in users
                   if isinstance(e["message"]["content"], str)]
        self.assertEqual(prompts, ["show the prompt"])
        assistant = next(e for e in ev if e["type"] == "assistant")
        self.assertEqual([b["type"] for b in assistant["message"]["content"]],
                         ["text", "tool_use"])
        self.assertEqual(assistant["message"]["content"][1]["name"], "exec")
        result = next(e for e in users if isinstance(e["message"]["content"], list))
        self.assertEqual(result["message"]["content"][0]["content"], "file.txt")


class PiSession(unittest.TestCase):
    def setUp(self):
        self.events = [
            {"type": "session", "version": 3, "id": "pi-session",
             "timestamp": "2026-09-02T20:00:00Z", "cwd": "/app/widgets"},
            {"type": "message", "id": "u1", "parentId": None,
             "timestamp": "2026-09-02T20:00:01Z",
             "message": {"role": "user", "content": "build the widget"}},
            {"type": "message", "id": "a1", "parentId": "u1",
             "timestamp": "2026-09-02T20:00:02Z",
             "message": {
                 "role": "assistant", "provider": "llama-cpp",
                 "model": "gemma4", "stopReason": "toolUse",
                 "content": [
                     {"type": "thinking", "thinking": "inspect first"},
                     {"type": "toolCall", "id": "call-1", "name": "bash",
                      "arguments": {"command": "ls"}},
                 ],
                 "usage": {
                     "input": 100, "output": 20, "cacheRead": 10,
                     "cacheWrite": 5, "totalTokens": 135,
                     "cost": {"total": 0},
                 },
             }},
            {"type": "message", "id": "r1", "parentId": "a1",
             "timestamp": "2026-09-02T20:00:03Z",
             "message": {"role": "toolResult", "toolCallId": "call-1",
                         "toolName": "bash", "content": [
                             {"type": "text", "text": "README.md"}],
                         "isError": False}},
            {"type": "message", "id": "abandoned", "parentId": "r1",
             "timestamp": "2026-09-02T20:00:03Z",
             "message": {"role": "user", "content": "abandoned branch"}},
            {"type": "session_info", "id": "n1", "parentId": "r1",
             "timestamp": "2026-09-02T20:00:04Z", "name": "Widget work"},
        ]

    def test_summary_and_transcript(self):
        path = write_pi_session(self.events)
        try:
            summary = viewer.summarize_pi_session(path)
            transcript = viewer.pi_to_transcript(self.events)
        finally:
            path.unlink()

        self.assertEqual(summary["sessionId"], "pi-session")
        self.assertEqual(summary["name"], "Widget work")
        self.assertEqual(summary["repo"], "widgets")
        self.assertEqual(summary["firstPrompt"], "build the widget")
        self.assertEqual(summary["models"], ["gemma4"])
        self.assertEqual(summary["tokens"]["input_tokens"], 100)
        self.assertEqual(summary["tokens"]["cache_read_tokens"], 10)
        self.assertEqual(summary["tokens"]["cache_creation_tokens"], 5)

        self.assertEqual([event["type"] for event in transcript],
                         ["user", "assistant", "user", "session_info"])
        assistant = transcript[1]
        self.assertEqual([block["type"] for block in
                          assistant["message"]["content"]],
                         ["thinking", "tool_use"])
        self.assertEqual(assistant["message"]["content"][1]["input"],
                         {"command": "ls"})
        result = transcript[2]["message"]["content"][0]
        self.assertEqual(result["type"], "tool_result")
        self.assertEqual(result["content"][0]["text"], "README.md")
        self.assertNotIn("abandoned branch", json.dumps(transcript))

    def test_manifest_discovers_pi_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session_dir = root / "pi" / "--app-widgets--"
            session_dir.mkdir(parents=True)
            session = session_dir / "2026-09-02T20-00-00_pi-session.jsonl"
            session.write_text(
                "".join(json.dumps(event) + "\n" for event in self.events),
                encoding="utf-8")

            sessions = viewer.build_manifest(root)
            resolved = viewer.ViewerState(root).resolve_session_path(
                session.relative_to(root).as_posix())

        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["tool"], "pi")
        self.assertEqual(sessions[0]["project"], "widgets")
        self.assertEqual(resolved, session.resolve())


class ManifestSorting(unittest.TestCase):
    def _write_codex_run(self, root: Path, run_dir: str,
                         started: str, ended: str, sid: str) -> None:
        sess = root / "2026" / "06_Jun" / run_dir / "sessions" / "2026" / "06" / "08"
        sess.mkdir(parents=True, exist_ok=True)
        events = [
            {"timestamp": started, "type": "session_meta",
             "payload": {"id": sid, "cwd": "/app"}},
            {"timestamp": ended, "type": "event_msg",
             "payload": {"type": "user_message", "message": "hi"}},
        ]
        (sess / f"rollout-{sid}.jsonl").write_text(
            "".join(json.dumps(e) + "\n" for e in events), encoding="utf-8")

    def test_sorted_by_last_updated_not_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # Started earlier, but stayed active the longest.
            self._write_codex_run(root, "08_Mon_10-00_codex",
                                   "2026-06-08T10:00:00Z", "2026-06-08T15:00:00Z", "long")
            # Started later, but went idle sooner.
            self._write_codex_run(root, "08_Mon_12-00_codex",
                                   "2026-06-08T12:00:00Z", "2026-06-08T12:30:00Z", "short")
            sessions = viewer.build_manifest(root)

        # Most recently updated first, even though it started before the other.
        self.assertEqual([s["sessionId"] for s in sessions], ["long", "short"])
        self.assertEqual(sessions[0]["endedAt"], "2026-06-08T15:00:00Z")


class PublishToPastehtml(unittest.TestCase):
    def _recorder(self, responses: list[tuple[int, dict]]):
        """Fake _pastehtml_call: records requests, replays canned responses."""
        calls = []

        def call(method, url, body, headers):
            calls.append({"method": method, "url": url,
                          "body": body, "headers": headers})
            return responses[len(calls) - 1]
        return calls, call

    def test_creates_paste_when_no_token(self):
        calls, call = self._recorder([(201, {"token": "t1", "update_token": "u1"})])
        status, payload = viewer.publish_to_pastehtml(
            "<html></html>", "my session.html", call=call)

        self.assertEqual(status, 201)
        self.assertEqual(payload["update_token"], "u1")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["method"], "POST")
        # Filename is URL-quoted into the query string; body is the raw HTML.
        self.assertTrue(calls[0]["url"].endswith("?filename=my%20session.html"))
        self.assertEqual(calls[0]["body"], b"<html></html>")
        self.assertEqual(calls[0]["headers"], {})

    def test_updates_existing_paste_with_token(self):
        calls, call = self._recorder([(200, {"token": "t1"})])
        status, payload = viewer.publish_to_pastehtml(
            "<html></html>", "s.html",
            token="t1", update_token="u1", call=call)

        self.assertEqual(status, 200)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["method"], "PATCH")
        self.assertTrue(calls[0]["url"].endswith("/t1"))
        self.assertEqual(calls[0]["headers"], {"Authorization": "Bearer u1"})

    def test_stale_token_falls_back_to_create(self):
        calls, call = self._recorder([
            (404, {"error": "not found"}),
            (201, {"token": "t2", "update_token": "u2"}),
        ])
        status, payload = viewer.publish_to_pastehtml(
            "<html></html>", "s.html",
            token="gone", update_token="u1", call=call)

        self.assertEqual(status, 201)
        self.assertEqual(payload["token"], "t2")
        self.assertEqual([c["method"] for c in calls], ["PATCH", "POST"])


if __name__ == "__main__":
    unittest.main()
