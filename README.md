# `ai` sandbox

A disposable Podman container or Lima virtual machine for running coding agents (Claude Code, Gemini CLI, OpenAI Codex, GitHub Copilot) with `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox` enabled by default.

## Contents

- [Why](#why)
- [Setup](#setup)
- [Prerequisites](#prerequisites)
- [Host browser](#host-browser)
- [1Password bridge](#1password-bridge)
- [GitHub bridge](#github-bridge)
- [Claude Code cloud setup](#claude-code-cloud-setup)
- [OAuth Login](#oauth-login)
- [Token Refresh Service](#token-refresh-service)
- [Claude Code plugins](#claude-code-plugins)
- [Codex plugins](#codex-plugins)
- [MCP Servers](#mcp-servers)
- [Persistent terminals inside a Linux VM](#persistent-terminals-inside-a-linux-vm)
- [Remote control](#remote-control)
- [Fast mode](#fast-mode)
- [Tricks](#tricks)
- [Stuff](#stuff)

## Why

Agents work best when they can freely run shell commands, edit files, install packages, and poke at databases — but you don't want them doing that against your host. This image gives each session its own throwaway Linux environment with:

- A Claude Code `PermissionRequest` hook that approves Bash requests, including
  the critical-path `rm` safeguard that bypass-permissions mode leaves enabled.
- The project you're working on mounted at `/app`.
- Language runtimes, databases (PostgreSQL, LavinMQ, Redis), and common tools preinstalled, so agents don't spend turns bootstrapping.
- OAuth credentials and API keys mounted from `~/ai/settings`, with multi-profile support and automatic token refresh.
- Shell history, agent session history, cloned repos, and installed gems persisted on the host across container restarts.
- A shared directory mounted at `/share` (from `~/ai/share`) for passing files between the host and containers.
- `mitmproxy` available for inspecting what the agent actually sends over the wire.
- An optional real Linux VM with rootful Docker for testing Compose, systemd,
  networking, image builds, and other host-level behavior.

## Setup

The image publishing workflow builds `ghcr.io/dentarg/ai` for Linux AMD64 and
ARM64 on pushes to `main` and manual runs from `main`. After both native
builds pass the agent smoke checks and local session integration tests, it publishes
`latest` and `sha-<full-commit-sha>` multi-platform tags. Docker and Podman
select the matching architecture automatically.

The package is public and supports anonymous downloads. The workflow uses
`GITHUB_TOKEN` with `packages: write`; no registry secret is needed.

```shell
# Download instead of building, keeping the local tag used by the host tools.
podman pull ghcr.io/dentarg/ai:latest
podman tag ghcr.io/dentarg/ai:latest ai:latest

# Inside a Linux VM, download directly into its Docker daemon.
docker pull ghcr.io/dentarg/ai:latest
```

Repeat the pull to update, or use a `sha-<full-commit-sha>` tag to select a
particular source revision. Registry digests can be used for an exact image.
`./build_image` still builds the local `ai:latest` image for development.

Drop per-profile OAuth credentials in `$HOME/ai/settings` as
`.credentials.<profile>.json`. They get mounted into the container and copied
into `~/.claude/` when you launch claude with a matching profile. See the
[OAuth Login](#oauth-login) section for how to generate these.

Codex profiles are stored as `$HOME/ai/settings/codex_<profile>/auth.json`.
The unprofiled default remains `$HOME/ai/settings/codex/auth.json`.
Claude profile settings are stored as
`$HOME/ai/settings/claude_<profile>/settings.json` and are merged over the
baked defaults at launch.

Profile model values are validated against a small bundled catalog. Run
`bin/ai models refresh` to download RubyLLM's model registry, retain only the
OpenAI and Anthropic fields used here, and cache the compact result under
`$HOME/ai/cache/models.json`. Launching, completing commands, and setting a
model never downloads the registry.

Optionally, add `AGENTS.md` to `$HOME/ai/settings` — it becomes `CLAUDE.md`
for Claude Code, `GEMINI.md` for Gemini CLI, and is copied into Codex's
session config.

Optionally, add `sentry.token` to `$HOME/ai/settings` to enable the
[Sentry MCP](https://mcp.sentry.dev/) server in Claude Code. See
[MCP Servers](#mcp-servers).

```shell
# create configuration files for a named Codex and Claude profile
bin/ai profile create <profile>

# remove a profile's Codex settings, Claude settings, and credentials
bin/ai profile remove <profile>

# authenticate either agent for the profile
bin/ai profile login <profile> codex
bin/ai profile login <profile> claude

# set the model each agent starts with for this profile
bin/ai profile set-model <profile> codex gpt-6-astra
bin/ai profile set-model <profile> claude claude-opus-4-8

# refresh the cached OpenAI and Anthropic model catalog
bin/ai models refresh

# show configured profiles and authentication status
bin/ai profile list

# enable command, profile, agent, and model completion
source <(bin/ai completion zsh)
# use "bash" instead of "zsh" when appropriate

# launch a new Podman container with an interactive shell
bin/ai

# select an agent explicitly: c or claude, cx or codex
# profiles and resumed sessions require an agent
# start Claude Code in Podman and share the current working directory
bin/ai c

# instead, clone an ephemeral Lima VM from ai-base; it is deleted on exit
bin/ai c --vm

# keep the VM running after exit so it can be inspected with limactl shell
bin/ai c --keep-vm

# enable nested virtualization and give the outer VM additional resources
bin/ai c --vm --nested-virt --cpus 8 --memory 16

# use the GPU-enabled krunkit base VM
bin/ai c --vm --gpu

# allow this session to request approved, allowlisted 1Password secrets
bin/ai c --1password

# launch a visible, isolated Chrome Canary on the host for the agent to control
bin/ai c --host-browser

# start podman and auto-launch "c <profile>" once the container is up.
# before launching, the shared "~/ai/settings" token for <profile> is
# refreshed on the host. If it has expired, recent Claude session history is
# searched for a newer active copy before falling back to interactive login.
bin/ai c <profile>

# start podman and auto-launch "cx" once the container is up.
bin/ai cx

# launch Codex with a specific profile.
bin/ai cx <profile>

# resume a prior Claude session: passed through to "c --resume <id>" on launch.
# works with or without a profile (c auto-detects it from the session).
bin/ai c --resume <session-id>
bin/ai c <profile> --resume <session-id>

# resume a prior Codex session: passed through to "cx --resume <id>" on launch.
# the profile is auto-detected from the original session.
bin/ai cx --resume <session-id>

# publish extra ports from the container to the host. each entry is either
# "PORT" (host==container) or "SRC:DST" (host:container); comma-separate many.
bin/ai c --ports 9999             # host 9999 -> container 9999
bin/ai c --ports 8888:7777        # host 8888 -> container 7777
bin/ai c <profile> --ports 9999,8888:7777

# all launch/profile/resume/port options also work with the VM backend
bin/ai --vm cx --ports 9999

# expose a UDP port from a Lima VM (host port 41641 -> guest port 41641)
bin/ai c --vm --keep-vm --udp-ports 41641

# enable Claude Code remote control for the session (off by default).
# equivalently set AI_REMOTE=1 in your shell. see "Remote control" below.
bin/ai c <profile> --remote
AI_REMOTE=1 bin/ai c <profile>

# enable fast mode for the session (off by default).
# equivalently set AI_FAST=1 in your shell. see "Fast mode" below.
bin/ai c <profile> --fast
AI_FAST=1 bin/ai c <profile>

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

# launch codex with a specific oauth profile
cx <profile>

# layer a native Codex configuration profile from
# ~/ai/settings/codex[_<oauth-profile>]/<config-profile>.config.toml
cx [<oauth-profile>] --profile <config-profile>

# resume a prior Codex session (searches /history for the session id; a prefix is enough).
# oauth and configuration profiles are auto-detected from the session.
cx --resume <session-id>

# exit the container or VM session
x
```

`bin/ai` mounts the project at `/app`, and `cx` preserves that working
directory when it launches Codex. Terminal tabs show
`project [oauth-profile] - Codex`, with the host working directory name
first so it stays visible in narrow tabs. Hostnames are omitted from the title.
Containers still use matching names and hostnames of `ai-c-XX-<project>`,
distinct from the VM prefixes `ai-l-`, `ai-g-`, and `ai-m-`. Containers
choose the first free number from `00` to `99`, including stopped containers
when checking availability. Codex title updates are disabled so they do not
replace the title with `app`. Its generated statusline
shows the current directory, git branch, model/reasoning, context used, and
thread id. TUI notifications are disabled for quieter terminal sessions. Codex defaults to
`gpt-6-astra`. To override the default for an OAuth profile, add native Codex
configuration such as
`model = "gpt-6-sol"` to
`~/ai/settings/codex_<oauth-profile>/default.config.toml`. Use
`~/ai/settings/codex/default.config.toml` for the unprofiled account.
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

# build the stopped ai-base Lima instance used by bin/ai c --vm
./build_vm

# replace an existing base VM; accepts the same agent update flags
./build_vm --force
./build_vm --force --update-agents
./build_vm --force --update-plugins

# build the separate ai-base-gpu instance with Lima's krunkit driver
./build_vm --gpu
./build_vm --gpu --force
```

### macOS Lima VM backend

On an Apple-silicon Mac with Lima 2.1 or later and `jq`, build a separate
macOS base and launch an ephemeral session:

```shell
./build_vm --macos
bin/ai c --macos
bin/ai --macos cx work
bin/ai c --macos work --ports 9999,8888:7777
```

The default base is `ai-base-macos`. If tool installation fails, run
`./build_vm --macos --resume` to resend the current build assets and rerun
provisioning in the existing VM, preserving its installed OS and packages.
`--force` deletes and rebuilds it instead; these options cannot be combined.
The existing
`--update-agents`, `--update-claude`, `--update-codex`, and `--update-plugins`
options also work. `AI_VM_BASE`, `AI_VM_CPUS`, `AI_VM_MEMORY`, and `AI_VM_DISK`
override the build defaults. `AI_VM_BUILD_TIMEOUT` controls each Lima startup
(default `60m`); subsequent tool installation streams directly over SSH.
The host must support the macOS 26 restore image supplied by the installed
Lima template and run the same or a newer macOS version.

Install full Xcode on the host before building. The build copies
`/Applications/Xcode.app` into the guest; set `AI_VM_XCODE_APP` to use another
Xcode application path. It accepts the Xcode license, installs first-launch
components, and downloads the iOS simulator runtime. The guest includes
`xcodebuild`, Swift, the macOS and iOS SDKs, and `simctl`. Allow space for Xcode
and the simulator on both machines, plus a temporary Xcode archive during the
build. Signing identities and provisioning profiles must be configured
separately for signed device builds and distribution.

Provisioning installs Homebrew, native language tools, the pinned Claude and
Codex versions, Codex plugins, and the shared agent wrappers. The guest user
gets passwordless sudo inside this disposable VM. The build reboots to activate
macOS synthetic links for `/workspace`, `/app`, and the other shared paths,
then verifies the installed tools after another restart before protecting the
base. No desktop login or Lima 2.3 `suppressFirstLoginSetup` setting is required
by this SSH workflow. After startup, the launcher attempts to hide Lima's
macOS display using the host's application API. The window may briefly appear
and take focus before it is hidden; Lima still requires the display to exist.
If that API fails, it tries System Events, which may request Automation or
Accessibility permission for the host terminal. Hiding failures are nonfatal.
The hide attempt times out after five seconds so it cannot block the build.
Set `AI_VM_SHOW_DISPLAY=1` when building or launching to leave it visible.

Profiles, resume, `--keep-vm`, CPU/memory overrides, and the opt-in host bridges
use the existing launcher. TCP ports are forwarded over an SSH tunnel bound to
host loopback; the tunnel closes when the launcher exits, even with `--keep-vm`.
UDP forwarding, `--gpu`, and `--nested-virt` are rejected for this backend.
Native gem caches live in `$AI_DIR/bundle-macos`, separate from Linux gems.
Codex transcripts remain in shared history, while its SQLite runtime databases
live under `~/.codex-state` on the macOS guest disk to avoid shared-filesystem
I/O errors. These local databases are discarded with an ephemeral VM.
`s` starts native PostgreSQL, Redis, and LavinMQ as system launch daemons running
as the guest user, then runs Bundler. The Linux Docker stack and Chromium setup
are not installed in macOS guests; use `--host-browser` for the host browser.

The macOS backend is experimental. Its build/launch command flow is covered by
`bash tools/test_macos_vm.sh`; full installation and agent login still require
verification on an Apple-silicon Mac. See [Lima's macOS guest documentation](https://lima-vm.io/docs/usage/guests/macos/).

### Linux Lima VM backend

`build_vm` provisions the expensive language runtimes and development tools
once, verifies Docker and the coding agents, stops the resulting `ai-base`
instance, and protects it from accidental deletion. `bin/ai c --vm` clones that
base for each session, adds the same `/app`, `/settings`, `/history`, `/share`,
and other mounts used by the Podman backend, then deletes the clone when the
interactive shell exits. The image and VM builds share the Chromium, system
tool, language-runtime, coding-agent, and token-refresh service recipes under
`inside_deps/`; only backend-specific setup remains in their provisioners.
The initial build may take a while; `AI_VM_BUILD_TIMEOUT` controls its Lima
startup and provisioning timeout and defaults to `60m`. Long-running
provisioning runs separately from Lima's boot scripts, and `build_vm` streams
its output. This avoids Lima's fixed ten-minute boot-script and cloud-init
progress-monitor limits.

Runtime instances and guest hostnames use `ai-l-XX-<project>` for standard Linux
VMs, `ai-g-XX-<project>` for GPU VMs, and `ai-m-XX-<project>` for macOS VMs.
`XX` is the first available two-digit index for that type and project, and
`project` is the sanitized current directory name, truncated to keep the VM
name within 63 characters.
Guests use UTC, matching the container backend.

VZ runtime clones use Apple's native `vzNAT` networking to avoid Lima's
user-mode TCP forwarding limits. The launcher configures this when cloning,
so existing base VMs do not need rebuilding. Other VM drivers keep their
existing network configuration.

Lima runtime clones expose only loopback TCP ports by default. Use
`--udp-ports HOST:CONTAINER` when a guest service needs an externally reachable
UDP port, such as Tailscale's default `41641`. The host-side port must also be
reachable through any outer firewall or NAT device. For Tailscale, use the same
port on both sides and configure the guest daemon to listen on that port.

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
`bin/ai c --vm --gpu` clones that base. This requires Apple Silicon, macOS 14 or
newer, and krunkit installed on the host.

The guest receives a paravirtualized Vulkan device rather than direct hardware
passthrough. Vulkan commands travel through Mesa Venus and MoltenVK to the
Apple GPU. Container images therefore need compatible Vulkan userspace drivers
and must receive the device explicitly. Verify the path with the patched Fedora
Mesa image recommended for krunkit:

```shell
docker run --rm --device /dev/dri --env XDG_RUNTIME_DIR=/tmp --entrypoint vulkaninfo quay.io/slopezpa/fedora-vgpu --summary
```

GPU workloads do not use the guest's Ubuntu Mesa because its Venus protocol is
incompatible with krunkit's host-side virglrenderer. They carry compatible Mesa
libraries in their container image, using the patched Fedora image above as a
base when appropriate.

Debian sid supplies Chromium without Ubuntu's snap wrapper. Its repository is
pinned below Ubuntu so installing Chromium cannot upgrade the guest's Mesa and
other base libraries to Debian versions.

The GPU base includes a pinned llama.cpp build with Vulkan support. The
`llama-cli` and `llama-server` commands run it in the compatible Fedora image,
pass through `/dev/dri`, and mount both the current directory and `/share`.
Models are deliberately not baked into the ephemeral VM; keep GGUF files under
`/share` so they survive VM rebuilds. For example:

```shell
mkdir -p /share/models
curl -L -o /share/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
llama-cli \
  --model /share/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --gpu-layers 99
```

The wrapper passes `GGML_VK_DISABLE_F16` through when it is set. Hybrid
DeltaNet models such as Qwen3.6 need this Vulkan workaround on the
paravirtualized Apple GPU. Qwen3.6-27B Q5_K_M runs reliably with 36 layers
offloaded, CPU-side KV cache, and reduced batch sizes:

```shell
GGML_VK_DISABLE_F16=1 llama-cli \
  --model /share/models/Qwen3.6-27B-Q5_K_M.gguf \
  --gpu-layers 36 \
  --no-kv-offload \
  --ctx-size 8192 \
  --batch-size 64 \
  --ubatch-size 32
```

`llama-server` uses host networking, so its default port is directly available
through the VM's configured forwards.

The GPU base runs a shared, authenticated llama.cpp router as
`local-code-server.service`. Model instances load on demand and unload when a
different model is selected, so multiple Pi sessions share one model allocation.
Qwen has one 16K slot and Gemma has one 64K slot. Qwen is the supported default
for autonomous repository work; use Gemma for bounded generation, review, and
diagnosis.

The `local-code` client is available in both the VM and the OCI image. It uses
Qwen3.8-27B IQ4_XS by default and accepts `qwen38` and `gemma4` aliases:

```shell
curl -L -o /share/models/Qwen3.8-27B-UD-IQ4_XS.gguf \
  https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-IQ4_XS.gguf
local-code
curl -L -o /share/models/gemma-4-26B_q4_0-it.gguf \
  https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/resolve/main/gemma-4-26B_q4_0-it.gguf
local-code --model gemma4
```

Pi gives the model `read`, `write`, `edit`, and `bash` tools. After each task it
prints a `Cooked for` duration and completion time. Host-networked Docker
containers in the GPU VM can reach the same server at `127.0.0.1:8080`; set
`LOCAL_CODE_BASE_URL` when using a different address. The API key defaults to
`local` and can be changed with `LOCAL_CODE_API_KEY` on the service and clients.
The client reserves 4K tokens for each response. When compacting, it retains the
newest 2K tokens for Qwen and 4K for Gemma. A Pi extension blocks unbounded
recursive listings, stops after three consecutive tool errors, and limits Gemma
tasks to 24 tool calls. Gemma uses Google's pinned canonical chat template and
preserves thinking across tool-call turns. Pi sessions persist under
`/history/pi` and appear in the history viewer.

Run the end-to-end smoke test inside a GPU VM to verify that the default model
can inspect a broken JavaScript function, edit it, and pass its test:

```shell
tools/test_local_code_model.sh
```

The model presets use 36 GPU layers for `qwen38` and 20 for `gemma4`. To
override the selected profile, stop the service and run the server directly:

```shell
sudo systemctl stop local-code-server
LOCAL_CODE_GPU_LAYERS=18 local-code-server
```

The primary guest port still comes from `PORT` (1337 by default), but the VM
launcher chooses a free loopback host port and prints it when the VM is ready.
Set `AI_VM_HOST_PORT` to request a fixed primary host port. Explicit `--ports`
mappings remain fixed. Resource defaults for `build_vm` can be changed with
`AI_VM_CPUS`, `AI_VM_MEMORY` (GiB), and `AI_VM_DISK` (GiB); `AI_VM_BASE`
changes the base instance name for both building and launching.

Lima bases enable zram swap sized to half of guest RAM, using zstd compression.
This absorbs temporary memory spikes from compilers and container builds before
the guest has to invoke the OOM killer.

Use `--keep-vm` when diagnosing a guest problem. The launcher prints the
instance name, which can then be opened or removed manually. The launcher also
keeps the VM automatically when its console exits nonzero, preserving guest
logs and Docker build cache for diagnosis.

```shell
# attach to a running VM for the current directory with the sandbox shell
bin/vm

# list instances, select one explicitly, or run a command in one
bin/vm list
bin/vm <instance>
bin/vm <instance> docker ps

limactl stop <instance>
limactl delete <instance>
```

## Host browser

`--host-browser` launches Google Chrome Canary on macOS with a dedicated
profile and makes its Chrome DevTools Protocol endpoint available inside either
the Podman container or Lima VM. Canary and the proxy stop when the session
exits. The profile remains under `$HOME/ai/host-browser/profile`, preserving
browser state such as cookies, logins, and extensions across sessions and host
reboots. Only one host-browser session may use the profile at a time.

On every launch, translation offers and password-saving prompts are disabled
for both new and existing profiles. Other preferences and saved browser state
are preserved.

Use a named profile to run isolated browser identities concurrently. Named
profiles remain under `$HOME/ai/host-browser/profiles/<name>`:

```shell
bin/ai c --host-browser=work
bin/ai c --host-browser=personal
```

The host-facing Chrome debugging socket remains on loopback. A TLS proxy
accepts guest connections using a random bearer token, rewrites the advertised
WebSocket endpoint, and strips the token before forwarding traffic to Chrome.
Its per-session certificate is valid for one year so long-running sessions do
not lose access.
The guest receives `HOST_BROWSER_URL`, `HOST_BROWSER_TOKEN`,
`HOST_BROWSER_CA`, and `NODE_EXTRA_CA_CERTS`. The token is passed to Lima
through a temporary file rather than a process argument.

Connect with the preinstalled `puppeteer-core` package:

```javascript
const puppeteer = require("puppeteer-core");
const authorization = `Bearer ${process.env.HOST_BROWSER_TOKEN}`;
const browser = await puppeteer.connect({
  browserURL: process.env.HOST_BROWSER_URL,
  wsOptions: {headers: {Authorization: authorization}},
});

const page = await browser.newPage({background: true});
await page.goto("https://example.com");
await browser.disconnect();
```

Run the script with the globally installed package on Node's module path:

```shell
NODE_PATH="$(npm root -g)" node browser-script.cjs
```

Canary starts without an initial window so launching it does not activate the
application. Always create pages with `{background: true}` and do not call
`page.bringToFront()`; foreground targets can cause macOS to switch focus to
Canary. Select Canary yourself when you want to inspect its windows.

Chrome Canary must be installed at its normal application path. Override it
with `AI_CHROME_CANARY_PATH` when necessary. Set `AI_HOST_BROWSER=1` instead
of passing the flag to enable the same behavior. Set
`AI_HOST_BROWSER_PROFILE=<name>` to select a named profile through the
environment.

The isolated profile supports extension development. Load an unpacked
extension in Canary, then use Puppeteer to inspect its extension pages,
content-script pages, and Manifest V3 service-worker targets. Manually loaded
extensions persist in the dedicated profile between sessions.

Applications running in the guest still need `--ports` so the host browser can
reach them. For example, `bin/ai c --host-browser --ports 3000` exposes a guest
server on `http://127.0.0.1:3000` to Canary.

## 1Password bridge

The optional bridge lets a container resolve individual secrets through the
macOS 1Password app without giving the container access to `op` or its desktop
session. Every retrieval must match the host-side alias allowlist and is
confirmed with a macOS dialog. The first `op` use in a terminal session may
also require 1Password biometric authorization.

First enable **Settings > Developer > Integrate with 1Password CLI** in the
1Password app. Verify the host integration with `op vault list`.

Manage `~/.config/ai/1password-bridge.json` on the host with the CLI (Ruby required):

```shell
bin/1password-bridge init my.1password.com
bin/1password-bridge set github-token op://Agent/GitHub/token
bin/1password-bridge show
bin/1password-bridge remove github-token
bin/1password-bridge edit
```

The policy applies to every session launched with `--1password`, regardless
of checkout. `init` updates the host account while retaining existing aliases;
`set` adds or replaces an alias. `edit` opens the entire policy using `$VISUAL`,
then `$EDITOR`, or `vi`. Changes are validated before an atomic save with mode
`0600`; invalid edits leave the original policy untouched. The tool stores
references only and does not retrieve secrets or invoke `op`.

Host-only configuration follows `XDG_CONFIG_HOME`, defaulting to
`$HOME/.config` when unset, empty, or relative. Both the CLI and launcher use
`$XDG_CONFIG_HOME/ai/1password-bridge.json` when an absolute base is set.
The CLI also accepts `--file PATH` for editing a policy explicitly; the
launcher always reads the standard location. `AI_DIR` still controls container
settings and persistent data, including bridge logs and runtime files.
Restart the bridge session after changing its policy.
Run the CLI tests with `ruby tools/onepassword-bridge/test_config.rb`.

The resulting policy has this structure:

```json
{
  "account": "my.1password.com",
  "secrets": {
    "github-token": "op://Agent/GitHub/token",
    "anthropic-api-key": "op://Agent/Anthropic/credential"
  }
}
```

Secret aliases may contain lowercase letters, digits, dots, underscores, and
hyphens. The launch directory appears in approval dialogs and audit logs,
but does not select the policy. Protect the policy from modification:

```shell
chmod 600 "$HOME/.config/ai/1password-bridge.json"
```

The policy deliberately lives outside directories mounted into containers.
Start an enabled session, then request a configured alias inside it:

```shell
bin/ai c --1password

# inside the container; prints the value after host approval
op-read github-token
```

The broker starts with the container and stops when it exits. It loads the
host policy once, accepts only fixed aliases over an authenticated ephemeral
TLS connection, and never accepts arbitrary `op` arguments or `op://`
references from the container. Audit events, without secret values or
references, are appended to `$HOME/ai/logs/1password-bridge.log`.

Any value returned by `op-read` is visible to the container and can be retained
by the agent. The bridge limits which secrets can be requested and requires
approval when they are requested; it cannot protect a secret after release.

## GitHub bridge

Use `bin/ai c --github=work` (or `AI_GITHUB=1 AI_GITHUB_PROFILE=work`) to enable restricted host `gh`
operations. Like the 1Password bridge, this requires a macOS host with `ruby`,
`op`, and the 1Password desktop integration enabled. Install `gh` on the host
as well. The container and Lima guests use the `gh-host` client; rebuild the
image or VM base to install it.

The image and both VM bases also ship the shared
[`gh-host` skill](skills/gh-host/SKILL.md). On bridge-enabled launches, `c`
links it into the session's `~/.claude/skills/` and `cx` links it into
`~/.agents/skills/`. Both agents can select it automatically for PR tasks;
you can also invoke `/gh-host` in Claude Code or `$gh-host` in Codex.
It explains repository selection, supported commands, approval, and safe
handling of denied or uncertain requests. Launching without the bridge removes
only the link managed by the wrapper; an existing user-authored skill is
preserved. The host broker remains responsible for enforcing permissions.

Store a fine-grained GitHub token in 1Password, restricted to the repositories
needed and with an expiration. Pull requests read permission supports the read
operations; write permission is needed to create PRs. The bridge resolves the
configured reference through host `op` for each request and passes the token
only to host `gh`. It does not use your normal `gh` login or expose a token-read
operation to the container.

Configure access once on the host, from any directory:

```shell
bin/github-bridge init \
  work my.1password.com op://Agent/GitHub/token \
  'company/*' 'another-org/*' owner/example
bin/github-bridge show work

# Optional: replace the allowed operations, including draft PR creation.
bin/github-bridge allow work \
  pr-list pr-view pr-diff pr-create
bin/github-bridge check work
bin/github-bridge list
bin/ai cx --github=work
```

Each named profile has its own token, repository scopes, and allowed operations,
independent of checkout. Mix exact `OWNER/REPO` entries with quoted `ORG/*`
entries to allow all current and future repositories under one or more owners.
Matching is case-insensitive; owner scopes also work for personal accounts.
Only an entire repository component may be `*`; arbitrary globs are rejected.
The token must also have access to each target repository.

`init` replaces only the named profile and resets its operations to read-only;
`allow` replaces only that profile's operation list. Other profiles are preserved.
Both validate and save atomically with mode `0600`. The 1Password reference is
configurable per profile. Each session uses exactly one profile and cannot switch
tokens through `gh-host`. Bare `--github` selects `AI_GITHUB_PROFILE`, defaulting
to `default`; unknown profiles fail at startup.
The launch directory is included only in audit logs and approval dialogs.

The policy lives at `~/.config/ai/github-bridge.json`, honoring an absolute
`XDG_CONFIG_HOME`, with the same defaults as the 1Password policy. `--file`
selects a different file for the configuration CLI only. The launcher reads
the standard location. Restart enabled sessions after policy changes.

```json
{
  "profiles": {
    "work": {
      "account": "my.1password.com",
      "token": "op://Agent/GitHub/token",
      "repositories": ["company/*", "another-org/*", "owner/example"],
      "operations": ["pr-list", "pr-view", "pr-diff"]
    }
  }
}
```

Inside an enabled container or VM:

```shell
gh-host pr-list owner/example
gh-host pr-view owner/example 123
gh-host pr-diff owner/example 123
printf '%s\n' 'Describe the change here.' | \
  gh-host pr-create owner/example feature-branch main 'PR title'
```

`pr-list` returns up to 30 open PRs. Read operations return GitHub JSON or a
plain diff. Creation uses an already-pushed branch in the selected repository,
creates a draft with maintainer edits disabled, and requires a macOS dialog
showing the exact request. Denial or a 60-second approval timeout prevents the
write. Reads rely on the host allowlist without an extra approval dialog;
1Password may still require authorization. Creating a PR may trigger repository
automation. A failed or timed-out create can have succeeded remotely; inspect
the PR list before retrying.

The broker supports github.com and these four operations only. It constructs
fixed `gh api` requests, validates all arguments on the host, and rejects extra
fields. Each `gh` process uses an empty configuration directory and a restricted
environment, outside the project checkout. Neither arbitrary commands, API
paths, host file paths, nor caller-supplied environment variables are accepted.

Each enabled session gets a bearer token and ephemeral TLS certificate. Only
the public bridge directory is mounted into the guest; the policy and command
configuration stay on the host. Requests are limited to 16 KiB, PR bodies to
8 KiB, command output to 2 MiB, and each `op`/`gh` process to 60 seconds. TLS and
request reads have a 10-second deadline. The broker handles one request at a
time. It exits with the session and removes its runtime directory.

Audit events go to `$AI_DIR/logs/github-bridge.log` (default
`~/ai/logs/github-bridge.log`) without tokens, token references, PR bodies, or
subprocess error output. Returned repository content is visible to the agent.

Run the bridge tests with:

```shell
for test in tools/github-bridge/test_*.rb; do ruby "$test" || break; done
bash tools/test_github_bridge.sh
bash tools/test_agent_skills.sh
```

## Claude Code cloud setup

Paste this into the cloud environment's **Setup script** field:

```bash
#!/bin/bash
# provisioning-revision: 2026-10-08-2 (change to refresh the cache)
set -euo pipefail

script=$(mktemp)
trap 'rm -f "$script"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  --connect-timeout 15 --max-time 120 \
  https://raw.githubusercontent.com/dentarg/ai/main/tools/claude-cloud-setup.sh \
  --output "$script"
bash "$script"
```

Set **Network access** to **Full** in the Claude Code cloud environment.
See the [setup script](tools/claude-cloud-setup.sh) for what it installs.

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
codex-login <profile>

# or from the host
bin/codex-login
bin/codex-login <profile>
```

This standalone helper starts Codex's "Sign in with Device Code" flow without
running the Codex CLI. Open the displayed URL, enter the one-time code, and
finish sign-in in your browser. Credentials are saved to
`/settings/codex/auth.json` in the container, or
`$HOME/ai/settings/codex/auth.json` from the host.
For a named profile, `codex_<profile>` replaces the `codex` directory name.

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

`c` rewrites the session's `settings.json` on every launch by merging
`claude/settings.json` with the selected profile's
`~/ai/settings/claude_<profile>/settings.json`. Removing a name from the
blocklist therefore re-enables it next time — nothing to undo.

### Why not `claude plugin install`

`~/.claude` is a fresh per-session directory under `/history` (see
`tools/claude.sh`). A real install writes `known_marketplaces.json`,
`installed_plugins.json` and `enabledPlugins` into it, all carrying absolute
paths into that throwaway directory, so it would be discarded on every launch.
`extraKnownMarketplaces` in settings doesn't help either: it is only acted on by
the interactive trust dialog. Symlinking into `~/.claude/skills/` sidesteps all
of it — and because they're symlinks into the image, a rebuild reaches resumed
sessions too.

## Codex plugins

Codex marketplaces are pinned separately in `versions/codex-plugins`:

```
# <name>  <git url>  <commit>
dentarg  https://github.com/dentarg/codex-plugins.git  d9eeb3d3…
```

Image and VM builds clone each marketplace, install every local plugin into a
validated Codex cache, and enable it in a reusable configuration fragment.
`cx` copies that cache and configuration into every new or resumed session.
The `dentarg/codex-plugins` marketplace currently provides the `gem@84codes`
plugin and its `$gem-bump` skill.

`./build_image --update-plugins` refreshes the Claude Code and Codex pins;
`./build_vm --update-plugins` refreshes the Codex pins used by the VM. A
selected Codex configuration profile can disable a baked plugin because profile
configuration is layered above the generated base configuration.

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

## Persistent terminals inside a Linux VM

`bin/ai session` runs multiplayer sessions with a shared native terminal. Start sessions
**inside a Linux sandbox VM**, with Docker available. Sessions use
`ghcr.io/dentarg/ai:latest` by default and pull it if missing from the VM's
Docker daemon. Pull explicitly to update a cached image. Use `--image ai:latest`
to use a local development build, or `--image ghcr.io/dentarg/ai:sha-<commit>`
to select a published revision. An image on the host's Podman daemon is not
automatically available in the VM.
Use `--keep-vm` when launching the VM: terminal detachment does not override
the outer launcher's VM cleanup policy.

Each session runs its agent in a separate Docker container. Local and invited
remote participants attach to the same native agent UI and type freely.

```shell
# Run from this repository inside the VM; choose the agent's working directory.
bin/ai session start demo --workspace /repos/demo -- c myprofile

# Start without attaching, and publish a web app on an unused VM loopback port.
bin/ai session start web --workspace /repos/web --detach --port 3000 -- cx myprofile

# From another terminal in the same VM:
bin/ai session list
bin/ai session attach demo
bin/ai session attach demo --read-only
bin/ai session ports web
```

Detach with **Ctrl+b, then d**. Ctrl+C still reaches the agent. Everyone
shares one input buffer; coordinate typing out of band. Writable clients
can also use tmux commands inside the agent container. Read-only attachment
is a local convenience, not a remote authentication boundary. Viewer
terminals do not resize the shared screen; the latest active writable
client determines its size.
Use **Ctrl+b, then i** to redisplay the session information without leaving
the terminal. The owner can list invitations or retrieve the same invitation
from another VM terminal.

The image must contain Bash, tmux, util-linux (`script`), and the requested
agent command. `--image` selects another image. The normal agent wrappers
and shell configuration are loaded, but the container runs without systemd
or automatic database startup. Supporting services belong in the VM.
Neither the Docker socket nor the VM's home directory is mounted into it.

`--settings` selects the settings directory (default `/settings`), mounted
read-only. Everyone with write access to the terminal can use the credentials
in that directory. Agent history, bundle cache, and shell history are isolated
per session. Token changes stay in the session; syncing refreshed credentials
back to the read-only settings directory is not supported in this first slice.

Repeat `--port` (also accepted as `--ports`) for additional TCP services.
`--port 3000` selects an unused
VM port; `--port 18080:3000` selects VM port 18080 explicitly. Both bind only
to `127.0.0.1` in the VM. Apps must listen on `0.0.0.0` inside the container.
`session ports` prints HTTP preview URLs; the forwarding itself also carries
WebSockets and other TCP protocols.
These are **session** ports: use `session start --port 3000`. The VM launcher's
`--ports` option is not required for Tailcat previews and does not publish a
port from an agent container. Ports must be selected when creating the session.

### Invite remote participants

The VM needs Tailcat (tested with v0.4.0), OpenSSH server, and a running systemd
user manager. Enable persistent user services once if needed:
`sudo loginctl enable-linger "$USER"`. The invitation commands run as your
normal VM user and do not change the VM's existing SSH server.

```shell
# On the VM: create one invitation per participant. Repeating this command
# displays the same invitation, including after attaching to the terminal.
bin/ai session invite web alice

# List invitations without displaying credentials.
bin/ai session invitations web

# On the participant's Mac or Linux machine, from a checkout of this repo:
bin/ai session join 'ai-session-v1.REPLACE_WITH_INVITATION' --port 3000

# Or receive the invitation as a file, keeping the credential out of shell
# history and process arguments:
bin/ai session join @alice.invite --port 3000

# Home-relative invitation paths also work:
bin/ai session join @~/Downloads/alice.invite --port 3000

# On the VM: disconnect this invitation's terminal and preview tunnels.
bin/ai session revoke web alice
```

Joining directly from a checkout requires Ruby 3.1 or newer, OpenSSH client, and
`tailcat` on PATH.
On macOS, install Tailcat with `brew install tailcat`
([upstream installation instructions](https://github.com/tailscale/tailcat/blob/main/INSTALL.md)).
`join` checks for missing client tools before attempting a connection.

To keep SSH and Tailcat inside a container, select Podman or Docker:

```shell
bin/ai session join --podman @~/Downloads/alice.invite --port 3000
bin/ai session join --docker @~/Downloads/alice.invite --port 3000

# Use a different local browser port:
bin/ai session join --podman @~/Downloads/alice.invite --port 13000:3000
```

The helper requires Ruby and the selected container engine on the participant's
machine. Start the engine first; for Podman on macOS, run `podman machine start`
after the usual initial setup. The helper runs `ghcr.io/dentarg/ai:latest`,
mounts the invitation read-only, sets the preview bind address, and publishes
ports only on host loopback. Repeat `--port` for more apps, or omit it for
terminal-only access. `--image IMAGE`
selects a different participant image. A missing image is pulled automatically;
use `podman pull ghcr.io/dentarg/ai:latest` or `docker pull ghcr.io/dentarg/ai:latest`
to refresh an already cached image.

Participants can also join using Docker without cloning this repository or
installing Ruby or Tailcat locally. Save the invitation as a file, then run:

```shell
docker pull ghcr.io/dentarg/ai:latest
docker run --rm --init -it \
  --mount "type=bind,src=$HOME/Downloads/alice.invite,dst=/invitation,readonly" \
  --entrypoint ai-join \
  ghcr.io/dentarg/ai:latest @/invitation
```

To browse an app published by the owner with `session start --port 3000`:

```shell
docker run --rm --init -it \
  --mount "type=bind,src=$HOME/Downloads/alice.invite,dst=/invitation,readonly" \
  --publish 127.0.0.1:3000:3000 \
  --entrypoint ai-join \
  ghcr.io/dentarg/ai:latest @/invitation --port 3000 --bind 0.0.0.0
```

Open `http://127.0.0.1:3000` on the participant's machine. `--bind 0.0.0.0`
lets Docker reach the SSH preview listener inside the client container;
`--publish 127.0.0.1:3000:3000` keeps access on the host limited to localhost.
To use host port 13000, change only the publish mapping to
`127.0.0.1:13000:3000`. Use `--bind 0.0.0.0` only with the container setup;
normal `session join` previews bind to localhost by default.
Detach with **Ctrl+b, then d**. Docker removes the client container and its
temporary credentials; the shared agent keeps running. Run the same command
again to reconnect with the invitation.

An invitation grants access immediately; send it privately through your usual
chat. It contains an SSH private key and a pinned server host key. Anyone with
the invitation can use it, so use a separate participant name for each person.
Invitations remain valid until revoked, the session stops, or the VM shuts down.
The same invitation supports repeated and simultaneous connections while valid.
Revoked participant names cannot be reused until the session is stopped and
started again. Restarting requires fresh invitations; old ones stay revoked.

Tailcat carries an encrypted connection to a dedicated SSH endpoint on VM
loopback. SSH forces terminal attachment inside the agent container and permits
forwarding only to this session's published preview ports. Arbitrary VM commands,
agent forwarding, remote forwarding, and Unix socket forwarding are disabled.
Each invitation has its own systemd service, so revocation also closes existing
connections without interrupting other participants. Share only with trusted
collaborators: terminal writers have the agent container's full capabilities
and can read its mounted credentials and project files.
After revocation, the participant's terminal may take a few seconds to detect
the lost transport and close; access is already stopped on the VM.

`join --port 3000` makes the app available at `http://127.0.0.1:3000` on the
participant's machine while attached. Use `--port 13000:3000` if local port 3000
is occupied, and repeat the option for other published ports. Browser requests
and WebSockets travel through the same authenticated connection. Detaching
closes these tunnels; joining again restores them. The participant's SSH
credentials are saved with private permissions in
`${XDG_CONFIG_HOME:-~/.config}/ai/session-joins/`.

Remote terminal events identify the invitation name, not individual keystrokes.
Detailed bridge diagnostics are available through `journalctl --user -u UNIT`;
the service name is in the invitation's `invitation.json` under session data.

### Session history and tests

```shell
bin/ai session logs demo
bin/ai session logs demo --follow
bin/ai session replay demo
bin/ai session stop demo
```

Use `logs --follow` (or `logs -f`) to print existing lifecycle events and keep
watching for new ones. Press Ctrl+C to stop following.

Session data lives in `/history/multiplayer/<name>` when `/history` exists,
otherwise `$AI_DIR/history/multiplayer/<name>` (`AI_DIR` defaults to `~/ai`).
`AI_SESSION_DIR` overrides this location. It contains the agent's own history,
a terminal output/timing recording, and a logfmt lifecycle log. Raw keystrokes
are not recorded, but text echoed on screen is. Terminal recordings do not
attribute prompts to participants. Replay uses util-linux `scriptreplay` in
the VM. Stopping removes the container while retaining these files. Start a
stopped session again with the same name and an agent command:

```shell
bin/ai session start demo --detach --port 3333 -- cx
```

The saved workspace, image, settings, and port mappings are reused unless
overridden. Supplying `--port` replaces the previous port mappings. Each start
creates a new container and agent process; use the agent's resume option to
continue an earlier conversation. Agent history, shell history, and bundle
cache are retained, but packages installed only in the removed container are
lost. The previous recording, session metadata, and invitation records move
to `runs/<previous-run-id>/` within the session directory. `session replay`
plays the current run's recording. Create new invitations after restarting.
Disconnects preserve running sessions, but VM reboot recovery is not implemented.

Run the integration tests without agent credentials or model requests.
The remote tests need the VM services listed above and reach Tailcat's relay
network; the local tests need only Docker and Ruby with Minitest:

```shell
docker build -f tools/session/Dockerfile.test -t ai-session-test:latest tools/session
ruby tools/session/test_session.rb

# Local tests only (also run against each candidate image in CI):
ruby tools/session/test_session.rb --exclude '/remote|tailcat/'

# Include joining through both Docker and Podman helpers with browser preview forwarding:
docker build -t ai-session-client-test:latest .
docker save ai-session-client-test:latest | podman load
AI_SESSION_CLIENT_IMAGE=ai-session-client-test:latest ruby tools/session/test_session.rb
```

## Remote control

[Remote control](https://code.claude.com/docs/en/remote-control) lets you
monitor and steer a running Claude Code session from claude.ai or the Claude
mobile app. The session keeps running in the container — only its I/O is
mirrored, over the same outbound HTTPS the agent already uses.

It is **off by default** and opt-in per session, because it exposes the
session (filesystem, MCP servers, every tool call) to anyone with your
claude.ai login. Turn it on with either:

```shell
bin/ai c <profile> --remote      # one-off flag
AI_REMOTE=1 bin/ai c <profile>   # or set the env in your shell
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
bin/ai c <profile> --fast      # one-off flag
AI_FAST=1 bin/ai c <profile>   # or set the env in your shell
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
- [x] [Terraform](https://developer.hashicorp.com/terraform)
- [x] ast-grep
- [x] [fnox](https://fnox.jdx.dev/) — encrypted and remote secret manager
- [x] tmux
- [x] SSH (`ssh-keygen`, ...)
- [x] SQLite
- [x] PostgreSQL
- [x] LavinMQ
- [x] Redis
- [x] [Toxiproxy](https://github.com/Shopify/toxiproxy) — network failure simulation
- [x] [amqpcat](https://github.com/cloudamqp/amqpcat)
- [x] [tailcat](https://github.com/tailscale/tailcat) — netcat over Tailscale's data plane
- [x] [rusage](https://justine.lol/rusage/) — better `time(1)`, prints full `getrusage(2)` stats
- [x] [logcli](https://grafana.com/docs/loki/latest/query/logcli/) — Grafana Loki CLI
