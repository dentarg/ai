#!/usr/bin/env python3
"""Tests for the history-viewer Codex support.

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


if __name__ == "__main__":
    unittest.main()
