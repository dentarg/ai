# `ai` sandbox

Run Claude Code, Codex, or Google Antigravity CLI in a disposable Podman
container or Lima VM. Your project is mounted at `/app`; credentials, agent
history, shell history, and caches persist under `~/ai`.

Agents run with permission prompts disabled inside the sandbox. Language
runtimes, databases, and development tools are included. Optional
host bridges provide browser control, GitHub operations, and approved
1Password reads.

## Prerequisites

- **Containers:** Podman, `curl`, `jq`, and Ruby or Python 3 on the host.
  On macOS, install with `brew install podman jq` and initialize the Podman
  machine with `bin/setup-vm` from this checkout.
- **Linux VMs:** Lima and `jq`; build a base with `./build_vm`.
- **macOS VMs:** Apple Silicon, Lima 2.1+, and full Xcode; build with
  `./build_vm --macos`. This backend is experimental.

See [building and updating](docs/building.md) for full requirements and options.

## Quick start

Clone the repository and put its commands on your path:

```shell
git clone https://github.com/dentarg/ai.git
cd ai
export PATH="$PWD/bin:$PATH"
```

With Podman running, download the public image and authenticate a profile:

```shell
podman pull ghcr.io/dentarg/ai:latest
podman tag ghcr.io/dentarg/ai:latest ai:latest
ai profile create work
ai profile login work claude
```

Launch from the project you want the agent to work on:

```shell
cd /path/to/project
ai c work
```

For Codex, use `ai profile login work codex` and `ai cx work`. Antigravity
uses `ai g work` and authenticates on first launch. Exit the shell to remove
the disposable environment; `--keep-vm` retains a VM for inspection.

## Common commands

| Command | Purpose |
| --- | --- |
| `ai` | Open a sandbox shell |
| `ai c work` / `ai cx work` / `ai g work` | Launch an agent with a profile |
| `ai cx --resume <id>` | Resume a saved session |
| `ai cx --resume <id> --fork` | Fork a saved conversation |
| `ai c work --ports 3000` | Expose an application port |
| `ai c work --vm` | Use a Linux VM |
| `ai c work --macos` | Use a macOS VM |
| `ai --help` | Show all launcher options |

Inside the sandbox, `s` starts services, `c` / `cx` / `g` launches an agent,
and `x` exits. Repeat the image pull and tag commands to update, or build
locally with `./build_image` from this checkout.

## Documentation

Guide examples use paths relative to the repository root.

| Topic | Guides |
| --- | --- |
| Everyday use | [Usage](docs/usage.md), [profiles and configuration](docs/configuration.md), [agent features and plugins](docs/agents.md) |
| Environments | [Building and updating](docs/building.md), [virtual machines](docs/virtual-machines.md), [Claude cloud setup](docs/cloud-setup.md), [installed tools and services](docs/environment.md) |
| Local inference | [Models, GPU VMs, and native macOS inference](docs/local-models.md) |
| Host integrations | [Browser](docs/host-browser.md), [1Password](docs/1password-bridge.md), [GitHub](docs/github-bridge.md) |
| History and collaboration | [Shared terminals](docs/sessions.md), [history viewer](tools/history-viewer/README.md) |
| Diagnostics | [Troubleshooting](docs/troubleshooting.md) |
