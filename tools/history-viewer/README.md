# history-viewer

Local web viewer for archived Claude Code sessions under `/history`.

## Run

Inside the `ai:latest` container (recommended — same environment as `bin/ai`):

    bin/history-viewer

Serves on `http://127.0.0.1:8765/`. Override with `PORT=9000 bin/history-viewer`. Reads from `${AI_DIR}/history` (default `~/ai/history`), mounted read-only.

Or run the Python directly against any history dir:

    python3 tools/history-viewer/viewer.py --open

Flags: `--history PATH` (default `/history`), `--port N` (default 8765), `--host` (default `127.0.0.1`), `--open` to auto-launch the browser.

## Features

- Browse every session from the archive, newest first
- Filter by date range, repo, branch, tool (claude/gemini), model, min tokens
- Full-text search across all session transcripts
- Transcript rendering: user/assistant bubbles, collapsed thinking + tool calls, "show internals" toggle
- Export to markdown — **clean** (just the user/assistant prose) or **full** (thinking, tool calls, results, meta wrappers)
- Session titles skip slash-command and `<local-command-caveat>` wrappers, picking the first real user prompt instead
- Stats dashboard: totals, breakdown by day / repo / model (claude runs only)

Pure Python stdlib + a single HTML file — no dependencies, no build step. The session endpoint resolves paths under `--history` and only serves `*.jsonl` files inside `projects/` subdirectories.
