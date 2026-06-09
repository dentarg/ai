# history-viewer

Local web viewer for archived Claude Code **and Codex** sessions under `/history`.

## Run

Inside the `ai:latest` container (recommended — same environment as `bin/ai`):

    bin/history-viewer

Serves on `http://127.0.0.1:8765/`. Override with `PORT=9000 bin/history-viewer`. Reads from `${AI_DIR}/history` (default `~/ai/history`), mounted read-only.

Or run the Python directly against any history dir:

    python3 tools/history-viewer/viewer.py --open

Flags: `--history PATH` (default `/history`), `--port N` (default 8765), `--host` (default `127.0.0.1`), `--open` to auto-launch the browser.

## Features

- Browse every Claude and Codex session from the archive, newest first
- Clear agent distinction: each session is tagged with a coloured badge (coral **Claude** / blue **Codex**) and a matching card stripe; filter by agent or branch, plus full-text search across all transcripts
- Transcript rendering: user/assistant bubbles, collapsed thinking + tool calls, "show internals" toggle. Codex rollouts are normalised into the same view — tool calls grouped per turn, and a placeholder where the (encrypted) reasoning was
- Export to markdown — **clean** (just the user/assistant prose) or **full** (thinking, tool calls, results, meta wrappers)
- Session titles skip slash-command and `<local-command-caveat>` wrappers, picking the first real user prompt instead
- Stats dashboard (Claude + Codex): tokens-per-day chart (line per model, with All time / Last 30 days / Last 7 days tabs and a per-model legend showing share, In/Out/cache tokens, and cost), plus breakdown tables by day / week / month / repo / model

Cost is computed from each provider's published per-model pricing (Anthropic for Claude, OpenAI for the `gpt-5.x` family); update the `PRICING_BY_MODEL*` tables in `viewer.py` when prices change.

Pure Python stdlib + a single HTML file — no dependencies, no build step. The session endpoint resolves paths under `--history` and only serves `*.jsonl` files inside `projects/` (Claude/Gemini) or `sessions/` (Codex `rollout-*.jsonl`) subdirectories.

## Tests

    cd tools/history-viewer && python3 -m unittest test_viewer -v

Covers Codex summary/cost parsing and the rollout → transcript normalisation (stdlib only, no fixtures on disk).
