# Usage

[README](../README.md)

The launcher's working directory is mounted at `/app`. Use
`/path/to/ai/bin/ai` from your project, or add this repository's `bin/`
directory to `PATH` and use `ai` from any checkout. Run `ai --help` for all
launcher options.

## Launch an agent

```shell
bin/ai                         # interactive shell
bin/ai c work                  # Claude Code
bin/ai cx work                 # Codex
bin/ai g work                  # Antigravity CLI
bin/ai c work --vm             # Linux VM
bin/ai c work --macos          # macOS VM
```

Profiles and resumed sessions require an explicit agent. Claude and Codex
profiles are managed with `bin/ai profile`; see [configuration](configuration.md).
Antigravity authenticates on first launch; see [agent features](agents.md).
Build a VM base before using `--vm` or `--macos`; see [building](building.md).

## Resume or fork

```shell
bin/ai c --resume <session-id>
bin/ai c work --resume <session-id>
bin/ai cx --resume <session-id>
bin/ai c --resume <session-id> --fork
bin/ai cx --resume <session-id> --fork
```

Add `--fork` to `bin/ai`, `c`, or `cx` with `--resume <id>` to create a new
conversation ID from the saved history, preserving the original transcript.
Claude launches with `--resume <id> --fork-session`; Codex launches with
`codex fork <id>`. For Claude, the wrappers also accept `--fork-session` as an
alias for `--fork`. Session ID prefixes and saved profile detection work as
for normal resumes, including the saved Codex configuration profile. Forked
transcripts are stored in the original session home. The option works with
Podman and both Linux and macOS VMs and requires an explicit `--resume` ID.

## Port forwarding

```shell
bin/ai c work --ports 9999             # host 9999 -> guest 9999
bin/ai c work --ports 8888:7777        # host 8888 -> guest 7777
bin/ai c work --ports 9999,8888:7777
bin/ai cx --vm --ports 9999
bin/ai c --vm --keep-vm --udp-ports 41641
```

The primary guest port comes from `PORT` (1337 by default). Both container and
VM launches choose a free host port and expose it inside the guest as
`HOST_PORT`. At startup, they print `http://localhost:<host-port>` on a
separate line for the primary TCP mapping and each `--ports` mapping.
Apps should listen on `PORT` and can use `HOST_PORT` when building
browser-facing URLs. For example, host port 45555 forwarded to guest port
1337 sets `PORT=1337` and `HOST_PORT=45555`. This describes the primary TCP
mapping; additional `--ports` and `--udp-ports` mappings remain explicit.
VM forwards bind to host loopback; set `AI_VM_HOST_PORT` to request a fixed
primary host port for a VM.

## VM resources

```shell
bin/ai c --keep-vm
bin/ai c --vm --nested-virt --cpus 8 --memory 16
bin/ai c --vm --gpu
```

`--keep-vm` preserves the VM after the shell exits. GPU and nested VM
requirements are documented in [virtual machines](virtual-machines.md) and
[local models](local-models.md).

## Inside the sandbox

```shell
s                              # start services; run Bundler when a Gemfile exists
c work                         # start Claude and services
c --apikey sk-ant-...
c --resume <session-id>
c --resume <session-id> --fork
cx work
cx --resume <session-id>
cx --resume <session-id> --fork
g
x                              # exit
```

See [agent features](agents.md) for Codex configuration profiles,
Antigravity subcommands, Claude remote control, fast mode, and plugins.

## Shell completion

```shell
source <(bin/ai completion zsh)
# Use "bash" instead of "zsh" for Bash.
```

Completion covers commands, profiles, agents, and model names.
