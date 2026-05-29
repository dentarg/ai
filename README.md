# `ai` image

A containerized sandbox for running coding agents (Claude Code, Gemini CLI, OpenAI Codex, GitHub Copilot) with `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox` enabled by default.

## Why

Agents work best when they can freely run shell commands, edit files, install packages, and poke at databases — but you don't want them doing that against your host. This image gives each session its own throwaway Linux environment with:

- The project you're working on mounted at `/app`.
- Language runtimes, databases (PostgreSQL, LavinMQ, Redis), and common tools preinstalled, so agents don't spend turns bootstrapping.
- OAuth credentials and API keys mounted from `~/ai/settings`, with multi-profile support and automatic token refresh.
- Shell history, agent session history, cloned repos, and installed gems persisted on the host across container restarts.
- `mitmproxy` available for inspecting what the agent actually sends over the wire.

## Setup

Drop per-profile OAuth credentials in `$HOME/ai/settings` as
`.credentials.<profile>.json`. They get mounted into the container and copied
into `~/.claude/` when you launch claude with a matching profile. See the
[OAuth Login](#oauth-login) section for how to generate these.

Optionally, add `AGENTS.md` to `$HOME/ai/settings` — it becomes `CLAUDE.md`
for Claude Code and `GEMINI.md` for Gemini CLI.

Optionally, add `sentry.token` to `$HOME/ai/settings` to enable the
[Sentry MCP](https://mcp.sentry.dev/) server in Claude Code. See
[MCP Servers](#mcp-servers).

```shell
# start podman and share the current working directory
bin/ai

# start services (and run "bundle install" if Gemfile exists)
s

# launch claude with a specific oauth profile
c <profile>

# or launch claude with an Anthropic API key
c --apikey sk-ant-...

# resume a prior session (searches /history for the session id; a prefix is enough).
# profile is auto-detected from the session's saved .profile file.
c --resume <session-id>

# launch gemini
g

# launch openai codex
cx

# exit the container
x
```

## Prerequisites

Your Anthropic API key in 1Password.

```shell
brew install podman

# init the VM, enable zram swap, set kernel.keys quotas
bin/setup-vm

./build_image

# rebuild all layers and pull latest base image
./build_image --force
```

## OAuth Login

First-time setup to get OAuth credentials:

```shell
# inside the container, or via podman run
refresh-tokens --login
refresh-tokens --login <profile>
```

This generates an OAuth authorization URL. Open it in your browser, sign in, and paste the code back into the terminal. Credentials are saved to `~/.claude/.credentials.json` (or `.credentials.<profile>.json`).

## Token Refresh Service

OAuth tokens expire periodically. A systemd service (`refresh-tokens.service`) runs in every container, keeping `~/.claude/.credentials*.json` files fresh automatically.

```shell
# check service status
systemctl status refresh-tokens

# view logs
journalctl -u refresh-tokens

# follow logs
journalctl -u refresh-tokens -f

# one-shot refresh (e.g. before launching a session)
refresh-tokens --once
```

The service can also run as a standalone container to refresh `/settings` credentials:

```shell
podman run -d --name token-refresh \
  --env CREDENTIALS_DIR=/settings \
  --volume ${HOME}/ai/settings:/settings \
  ai:latest /usr/local/bin/refresh-tokens --daemon
```

Environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `CREDENTIALS_DIR` | `~/.claude` | Directory containing `.credentials*.json` files |
| `CHECK_INTERVAL` | `300` | Seconds between checks |
| `REFRESH_BEFORE` | `3600` | Seconds before expiry to trigger refresh |

## MCP Servers

### Sentry

To enable Sentry's MCP server so the agent can fetch issues, events, and
stack traces directly, drop your Sentry
[user auth token](https://sentry.io/settings/account/api/auth-tokens/) in
`$HOME/ai/settings/sentry.token` (just the token, no quotes or whitespace).

When you launch `c <profile>`, an `mcpServers.sentry` entry is injected into
the session's `~/.claude.json` that runs
[`@sentry/mcp-server`](https://github.com/getsentry/sentry-mcp) locally over
stdio with `SENTRY_ACCESS_TOKEN` set. We don't use the hosted
`mcp.sentry.dev` because its OAuth flow expects a callback on
`localhost:62880` inside the browser host — unreachable from this container.

For self-hosted Sentry, additionally drop the hostname in
`$HOME/ai/settings/sentry.host` (e.g. `sentry.example.com`) — it's passed
through as `--host=...`.

No `sentry.token` → no MCP server registered.

## Tricks

`zsh` things:

```zsh
# pod       # list all running containers
# pod <id>  # launch bash shell in selected container
# pod last  # launch bash shell in the youngest container
function pod() {
    [ $# -lt 1 ] && podman ps && return 0

    [ "$1" = "last" ] && podman exec -it $(podman ps | tail -1 | cut -d ' ' -f 1) ${2:-bash} && return

    local container
    container=$1
    podman exec -it $container ${2:-bash}
}
```

### `mitmproxy`

Start it capturing everything:

```bash
./mitmdump --mode regular --listen-port 8080 --ssl-insecure --set flow_detail=3 -w claude.flow
```

mitmproxy generates its CA at `~/.mitmproxy/mitmproxy-ca-cert.pem` on first run.

```bash
export NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem
export HTTPS_PROXY=http://127.0.0.1:8080
```

Start the agent

```bash
claude
```

Output the (partially) binary dump as text (`--mode` picking another port is important if proxy already running)

```bash
./mitmdump --mode regular@8082 --set flow_detail=3 -r claude.flow --set export_format=curl
```

### Commands

`tcpdump`

```shell
podman run --rm -it --cap-add=NET_RAW --cap-add=NET_ADMIN --net=container:<container> nicolaka/netshoot tcpdump -i eth0
```

`podman`

```shell
# to see current settings
podman machine inspect

# when we can't build because we're out of space
podman system prune--all

# initial setup, or after `podman machine reset`:
# inits the VM (300 GB disk, 8 GB RAM), enables zram swap, and persists
# kernel.keys.maxkeys / maxbytes so we don't hit the keyring quota
# ("crun: join keyctl ... Disk quota exceeded")
bin/setup-vm
```

## Stuff

- [x] Claude Code
- [x] GitHub Copilot
- [x] Google Gemini
- [x] Node.js
- [x] Bun ~~TypeScript~~
- [x] Ruby
- [x] Crystal
- [x] Python
- [x] Rust
- [x] Go
- [x] SSH (`ssh-keygen`, ...)
- [x] PostgreSQL
- [x] LavinMQ
- [x] Redis
- [x] [amqpcat](https://github.com/cloudamqp/amqpcat)
- [x] [rusage](https://justine.lol/rusage/) — better `time(1)`, prints full `getrusage(2)` stats
- [x] [logcli](https://grafana.com/docs/loki/latest/query/logcli/) — Grafana Loki CLI
