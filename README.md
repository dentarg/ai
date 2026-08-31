# `ai` sandbox

A disposable Podman container or Lima virtual machine for running coding agents (Claude Code, Gemini CLI, OpenAI Codex, GitHub Copilot) with `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox` enabled by default.

## Why

Agents work best when they can freely run shell commands, edit files, install packages, and poke at databases — but you don't want them doing that against your host. This image gives each session its own throwaway Linux environment with:

- The project you're working on mounted at `/app`.
- Language runtimes, databases (PostgreSQL, LavinMQ, Redis), and common tools preinstalled, so agents don't spend turns bootstrapping.
- OAuth credentials and API keys mounted from `~/ai/settings`, with multi-profile support and automatic token refresh.
- Shell history, agent session history, cloned repos, and installed gems persisted on the host across container restarts.
- A shared directory mounted at `/share` (from `~/ai/share`) for passing files between the host and containers.
- `mitmproxy` available for inspecting what the agent actually sends over the wire.
- An optional real Linux VM with rootful Docker for testing Compose, systemd,
  networking, image builds, and other host-level behavior.

## Setup

Drop per-profile OAuth credentials in `$HOME/ai/settings` as
`.credentials.<profile>.json`. They get mounted into the container and copied
into `~/.claude/` when you launch claude with a matching profile. See the
[OAuth Login](#oauth-login) section for how to generate these.

Optionally, add `AGENTS.md` to `$HOME/ai/settings` — it becomes `CLAUDE.md`
for Claude Code, `GEMINI.md` for Gemini CLI, and is copied into Codex's
session config.

Optionally, add `sentry.token` to `$HOME/ai/settings` to enable the
[Sentry MCP](https://mcp.sentry.dev/) server in Claude Code. See
[MCP Servers](#mcp-servers).

```shell
# start podman and share the current working directory
bin/ai

# instead, clone an ephemeral Lima VM from ai-base; it is deleted on exit
bin/ai --vm

# keep the VM running after exit so it can be inspected with limactl shell
bin/ai --keep-vm

# enable nested virtualization and give the outer VM additional resources
bin/ai --vm --nested-virt --cpus 8 --memory 16

# use the GPU-enabled krunkit base VM
bin/ai --vm --gpu

# allow this session to request approved, allowlisted 1Password secrets
bin/ai --1password

# start podman and auto-launch "c <profile>" once the container is up.
# before launching, the shared "~/ai/settings" token for <profile> is
# refreshed on the host. If it has expired, recent Claude session history is
# searched for a newer active copy before falling back to interactive login.
bin/ai <profile>

# start podman and auto-launch "cx" once the container is up.
bin/ai cx

# resume a prior Claude session: passed through to "c --resume <id>" on launch.
# works with or without a profile (c auto-detects it from the session).
bin/ai --resume <session-id>
bin/ai <profile> --resume <session-id>

# resume a prior Codex session: passed through to "cx --resume <id>" on launch.
bin/ai cx --resume <session-id>

# publish extra ports from the container to the host. each entry is either
# "PORT" (host==container) or "SRC:DST" (host:container); comma-separate many.
bin/ai --ports 9999             # host 9999 -> container 9999
bin/ai --ports 8888:7777        # host 8888 -> container 7777
bin/ai <profile> --ports 9999,8888:7777

# all launch/profile/resume/port options also work with the VM backend
bin/ai --vm cx --ports 9999

# enable Claude Code remote control for the session (off by default).
# equivalently set AI_REMOTE=1 in your shell. see "Remote control" below.
bin/ai <profile> --remote
AI_REMOTE=1 bin/ai <profile>

# enable fast mode for the session (off by default).
# equivalently set AI_FAST=1 in your shell. see "Fast mode" below.
bin/ai <profile> --fast
AI_FAST=1 bin/ai <profile>

# start services (and run "bundle install" if Gemfile exists).
# also runs automatically as part of "c" below.
s

# launch claude with a specific oauth profile (runs "s" first)
c <profile>

# or launch claude with an Anthropic API key
c --apikey sk-ant-...

# resume a prior Claude session (searches /history for the session id; a prefix is enough).
# profile is auto-detected from the session's saved .profile file.
c --resume <session-id>

# launch gemini
g

# launch openai codex
cx

# resume a prior Codex session (searches /history for the session id; a prefix is enough).
cx --resume <session-id>

# exit the container or VM session
x
```

`cx` launches Codex through a temporary symlink named after the host directory
captured by `bin/ai`, so Codex's terminal title and project/status fields show
that host directory name instead of `/app`. Its generated statusline shows the
project, git branch, model/reasoning, context used, and thread id. TUI
notifications are disabled for quieter terminal sessions.
`cx --resume <id>` searches archived Codex rollouts under `/history` and
reuses the original Codex home before launching `codex resume <id>`.

## Prerequisites

Podman is required for the default backend. Lima and `jq` are required for
`--vm`. The optional 1Password bridge also requires 1Password 8 and 1Password
CLI on the host.

```shell
brew install podman
brew install lima jq           # for --vm
brew tap libkrun/krun          # for --vm --gpu
brew trust libkrun/krun
brew install krunkit
brew install 1password-cli # optional

# init the Podman machine, enable zram swap, set kernel.keys quotas
bin/setup-vm

# normal builds use the pinned agent versions in "versions/" and do not
# check upstream "latest" endpoints.
./build_image

# update pinned Claude Code, Codex and plugin marketplace versions, then rebuild
./build_image --update-agents

# update only one pinned version file
./build_image --update-claude
./build_image --update-codex
./build_image --update-plugins

# rebuild all layers and pull latest base image
./build_image --force

# build the stopped ai-base Lima instance used by bin/ai --vm
./build_vm

# replace an existing base VM; accepts the same agent update flags
./build_vm --force
./build_vm --force --update-agents

# build the separate ai-base-gpu instance with Lima's krunkit driver
./build_vm --gpu
./build_vm --gpu --force
```

### Lima VM backend

`build_vm` provisions the expensive language runtimes and development tools
once, verifies Docker and the coding agents, stops the resulting `ai-base`
instance, and protects it from accidental deletion. `bin/ai --vm` clones that
base for each session, adds the same `/app`, `/settings`, `/history`, `/share`,
and other mounts used by the Podman backend, then deletes the clone when the
interactive shell exits. The image and VM builds share the Chromium, system
tool, language-runtime, coding-agent, and token-refresh service recipes under
`inside_deps/`; only backend-specific setup remains in their provisioners.
The initial build may take a while; `AI_VM_BUILD_TIMEOUT` controls its Lima
startup timeout and defaults to `60m`.

Runtime instances and guest hostnames use `ai-XX-<project>`, where `XX` is the
first available two-digit suffix and `project` is the current directory name.
Guests use UTC, matching the container backend.

Ubuntu's `docker.io`, `docker-buildx`, and `docker-compose-v2` packages provide
a rootful Docker stack inside the guest. The normal Lima user belongs to the
`docker` group and has passwordless `sudo`, so tests can exercise a realistic
Docker host without exposing the host Docker or Podman socket. Docker itself
does not require nested virtualization.

Use `--nested-virt` to expose KVM to software that starts another VM inside the
Lima guest. Lima supports this with the `vz` driver on Apple M3 or newer Macs;
the inner VM must use the native architecture. For QEMU, use `-accel kvm -cpu
host`. The option is disabled by default. `--cpus` and `--memory` override the
cloned VM's resources for workloads that need more than the base VM allocation.

GPU acceleration uses a separate `ai-base-gpu` instance because Lima selects
the VM driver when an instance is created. `build_vm --gpu` uses Lima's
experimental `krunkit` driver and verifies that `/dev/dri/renderD128` exists;
`bin/ai --vm --gpu` clones that base. This requires Apple Silicon, macOS 14 or
newer, and krunkit installed on the host.

The guest receives a paravirtualized Vulkan device rather than direct hardware
passthrough. Vulkan commands travel through Mesa Venus and MoltenVK to the
Apple GPU. Container images therefore need compatible Vulkan userspace drivers
and must receive the device explicitly. Verify the path with the patched Fedora
Mesa image recommended for krunkit:

```shell
docker run --rm --device /dev/dri --env XDG_RUNTIME_DIR=/tmp --entrypoint vulkaninfo quay.io/slopezpa/fedora-vgpu --summary
```

Ubuntu's Mesa packages are not installed in the guest because their Venus
protocol is incompatible with krunkit's host-side virglrenderer. GPU workloads
should carry compatible Mesa libraries in their container image, using the
patched Fedora image above as a base when appropriate.

The primary guest port still comes from `PORT` (1337 by default), but the VM
launcher chooses a free loopback host port and prints it when the VM is ready.
Set `AI_VM_HOST_PORT` to request a fixed primary host port. Explicit `--ports`
mappings remain fixed. Resource defaults for `build_vm` can be changed with
`AI_VM_CPUS`, `AI_VM_MEMORY` (GiB), and `AI_VM_DISK` (GiB); `AI_VM_BASE`
changes the base instance name for both building and launching.

Use `--keep-vm` when diagnosing a guest problem. The launcher prints the
instance name, which can then be opened or removed manually:

```shell
limactl shell <instance>
limactl stop <instance>
limactl delete <instance>
```

## 1Password bridge

The optional bridge lets a container resolve individual secrets through the
macOS 1Password app without giving the container access to `op` or its desktop
session. Every retrieval must match the host-side project allowlist and is
confirmed with a macOS dialog. The first `op` use in a terminal session may
also require 1Password biometric authorization.

First enable **Settings > Developer > Integrate with 1Password CLI** in the
1Password app. Verify the host integration with `op vault list`.

Create `$HOME/ai/1password-bridge.json` on the host:

```json
{
  "projects": {
    "/Users/me/src/example": {
      "account": "my.1password.com",
      "secrets": {
        "github-token": "op://Agent/GitHub/token",
        "anthropic-api-key": "op://Agent/Anthropic/credential"
      }
    }
  }
}
```

Project paths must be absolute and canonical; run `pwd -P` in the project to
get the exact value. Secret aliases may contain lowercase letters, digits,
dots, underscores, and hyphens. Protect the policy from modification:

```shell
chmod 600 "$HOME/ai/1password-bridge.json"
```

The policy deliberately lives outside directories mounted into containers.
Start an enabled session, then request a configured alias inside it:

```shell
bin/ai --1password

# inside the container; prints the value after host approval
op-read github-token
```

The broker starts with the container and stops when it exits. It loads the
project policy once, accepts only fixed aliases over an authenticated ephemeral
TLS connection, and never accepts arbitrary `op` arguments or `op://`
references from the container. Audit events, without secret values or
references, are appended to `$HOME/ai/logs/1password-bridge.log`.

Any value returned by `op-read` is visible to the container and can be retained
by the agent. The bridge limits which secrets can be requested and requires
approval when they are requested; it cannot protect a secret after release.

## OAuth Login

First-time setup to get OAuth credentials.

Claude Code:

```shell
# inside the container, or via podman run
refresh-tokens --login
refresh-tokens --login <profile>
```

This generates an OAuth authorization URL. Open it in your browser, sign in, and paste the code back into the terminal. Credentials are saved to `~/.claude/.credentials.json` (or `.credentials.<profile>.json`).

OpenAI Codex:

```shell
# inside the container
codex-login

# or from the host
bin/codex-login
```

This standalone helper starts Codex's "Sign in with Device Code" flow without
running the Codex CLI. Open the displayed URL, enter the one-time code, and
finish sign-in in your browser. Credentials are saved to
`/settings/codex/auth.json` in the container, or
`$HOME/ai/settings/codex/auth.json` from the host.

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

# inspect active credentials saved in recent Claude session history
refresh-tokens --list-active
refresh-tokens --list-active <profile>

# print or copy the freshest active credentials for a profile
refresh-tokens --find-active <profile>
refresh-tokens --copy-active <profile> /path/to/.credentials.json
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
| `HISTORY_DIR` | `~/ai/history` | Claude session history to search |
| `HISTORY_DAYS` | `2` | Recent file-age window to search |

## Claude Code plugins

Plugin marketplaces are baked into the image, so their commands are there in
every session and every project with no per-project configuration. List one per
line in `versions/claude-plugins`:

```
# <name>  <git url>  <commit>
84codes  https://github.com/84codes/claude-plugins.git  d53b7805…
```

At build time each is cloned to `/opt/claude-plugins/marketplaces/<name>`,
validated, and every plugin it declares with an in-repo source is symlinked
into `/opt/claude-plugins/enabled/`. On launch, `c` links those into the
session's `~/.claude/skills/`, where Claude Code auto-loads each as
`<name>@skills-dir`, enabled by default. Today that gives you `/gem:bump`.

Plugins a marketplace sources from *another* repo are skipped, with a count in
the build log — add that repo as its own line to vendor them. Two marketplaces
providing the same plugin name is a build error rather than a coin flip.

```shell
# re-pin every marketplace to its remote HEAD, then rebuild
./build_image --update-plugins
```

### Blocking a plugin

Everything baked in loads by default. To keep one off, name it in
`claude/plugins.blocklist` (version controlled, ships in the image) or in
`~/ai/settings/plugins.blocklist` on the host (no rebuild needed) — the two are
merged:

```
# one plugin name per line
code-simplifier
```

Blocked plugins are still installed and still listed by `/plugin`; they just
start disabled, so you can turn one on for a single session:

```shell
claude plugin list
#   ❯ gem@skills-dir            ✔ loaded
#   ❯ code-simplifier@skills-dir  ✘ disabled

claude plugin enable code-simplifier@skills-dir
```

`c` rewrites the session's `settings.json` from `claude/settings.json` on every
launch, so removing a name from the blocklist re-enables it next time — nothing
to undo.

### Why not `claude plugin install`

`~/.claude` is a fresh per-session directory under `/history` (see
`tools/claude.sh`). A real install writes `known_marketplaces.json`,
`installed_plugins.json` and `enabledPlugins` into it, all carrying absolute
paths into that throwaway directory, so it would be discarded on every launch.
`extraKnownMarketplaces` in settings doesn't help either: it is only acted on by
the interactive trust dialog. Symlinking into `~/.claude/skills/` sidesteps all
of it — and because they're symlinks into the image, a rebuild reaches resumed
sessions too.

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

## Remote control

[Remote control](https://code.claude.com/docs/en/remote-control) lets you
monitor and steer a running Claude Code session from claude.ai or the Claude
mobile app. The session keeps running in the container — only its I/O is
mirrored, over the same outbound HTTPS the agent already uses.

It is **off by default** and opt-in per session, because it exposes the
session (filesystem, MCP servers, every tool call) to anyone with your
claude.ai login. Turn it on with either:

```shell
bin/ai <profile> --remote      # one-off flag
AI_REMOTE=1 bin/ai <profile>   # or set the env in your shell
```

`bin/ai` forwards this into the container as `AI_REMOTE=1`; `c` then sets
`remoteControlAtStartup` in the session's `~/.claude/settings.json` — the same
key the `/config` "Enable Remote Control for all sessions" toggle writes, so the
bridge starts automatically. Running `c` directly honours the same `--remote`
flag and `AI_REMOTE` env. To make it the default for every session, export
`AI_REMOTE=1` in your host shell profile.

Remote sessions are labelled by the host directory in the claude.ai/mobile
list — `c` sets `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX` from `HOST_DIR`, so
they show as `<dir>-<random-words>` instead of the container hostname.

To enable it on an already-running session, run `/remote-control` (or `/rc`)
in the TUI; a `/rc active` link then appears in the footer.

## Fast mode

[Fast mode](https://code.claude.com/docs/en/fast-mode) runs Opus with
higher-speed output. It is **off by default** and opt-in per session, because
it draws from usage credits at a higher rate and has separate rate limits.
Turn it on with either:

```shell
bin/ai <profile> --fast      # one-off flag
AI_FAST=1 bin/ai <profile>   # or set the env in your shell
```

`bin/ai` forwards this into the container as `AI_FAST=1`; `c` then sets
`fastMode` in the session's `~/.claude/settings.json` — the same key the
`/fast` toggle writes. Running `c` directly honours the same `--fast` flag and
`AI_FAST` env. To make it the default for every session, export `AI_FAST=1` in
your host shell profile. Toggle it within a session with `/fast [on|off]`.

`c` also exports `CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK=1` in the fast path.
Without it the persisted `fastMode` is evaluated once at startup, while the
async fast-mode availability check is still pending, so in a fresh container it
resolves to off and never re-applies; skipping that check lets the setting
engage immediately.

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
- [x] ast-grep
- [x] tmux
- [x] SSH (`ssh-keygen`, ...)
- [x] SQLite
- [x] PostgreSQL
- [x] LavinMQ
- [x] Redis
- [x] [amqpcat](https://github.com/cloudamqp/amqpcat)
- [x] [rusage](https://justine.lol/rusage/) — better `time(1)`, prints full `getrusage(2)` stats
- [x] [logcli](https://grafana.com/docs/loki/latest/query/logcli/) — Grafana Loki CLI
