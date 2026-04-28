#!/usr/bin/env python3
"""Browse Claude Code session history in a local web viewer.

Serves a static HTML SPA plus a small JSON API over a directory of
archived ~/.claude snapshots (default: /history).
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
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
RUN_DIR_RE = re.compile(r"^(\d{2})_([A-Za-z]{3})_(\d{2})-(\d{2})_(\w+)$")
MONTHS = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], start=1)}

# Per-model USD pricing per 1M tokens, from platform.claude.com/docs/en/about-claude/pricing
# Tuple: (input, output, cache_read, cache_write_5m, cache_write_1h)
PRICING_BY_MODEL: dict[str, tuple[float, float, float, float, float]] = {
    # Opus 4.5+: reduced pricing
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
    cost = 0.0
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
                    first_prompt = first_text(content)[:300]
            elif etype == "assistant":
                assistant_msgs += 1
                msg_count += 1
                msg = evt.get("message", {}) or {}
                model = msg.get("model")
                if model:
                    models.add(model)
                usage = msg.get("usage") or {}
                totals["input_tokens"] += usage.get("input_tokens", 0) or 0
                totals["output_tokens"] += usage.get("output_tokens", 0) or 0
                totals["cache_read_tokens"] += usage.get("cache_read_input_tokens", 0) or 0
                cc_total = usage.get("cache_creation_input_tokens", 0) or 0
                totals["cache_creation_tokens"] += cc_total
                breakdown = usage.get("cache_creation") or {}
                cc_5m = breakdown.get("ephemeral_5m_input_tokens", 0) or 0
                cc_1h = breakdown.get("ephemeral_1h_input_tokens", 0) or 0
                if not (cc_5m or cc_1h):
                    cc_5m = cc_total
                totals["cache_5m_tokens"] += cc_5m
                totals["cache_1h_tokens"] += cc_1h
                cost += event_cost(model, usage)

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
        "cost": round(cost, 4),
        "startedAt": first_ts,
        "endedAt": last_ts,
    }


def build_manifest(history_root: Path, cache: dict | None = None) -> list[dict]:
    """Walk <root>/<year>/<month>/<run>/projects/*/*.jsonl and summarize.

    `cache` maps relative path → {"sig": (size, mtime_ns), "entry": dict}.
    Files whose signature is unchanged reuse the cached summary; new and
    modified files are re-summarized.
    """
    sessions: list[dict] = []
    if not history_root.is_dir():
        return sessions
    if cache is None:
        cache = {}
    for year_dir in sorted(p for p in history_root.iterdir() if p.is_dir() and re.fullmatch(r"\d{4}", p.name)):
        for month_dir in sorted(p for p in year_dir.iterdir() if p.is_dir()):
            for run_dir in sorted(p for p in month_dir.iterdir() if p.is_dir()):
                meta = parse_run_dir(year_dir.name, month_dir.name, run_dir.name)
                if not meta:
                    continue
                projects = run_dir / "projects"
                if not projects.is_dir():
                    continue
                fallback_name = None
                name_file = run_dir / ".session_name"
                if name_file.is_file():
                    try:
                        fallback_name = name_file.read_text(encoding="utf-8", errors="replace").strip() or None
                    except OSError as e:
                        log("warn", op="read_name", path=str(name_file), err=repr(e))
                for project_dir in sorted(p for p in projects.iterdir() if p.is_dir()):
                    for jsonl in sorted(project_dir.glob("*.jsonl")):
                        rel = jsonl.relative_to(history_root).as_posix()
                        try:
                            st = jsonl.stat()
                        except OSError as e:
                            log("warn", op="stat", path=str(jsonl), err=repr(e))
                            continue
                        sig = (st.st_size, st.st_mtime_ns)
                        cached = cache.get(rel)
                        if cached and cached["sig"] == sig:
                            sessions.append(cached["entry"])
                            continue
                        try:
                            summary = summarize_session(jsonl)
                        except OSError as e:
                            log("warn", op="summarize", path=str(jsonl), err=repr(e))
                            continue
                        entry = {
                            "path": rel,
                            "runDir": run_dir.name,
                            "tool": meta["tool"],
                            "runStartedAt": meta["timestamp"],
                            "project": project_dir.name,
                            **summary,
                        }
                        if not entry.get("name") and fallback_name:
                            entry["name"] = fallback_name
                        cache[rel] = {"sig": sig, "entry": entry}
                        sessions.append(entry)
    sessions.sort(key=lambda s: (s.get("startedAt") or s["runStartedAt"]), reverse=True)
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
        if "projects" not in candidate.parts:
            return None
        if not candidate.is_file():
            return None
        return candidate


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
            return self._send_json(HTTPStatus.OK, {"path": rel, "events": events})

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
