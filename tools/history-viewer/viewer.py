#!/usr/bin/env python3
"""Browse Claude Code, Codex, and Pi session history in a local web viewer.

Serves a static HTML SPA plus a small JSON API over a directory of
archived agent snapshots (default: /history).
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
RUN_DIR_RE = re.compile(r"^(\d{2})_([A-Za-z]{3})_(\d{2})-(\d{2})_(\w+)$")
MONTHS = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], start=1)}

# Per-model USD pricing per 1M tokens, from platform.claude.com/docs/en/about-claude/pricing
# Tuple: (input, output, cache_read, cache_write_5m, cache_write_1h)
PRICING_BY_MODEL: dict[str, tuple[float, float, float, float, float]] = {
    # Fable: top tier, above Opus
    "claude-fable-5":    (10.00, 50.00, 1.00, 12.50, 20.00),
    # Opus 4.5+: reduced pricing
    "claude-opus-4-8":   ( 5.00, 25.00, 0.50,  6.25, 10.00),
    "claude-opus-4-7":   ( 5.00, 25.00, 0.50,  6.25, 10.00),
    "claude-opus-4-6":   ( 5.00, 25.00, 0.50,  6.25, 10.00),
    "claude-opus-4-5":   ( 5.00, 25.00, 0.50,  6.25, 10.00),
    # Opus (older, deprecated pricing)
    "claude-opus-4-1":   (15.00, 75.00, 1.50, 18.75, 30.00),
    "claude-opus-4":     (15.00, 75.00, 1.50, 18.75, 30.00),
    "claude-opus-3":     (15.00, 75.00, 1.50, 18.75, 30.00),
    # Sonnet
    "claude-sonnet-4-6": ( 3.00, 15.00, 0.30,  3.75,  6.00),
    "claude-sonnet-4-5": ( 3.00, 15.00, 0.30,  3.75,  6.00),
    "claude-sonnet-4":   ( 3.00, 15.00, 0.30,  3.75,  6.00),
    "claude-sonnet-3-7": ( 3.00, 15.00, 0.30,  3.75,  6.00),
    # Haiku
    "claude-haiku-4-5":  ( 1.00,  5.00, 0.10,  1.25,  2.00),
    "claude-haiku-3-5":  ( 0.80,  4.00, 0.08,  1.00,  1.60),
    "claude-haiku-3":    ( 0.25,  1.25, 0.03,  0.30,  0.50),
}

# Per-model USD pricing per 1M tokens for OpenAI / Codex models, from
# openai.com/api/pricing. Tuple: (input, output, cached_input). OpenAI has no
# separate cache-write tiers, so the structure is simpler than the Claude one.
PRICING_BY_MODEL_OPENAI: dict[str, tuple[float, float, float]] = {
    "gpt-5.5":     (5.00, 30.00, 0.50),
    "gpt-5.4":     (2.50, 15.00, 0.25),
    "gpt-5.1":     (1.25, 10.00, 0.125),
    "gpt-5":       (1.25, 10.00, 0.125),
    "gpt-5-mini":  (0.25,  2.00, 0.025),
    "gpt-5-nano":  (0.05,  0.40, 0.005),
}


def pricing_for(model: str) -> tuple[float, float, float, float, float] | None:
    """Longest-prefix match against PRICING_BY_MODEL.

    Real model ids include date suffixes like `claude-opus-4-5-20251101`.
    """
    if not model:
        return None
    best = None
    for key in PRICING_BY_MODEL:
        if model == key or model.startswith(key + "-"):
            if best is None or len(key) > len(best):
                best = key
    return PRICING_BY_MODEL[best] if best else None


def event_cost(model: str, usage: dict) -> float:
    """Cost for a single assistant event in USD, honoring 5m/1h cache breakdown."""
    p = pricing_for(model)
    if not p:
        return 0.0
    p_in, p_out, p_cache_read, p_cache_5m, p_cache_1h = p
    in_tok = usage.get("input_tokens", 0) or 0
    out_tok = usage.get("output_tokens", 0) or 0
    cache_read = usage.get("cache_read_input_tokens", 0) or 0
    breakdown = usage.get("cache_creation") or {}
    cache_5m = breakdown.get("ephemeral_5m_input_tokens", 0) or 0
    cache_1h = breakdown.get("ephemeral_1h_input_tokens", 0) or 0
    if not (cache_5m or cache_1h):
        # Fallback when the breakdown is absent: bill 5-minute rate.
        cache_5m = usage.get("cache_creation_input_tokens", 0) or 0
    cost = (
        in_tok * p_in +
        out_tok * p_out +
        cache_read * p_cache_read +
        cache_5m * p_cache_5m +
        cache_1h * p_cache_1h
    ) / 1_000_000
    # US-only data residency adds a 1.1x multiplier on Opus 4.7/4.6 and newer.
    if usage.get("inference_geo") == "us":
        cost *= 1.1
    return cost


def openai_pricing_for(model: str) -> tuple[float, float, float] | None:
    """Longest-prefix match against PRICING_BY_MODEL_OPENAI.

    Codex reports ids like `gpt-5.5` or `gpt-5.5-codex`; the latter falls back
    to the `gpt-5.5` base rate.
    """
    if not model:
        return None
    best = None
    for key in PRICING_BY_MODEL_OPENAI:
        if model == key or model.startswith(key + "-"):
            if best is None or len(key) > len(best):
                best = key
    return PRICING_BY_MODEL_OPENAI[best] if best else None


def codex_cost(model: str, usage: dict) -> float:
    """Cost in USD for a Codex session's cumulative `total_token_usage`.

    OpenAI's `input_tokens` already includes the cached portion, so the freshly
    billed input is `input_tokens - cached_input_tokens`. `output_tokens`
    already includes reasoning tokens.
    """
    p = openai_pricing_for(model)
    if not p:
        return 0.0
    p_in, p_out, p_cached = p
    input_total = usage.get("input_tokens", 0) or 0
    cached = usage.get("cached_input_tokens", 0) or 0
    output = usage.get("output_tokens", 0) or 0
    fresh_in = max(0, input_total - cached)
    return (fresh_in * p_in + cached * p_cached + output * p_out) / 1_000_000


def log(event: str, **fields) -> None:
    parts = [f"at={event}"] + [f"{k}={v}" for k, v in fields.items()]
    print(" ".join(parts), file=sys.stderr, flush=True)


def parse_run_dir(year: str, month_dir: str, run_dir: str) -> dict | None:
    """Turn .../2026/04_Apr/24_Fri_14-02_claude into structured metadata.

    The middle token in the run dir is a weekday (e.g. Fri), not a month —
    the month comes from the parent dir.
    """
    mon_match = re.match(r"^(\d{2})_([A-Za-z]{3})$", month_dir)
    if not mon_match:
        return None
    mon_abbr = mon_match.group(2)
    if mon_abbr not in MONTHS:
        return None
    m = RUN_DIR_RE.match(run_dir)
    if not m:
        return None
    day, _weekday, hh, mm, tool = m.groups()
    iso = f"{year}-{MONTHS[mon_abbr]:02d}-{day}T{hh}:{mm}:00"
    return {"timestamp": iso, "tool": tool}


def first_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                return block.get("text", "")
    return ""


# Synthetic user messages that Claude Code injects around slash commands and local
# stdout/stderr. Skipping them lets us pick the real first prompt as the session title.
META_PREFIXES = (
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<command-stdout>",
    "<command-stderr>",
    "<local-command-stdout>",
    "<local-command-stderr>",
    "<local-command-caveat>",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
    "<system-reminder>",
    "<user-prompt-submit-hook>",
    "Caveat: The messages below were generated by the user",
)


def is_meta_user_text(text: str) -> bool:
    if not text:
        return True
    s = text.lstrip()
    return any(s.startswith(p) for p in META_PREFIXES)


CODEX_CONTEXT_PREFIXES = (
    "# AGENTS.md instructions",
    "<environment_context>",
)


def codex_text(content) -> str:
    """Extract visible text from a Codex message content value."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    texts = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") not in {
            "input_text", "output_text", "text",
        }:
            continue
        text = block.get("text")
        if isinstance(text, str) and text:
            texts.append(text)
    return "\n\n".join(texts)


def is_codex_meta_user_text(text: str) -> bool:
    if is_meta_user_text(text):
        return True
    s = text.lstrip()
    return any(s.startswith(p) for p in CODEX_CONTEXT_PREFIXES)


def summarize_session(path: Path) -> dict:
    """Read a jsonl once and extract summary metadata."""
    sid = None
    cwd = None
    branch = None
    version = None
    first_prompt = ""
    name = None
    msg_count = 0
    user_msgs = 0
    assistant_msgs = 0
    models: set[str] = set()
    totals = {"input_tokens": 0, "output_tokens": 0,
              "cache_read_tokens": 0, "cache_creation_tokens": 0,
              "cache_5m_tokens": 0, "cache_1h_tokens": 0}
    by_model: dict[str, dict[str, int]] = {}
    cost = 0.0
    cost_by_model: dict[str, float] = {}
    first_ts = None
    last_ts = None
    line_count = 0

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line_count += 1
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            sid = sid or evt.get("sessionId")
            cwd = cwd or evt.get("cwd")
            branch = branch or evt.get("gitBranch")
            version = version or evt.get("version")
            ts = evt.get("timestamp")
            if ts:
                first_ts = first_ts or ts
                last_ts = ts
            etype = evt.get("type")
            if etype == "summary":
                s = (evt.get("summary") or "").strip()
                if s:
                    name = s
            elif etype == "user":
                user_msgs += 1
                msg_count += 1
                if not first_prompt:
                    content = evt.get("message", {}).get("content")
                    text = first_text(content)
                    if text and not is_meta_user_text(text):
                        first_prompt = text[:300]
            elif etype == "assistant":
                assistant_msgs += 1
                msg_count += 1
                msg = evt.get("message", {}) or {}
                model = msg.get("model")
                if model:
                    models.add(model)
                usage = msg.get("usage") or {}
                in_tok = usage.get("input_tokens", 0) or 0
                out_tok = usage.get("output_tokens", 0) or 0
                cr_tok = usage.get("cache_read_input_tokens", 0) or 0
                cc_total = usage.get("cache_creation_input_tokens", 0) or 0
                breakdown = usage.get("cache_creation") or {}
                cc_5m = breakdown.get("ephemeral_5m_input_tokens", 0) or 0
                cc_1h = breakdown.get("ephemeral_1h_input_tokens", 0) or 0
                if not (cc_5m or cc_1h):
                    cc_5m = cc_total
                totals["input_tokens"] += in_tok
                totals["output_tokens"] += out_tok
                totals["cache_read_tokens"] += cr_tok
                totals["cache_creation_tokens"] += cc_total
                totals["cache_5m_tokens"] += cc_5m
                totals["cache_1h_tokens"] += cc_1h
                evt_cost = event_cost(model, usage)
                cost += evt_cost
                if model:
                    bucket = by_model.setdefault(model, {
                        "input_tokens": 0, "output_tokens": 0,
                        "cache_read_tokens": 0, "cache_creation_tokens": 0,
                    })
                    bucket["input_tokens"] += in_tok
                    bucket["output_tokens"] += out_tok
                    bucket["cache_read_tokens"] += cr_tok
                    bucket["cache_creation_tokens"] += cc_total
                    cost_by_model[model] = cost_by_model.get(model, 0.0) + evt_cost

    return {
        "sessionId": sid,
        "cwd": cwd,
        "repo": Path(cwd).name if cwd else None,
        "gitBranch": branch,
        "version": version,
        "name": name,
        "firstPrompt": first_prompt,
        "events": line_count,
        "messages": msg_count,
        "userMessages": user_msgs,
        "assistantMessages": assistant_msgs,
        "models": sorted(models),
        "tokens": totals,
        "tokensByModel": by_model,
        "cost": round(cost, 4),
        "costByModel": {m: round(c, 4) for m, c in cost_by_model.items()},
        "startedAt": first_ts,
        "endedAt": last_ts,
    }


def _codex_repo(cwd: str | None, repo_url: str | None) -> str | None:
    """Prefer the git remote's repo name; fall back to the cwd basename."""
    if repo_url:
        name = repo_url.rstrip("/").rsplit("/", 1)[-1]
        if name.endswith(".git"):
            name = name[:-4]
        if name:
            return name
    return Path(cwd).name if cwd else None


def summarize_codex_session(path: Path) -> dict:
    """Summarize a Codex rollout jsonl, returning the same shape as
    summarize_session so the manifest is agent-agnostic.

    Codex token usage is reported as a cumulative `total_token_usage`; we keep
    the last snapshot. OpenAI's input count includes the cached portion, so we
    split it into fresh input (`input_tokens`) and cache reads.
    """
    sid = None
    cwd = None
    branch = None
    repo_url = None
    version = None
    first_prompt = ""
    response_user_msgs = 0
    legacy_user_msgs = 0
    response_assistant_msgs = 0
    legacy_assistant_msgs = 0
    models: set[str] = set()
    primary_model = None
    last_usage: dict = {}
    first_ts = None
    last_ts = None
    line_count = 0

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line_count += 1
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = evt.get("timestamp")
            if ts:
                first_ts = first_ts or ts
                last_ts = ts
            etype = evt.get("type")
            payload = evt.get("payload") or {}
            ptype = payload.get("type")
            if etype == "session_meta":
                sid = sid or payload.get("id") or payload.get("session_id")
                cwd = cwd or payload.get("cwd")
                version = version or payload.get("cli_version")
                git = payload.get("git") or {}
                branch = branch or git.get("branch")
                repo_url = repo_url or git.get("repository_url")
            elif etype == "turn_context":
                cwd = cwd or payload.get("cwd")
                model = payload.get("model")
                if model:
                    models.add(model)
                    primary_model = model
            elif etype == "event_msg" and ptype == "user_message":
                legacy_user_msgs += 1
                text = (payload.get("message") or "").strip()
                if not first_prompt and not is_codex_meta_user_text(text):
                    first_prompt = text[:300]
            elif etype == "event_msg" and ptype == "agent_message":
                legacy_assistant_msgs += 1
            elif etype == "event_msg" and ptype == "token_count":
                usage = (payload.get("info") or {}).get("total_token_usage")
                if usage:
                    last_usage = usage
            elif etype == "response_item" and ptype == "message":
                role = payload.get("role")
                text = codex_text(payload.get("content"))
                if role == "user":
                    if not is_codex_meta_user_text(text):
                        response_user_msgs += 1
                        if not first_prompt and text.strip():
                            first_prompt = text.strip()[:300]
                elif role == "assistant":
                    response_assistant_msgs += 1

    user_msgs = response_user_msgs or legacy_user_msgs
    assistant_msgs = response_assistant_msgs or legacy_assistant_msgs

    input_total = last_usage.get("input_tokens", 0) or 0
    cached = last_usage.get("cached_input_tokens", 0) or 0
    output = last_usage.get("output_tokens", 0) or 0
    fresh_in = max(0, input_total - cached)
    totals = {
        "input_tokens": fresh_in,
        "output_tokens": output,
        "cache_read_tokens": cached,
        "cache_creation_tokens": 0,
        "cache_5m_tokens": 0,
        "cache_1h_tokens": 0,
    }
    cost = codex_cost(primary_model, last_usage)
    by_model: dict[str, dict[str, int]] = {}
    cost_by_model: dict[str, float] = {}
    if primary_model:
        by_model[primary_model] = {
            "input_tokens": fresh_in,
            "output_tokens": output,
            "cache_read_tokens": cached,
            "cache_creation_tokens": 0,
        }
        cost_by_model[primary_model] = cost

    return {
        "sessionId": sid,
        "cwd": cwd,
        "repo": _codex_repo(cwd, repo_url),
        "gitBranch": branch,
        "version": version,
        "name": Path(cwd).name if cwd else None,
        "firstPrompt": first_prompt,
        "events": line_count,
        "messages": user_msgs + assistant_msgs,
        "userMessages": user_msgs,
        "assistantMessages": assistant_msgs,
        "models": sorted(models),
        "tokens": totals,
        "tokensByModel": by_model,
        "cost": round(cost, 4),
        "costByModel": {m: round(c, 4) for m, c in cost_by_model.items()},
        "startedAt": first_ts,
        "endedAt": last_ts,
    }


def pi_active_entries(raw_events: list[dict]) -> list[dict]:
    """Return the entries on Pi's current branch, oldest first."""
    entries = [event for event in raw_events
               if event.get("type") != "session" and event.get("id")]
    if not entries:
        return []
    by_id = {event["id"]: event for event in entries}
    active = []
    current = entries[-1]
    seen = set()
    while current and current["id"] not in seen:
        active.append(current)
        seen.add(current["id"])
        current = by_id.get(current.get("parentId"))
    active.reverse()
    return active


def summarize_pi_session(path: Path) -> dict:
    """Summarize a Pi session JSONL into the common manifest shape."""
    raw_events = []
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                raw_events.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    header = next((event for event in raw_events
                   if event.get("type") == "session"), {})
    active = pi_active_entries(raw_events)
    cwd = header.get("cwd")
    first_prompt = ""
    name = None
    user_msgs = 0
    assistant_msgs = 0
    models: set[str] = set()
    totals = {"input_tokens": 0, "output_tokens": 0,
              "cache_read_tokens": 0, "cache_creation_tokens": 0,
              "cache_5m_tokens": 0, "cache_1h_tokens": 0}
    by_model: dict[str, dict[str, int]] = {}
    cost = 0.0
    cost_by_model: dict[str, float] = {}

    for event in active:
        if event.get("type") == "session_info" and event.get("name"):
            name = event["name"]
            continue
        if event.get("type") != "message":
            continue
        message = event.get("message") or {}
        role = message.get("role")
        if role == "user":
            user_msgs += 1
            text = first_text(message.get("content"))
            if not first_prompt and text and not is_meta_user_text(text):
                first_prompt = text[:300]
            continue
        if role != "assistant":
            continue
        assistant_msgs += 1
        model = message.get("model") or ""
        if model:
            models.add(model)
        usage = message.get("usage") or {}
        input_tokens = usage.get("input", 0) or 0
        output_tokens = usage.get("output", 0) or 0
        cache_read = usage.get("cacheRead", 0) or 0
        cache_write = usage.get("cacheWrite", 0) or 0
        totals["input_tokens"] += input_tokens
        totals["output_tokens"] += output_tokens
        totals["cache_read_tokens"] += cache_read
        totals["cache_creation_tokens"] += cache_write
        totals["cache_5m_tokens"] += cache_write
        event_cost = (usage.get("cost") or {}).get("total", 0) or 0
        cost += event_cost
        if model:
            bucket = by_model.setdefault(model, {
                "input_tokens": 0, "output_tokens": 0,
                "cache_read_tokens": 0, "cache_creation_tokens": 0,
            })
            bucket["input_tokens"] += input_tokens
            bucket["output_tokens"] += output_tokens
            bucket["cache_read_tokens"] += cache_read
            bucket["cache_creation_tokens"] += cache_write
            cost_by_model[model] = cost_by_model.get(model, 0.0) + event_cost

    last_ts = active[-1].get("timestamp") if active else header.get("timestamp")
    return {
        "sessionId": header.get("id"),
        "cwd": cwd,
        "repo": Path(cwd).name if cwd else None,
        "gitBranch": None,
        "version": header.get("version"),
        "name": name,
        "firstPrompt": first_prompt,
        "events": len(raw_events),
        "messages": user_msgs + assistant_msgs,
        "userMessages": user_msgs,
        "assistantMessages": assistant_msgs,
        "models": sorted(models),
        "tokens": totals,
        "tokensByModel": by_model,
        "cost": round(cost, 4),
        "costByModel": {model: round(value, 4)
                        for model, value in cost_by_model.items()},
        "startedAt": header.get("timestamp"),
        "endedAt": last_ts,
    }


def pi_to_transcript(raw_events: list[dict]) -> list[dict]:
    """Normalize Pi's active branch into the viewer's event shape."""
    transcript = []
    for entry in pi_active_entries(raw_events):
        if entry.get("type") == "compaction":
            transcript.append({**entry, "type": "summary"})
            continue
        if entry.get("type") != "message":
            transcript.append(entry)
            continue
        message = entry.get("message") or {}
        role = message.get("role")
        event = {"uuid": entry.get("id"),
                 "timestamp": entry.get("timestamp")}
        if role == "user":
            transcript.append({**event, "type": "user", "message": message})
        elif role == "assistant":
            content = []
            for block in message.get("content") or []:
                if block.get("type") == "toolCall":
                    content.append({"type": "tool_use", "id": block.get("id"),
                                    "name": block.get("name"),
                                    "input": block.get("arguments") or {}})
                else:
                    content.append(block)
            transcript.append({**event, "type": "assistant",
                               "message": {**message, "content": content}})
        elif role == "toolResult":
            result = {
                "type": "tool_result",
                "tool_use_id": message.get("toolCallId"),
                "content": message.get("content") or [],
                "is_error": message.get("isError", False),
            }
            transcript.append({**event, "type": "user",
                               "message": {"content": [result]}})
        else:
            transcript.append(entry)
    return transcript


CODEX_REASONING_PLACEHOLDER = "⋯ reasoning hidden (encrypted, not stored)"


def codex_to_transcript(raw_events: list[dict]) -> list[dict]:
    """Normalize a Codex rollout into the Claude-shaped event stream the
    frontend already renders.

    Assistant-side items (reasoning, assistant text, tool calls) within a turn
    are grouped into one `assistant` event; each `function_call_output` becomes
    a `tool_result` packaged in a following `user` event, mirroring Claude's
    convention. Duplicate `agent_message` lines and the developer/user context
    `response_item`s are dropped; everything else passes through as an internal
    event.
    """
    out: list[dict] = []
    assistant_blocks: list[dict] = []
    pending_results: list[dict] = []
    assistant_ts = None
    result_ts = None
    current_model = None
    counter = 0
    has_legacy_user_messages = any(
        evt.get("type") == "event_msg"
        and (evt.get("payload") or {}).get("type") == "user_message"
        for evt in raw_events
    )

    def next_uuid(prefix: str) -> str:
        nonlocal counter
        counter += 1
        return f"codex-{prefix}-{counter}"

    def flush_assistant() -> None:
        nonlocal assistant_blocks, assistant_ts
        if not assistant_blocks:
            return
        out.append({
            "type": "assistant",
            "uuid": next_uuid("a"),
            "timestamp": assistant_ts,
            "message": {"model": current_model, "content": assistant_blocks},
        })
        assistant_blocks = []
        assistant_ts = None

    def flush_results() -> None:
        nonlocal pending_results, result_ts
        if not pending_results:
            return
        out.append({
            "type": "user",
            "uuid": next_uuid("r"),
            "timestamp": result_ts,
            "message": {"content": pending_results},
        })
        pending_results = []
        result_ts = None

    def add_assistant_block(block: dict, ts) -> None:
        nonlocal assistant_ts
        flush_results()
        if assistant_ts is None:
            assistant_ts = ts
        assistant_blocks.append(block)

    for evt in raw_events:
        ts = evt.get("timestamp")
        etype = evt.get("type")
        payload = evt.get("payload") or {}
        ptype = payload.get("type")

        if etype == "event_msg" and ptype == "user_message":
            flush_results()
            flush_assistant()
            out.append({
                "type": "user",
                "uuid": next_uuid("u"),
                "timestamp": ts,
                "message": {"content": payload.get("message", "")},
            })
            continue

        if etype == "response_item" and ptype == "message" and payload.get("role") == "user":
            text = codex_text(payload.get("content")).strip()
            if has_legacy_user_messages or is_codex_meta_user_text(text):
                continue
            flush_results()
            flush_assistant()
            out.append({
                "type": "user",
                "uuid": next_uuid("u"),
                "timestamp": ts,
                "message": {"content": text},
            })
            continue

        if etype == "turn_context":
            model = payload.get("model")
            if model:
                current_model = model
            # turn_context is internal; fall through to emit it below.

        if etype == "response_item" and ptype == "reasoning":
            summary = payload.get("summary") or []
            text = "\n\n".join(
                s.get("text", "") for s in summary
                if isinstance(s, dict) and s.get("text")
            ).strip()
            add_assistant_block(
                {"type": "thinking", "thinking": text or CODEX_REASONING_PLACEHOLDER},
                ts,
            )
            continue

        if etype == "response_item" and ptype == "message" and payload.get("role") == "assistant":
            text = codex_text(payload.get("content"))
            if text.strip():
                add_assistant_block({"type": "text", "text": text}, ts)
            continue

        if etype == "response_item" and ptype in ("function_call", "custom_tool_call"):
            args = payload.get("arguments")
            if args is None:
                args = payload.get("input")
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    args = {"raw": args}
            add_assistant_block(
                {"type": "tool_use", "name": payload.get("name", "?"), "input": args or {}},
                ts,
            )
            continue

        if etype == "response_item" and ptype in ("function_call_output", "custom_tool_call_output"):
            flush_assistant()
            if result_ts is None:
                result_ts = ts
            pending_results.append({
                "type": "tool_result",
                "content": payload.get("output", ""),
                "is_error": payload.get("is_error", False),
            })
            continue

        # Drop duplicates and raw context; surface the rest as internal events.
        if etype == "event_msg" and ptype == "agent_message":
            continue
        if etype == "response_item" and ptype == "message" and payload.get("role") in ("user", "developer"):
            continue

        flush_results()
        flush_assistant()
        out.append(evt)

    flush_results()
    flush_assistant()
    return out


def build_manifest(history_root: Path, cache: dict | None = None) -> list[dict]:
    """Walk each run dir and summarize its session transcripts.

    Claude/Gemini runs store `<run>/projects/<slug>/*.jsonl`; Codex runs store
    `<run>/sessions/YYYY/MM/DD/rollout-*.jsonl`; Pi stores sessions below
    `<history>/pi/`. All are summarized into the same entry shape.

    `cache` maps relative path → {"sig": (size, mtime_ns), "entry": dict}.
    Files whose signature is unchanged reuse the cached summary; new and
    modified files are re-summarized.
    """
    sessions: list[dict] = []
    if not history_root.is_dir():
        return sessions
    if cache is None:
        cache = {}

    def add_session(jsonl: Path, summarizer, project: str, run_dir: Path,
                    meta: dict, fallback_name: str | None) -> None:
        rel = jsonl.relative_to(history_root).as_posix()
        try:
            st = jsonl.stat()
        except OSError as e:
            log("warn", op="stat", path=str(jsonl), err=repr(e))
            return
        sig = (st.st_size, st.st_mtime_ns)
        cached = cache.get(rel)
        if cached and cached["sig"] == sig:
            sessions.append(cached["entry"])
            return
        try:
            summary = summarizer(jsonl)
        except OSError as e:
            log("warn", op="summarize", path=str(jsonl), err=repr(e))
            return
        entry = {
            "path": rel,
            "runDir": run_dir.name,
            "tool": meta["tool"],
            "runStartedAt": meta["timestamp"],
            "project": project,
            **summary,
        }
        if not entry["project"]:
            entry["project"] = entry.get("repo") or jsonl.parent.name
        if not entry.get("name") and fallback_name:
            entry["name"] = fallback_name
        cache[rel] = {"sig": sig, "entry": entry}
        sessions.append(entry)

    for year_dir in sorted(p for p in history_root.iterdir() if p.is_dir() and re.fullmatch(r"\d{4}", p.name)):
        for month_dir in sorted(p for p in year_dir.iterdir() if p.is_dir()):
            for run_dir in sorted(p for p in month_dir.iterdir() if p.is_dir()):
                meta = parse_run_dir(year_dir.name, month_dir.name, run_dir.name)
                if not meta:
                    continue
                projects = run_dir / "projects"
                codex_sessions = run_dir / "sessions"
                if projects.is_dir():
                    fallback_name = None
                    name_file = run_dir / ".session_name"
                    if name_file.is_file():
                        try:
                            fallback_name = name_file.read_text(encoding="utf-8", errors="replace").strip() or None
                        except OSError as e:
                            log("warn", op="read_name", path=str(name_file), err=repr(e))
                    for project_dir in sorted(p for p in projects.iterdir() if p.is_dir()):
                        for jsonl in sorted(project_dir.glob("*.jsonl")):
                            add_session(jsonl, summarize_session, project_dir.name,
                                        run_dir, meta, fallback_name)
                elif meta["tool"] == "codex" and codex_sessions.is_dir():
                    for jsonl in sorted(codex_sessions.rglob("rollout-*.jsonl")):
                        add_session(jsonl, summarize_codex_session, "",
                                    run_dir, meta, None)
    pi_sessions = history_root / "pi"
    if pi_sessions.is_dir():
        meta = {"tool": "pi", "timestamp": ""}
        for jsonl in sorted(pi_sessions.rglob("*.jsonl")):
            add_session(jsonl, summarize_pi_session, "", pi_sessions,
                        meta, None)
    # Sort by last-updated time (last event), falling back to start time so
    # the most recently active sessions surface first.
    sessions.sort(
        key=lambda s: (s.get("endedAt") or s.get("startedAt") or s["runStartedAt"]),
        reverse=True)
    return sessions


class ViewerState:
    def __init__(self, history_root: Path) -> None:
        self.history_root = history_root
        self._cache: dict = {}
        self._manifest: list[dict] | None = None
        self._lock = threading.Lock()

    def manifest(self, refresh: bool = False) -> list[dict]:
        """Always rescan the directory; reuse cached summaries by file signature."""
        with self._lock:
            if refresh:
                self._cache = {}
            t0 = time.monotonic()
            before = len(self._cache)
            self._manifest = build_manifest(self.history_root, self._cache)
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            log("info", op="manifest_ready",
                sessions=len(self._manifest),
                cached=before,
                rebuilt=len(self._cache) - before,
                ms=elapsed_ms)
            return self._manifest

    def resolve_session_path(self, rel: str) -> Path | None:
        """Resolve a relative jsonl path safely under history_root."""
        if not rel or rel.startswith("/") or ".." in rel.split("/"):
            return None
        candidate = (self.history_root / rel).resolve()
        try:
            candidate.relative_to(self.history_root)
        except ValueError:
            return None
        if candidate.suffix != ".jsonl":
            return None
        parts = Path(rel).parts
        # Pi has a dedicated root; other agents use run-scoped directories.
        if (not parts or parts[0] != "pi") and \
                "projects" not in parts and "sessions" not in parts:
            return None
        if not candidate.is_file():
            return None
        return candidate


# pastehtml.dev: publish a single self-contained HTML file, get a private
# shareable link (https://pastehtml.dev/llms.txt). Overridable for tests and
# self-hosted instances.
PASTEHTML_API = os.environ.get("PASTEHTML_API", "https://pastehtml.dev/api/pastes")
PASTEHTML_MAX_BYTES = 2 * 1024 * 1024


def _pastehtml_call(method: str, url: str, body: bytes, headers: dict) -> tuple[int, dict]:
    """One HTTP round-trip to pastehtml.dev; returns (status, parsed JSON)."""
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Content-Type", "text/html; charset=utf-8")
    # Cloudflare answers 403 to urllib's default Python-urllib/3.x agent.
    req.add_header("User-Agent", "history-viewer (+https://pastehtml.dev/llms.txt)")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except (json.JSONDecodeError, OSError):
            return e.code, {"error": f"pastehtml returned HTTP {e.code}"}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        return 502, {"error": f"pastehtml request failed: {e}"}


def publish_to_pastehtml(html: str, filename: str,
                         token: str | None = None,
                         update_token: str | None = None,
                         call=_pastehtml_call) -> tuple[int, dict]:
    """Create or update a paste on pastehtml.dev.

    With a token + update_token the existing paste is PATCHed so the shared
    link stays current; a stale token (403/404) falls back to creating a
    fresh paste, whose response carries a new update_token.
    """
    body = html.encode("utf-8")
    if token and update_token:
        status, payload = call(
            "PATCH", f"{PASTEHTML_API}/{quote(token)}", body,
            {"Authorization": f"Bearer {update_token}"})
        if status not in (403, 404):
            return status, payload
    return call("POST", f"{PASTEHTML_API}?filename={quote(filename)}", body, {})


def make_handler(state: ViewerState, html_path: Path):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            log("http", client=self.address_string(), msg=fmt % args)

        def _send_json(self, status: int, payload) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _send_error_json(self, status: int, message: str) -> None:
            self._send_json(status, {"error": message})

        def do_GET(self):
            parsed = urlparse(self.path)
            path = parsed.path
            qs = parse_qs(parsed.query)

            if path == "/":
                return self._serve_html()
            if path == "/favicon.ico":
                self.send_response(HTTPStatus.NO_CONTENT)
                self.end_headers()
                return
            if path == "/api/sessions":
                refresh = qs.get("refresh", ["0"])[0] == "1"
                return self._send_json(HTTPStatus.OK, state.manifest(refresh=refresh))
            if path == "/api/session":
                return self._serve_session(qs.get("path", [""])[0])
            if path == "/api/search":
                q = qs.get("q", [""])[0]
                limit = int(qs.get("limit", ["50"])[0])
                return self._serve_search(q, limit)
            return self._send_error_json(HTTPStatus.NOT_FOUND, "not found")

        def do_POST(self):
            if urlparse(self.path).path != "/api/publish":
                return self._send_error_json(HTTPStatus.NOT_FOUND, "not found")
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            # JSON-escaping inflates the HTML, so allow some headroom over
            # pastehtml's 2 MB document limit.
            if not 0 < length <= 4 * PASTEHTML_MAX_BYTES:
                return self._send_error_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                                             "request body missing or too large")
            try:
                req = json.loads(self.rfile.read(length))
            except json.JSONDecodeError:
                req = None
            if not isinstance(req, dict):
                return self._send_error_json(HTTPStatus.BAD_REQUEST, "invalid JSON body")
            html = req.get("html") or ""
            if not html.strip():
                return self._send_error_json(HTTPStatus.BAD_REQUEST, "html is required")
            if len(html.encode("utf-8")) > PASTEHTML_MAX_BYTES:
                return self._send_error_json(
                    HTTPStatus.UNPROCESSABLE_ENTITY,
                    "document exceeds pastehtml's 2 MB limit")
            status, payload = publish_to_pastehtml(
                html, req.get("filename") or "session.html",
                token=req.get("token"), update_token=req.get("update_token"))
            log("info", op="publish", status=status, token=payload.get("token", "-"))
            return self._send_json(status, payload)

        def _serve_html(self):
            try:
                body = html_path.read_bytes()
            except OSError:
                return self._send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, "viewer.html missing")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _serve_session(self, rel: str):
            resolved = state.resolve_session_path(rel)
            if not resolved:
                return self._send_error_json(HTTPStatus.FORBIDDEN, "invalid path")
            events = []
            with resolved.open("r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        events.append({"type": "__parse_error", "raw": line})
            # Codex and Pi use different schemas; normalize them into the
            # Claude-shaped event stream the frontend renders.
            is_codex = "sessions" in resolved.parts and resolved.name.startswith("rollout-")
            is_pi = Path(rel).parts[0] == "pi"
            if is_codex:
                events = codex_to_transcript(events)
            elif is_pi:
                events = pi_to_transcript(events)
            agent = "codex" if is_codex else "pi" if is_pi else "claude"
            return self._send_json(HTTPStatus.OK, {"path": rel, "agent": agent, "events": events})

        def _serve_search(self, q: str, limit: int):
            q = q.strip()
            if len(q) < 2:
                return self._send_json(HTTPStatus.OK, {"query": q, "results": []})
            needle = q.lower()
            results = []
            for session in state.manifest():
                rel = session["path"]
                resolved = state.resolve_session_path(rel)
                if not resolved:
                    continue
                snippets = []
                matches = 0
                try:
                    with resolved.open("r", encoding="utf-8", errors="replace") as f:
                        for lineno, line in enumerate(f, 1):
                            if needle in line.lower():
                                matches += 1
                                if len(snippets) < 3:
                                    snippets.append({"line": lineno, "text": line.strip()[:240]})
                except OSError:
                    continue
                if matches:
                    results.append({
                        "path": rel,
                        "sessionId": session.get("sessionId"),
                        "matchCount": matches,
                        "snippets": snippets,
                    })
                    if len(results) >= limit:
                        break
            return self._send_json(HTTPStatus.OK, {"query": q, "results": results})

    return Handler


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--history", default="/history", help="path to history archive root (default: /history)")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--open", action="store_true", help="open the viewer in a browser on startup")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    history_root = Path(args.history).resolve()
    if not history_root.is_dir():
        log("error", op="startup", msg=f"history dir not found: {history_root}")
        return 2

    html_path = SCRIPT_DIR / "viewer.html"
    state = ViewerState(history_root)
    handler = make_handler(state, html_path)
    server = ThreadingHTTPServer((args.host, args.port), handler)
    url = f"http://{args.host}:{args.port}/"
    log("info", op="listen", url=url, history=str(history_root))

    if args.open:
        threading.Thread(target=lambda: webbrowser.open(url), daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("info", op="shutdown")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    sys.exit(main())
