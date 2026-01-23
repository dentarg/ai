# `ai` image

Create `$HOME/ai/settings` with `.claude.tmpl.json`:

```json
{
  "bypassPermissionsModeAccepted": true,
  "hasCompletedOnboarding": true,
  "primaryApiKey": "op://vault-name/long-id/password",
}
```

or `.claude.json` or `.claude.<profile>.json` (and optionally `.credentials.<profile>.json` with oauth tokens)

Add `AGENTS.md` to `$HOME/ai/settings` if you want. It will populate `CLAUDE.md` for Claude Code and `GEMINI.md` for Gemini CLI.

```shell
# start podman and share the current working directory
bin/ai
bin/ai --1p # if you want to use claude.tmpl.json with op:// reference

# start services (and run "bundle install" if Gemfile.lock exist)
s

# launch claude
cool_claude

# launch claude with a specific config
cool_claude <profile>

# launch gemini
g

# launch openai codex
oc
```

## Prerequisites

Your Anthropic API key in 1Password.

```shell
brew install podman
# memory is in MiB, disk in GiB
podman machine init --disk-size 200 --memory 8192 --now
./build_image
```

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

Commands

```shell
podman run --rm -it --cap-add=NET_RAW --cap-add=NET_ADMIN --net=container:<container> nicolaka/netshoot tcpdump -i eth0

# to see current settings
podman machine inspect

# when we can't build because we're out of space
podman system prune--all

# to combat this error related to "Linux Kernel Keyring quota"
# Error: preparing container ... for attach: crun: join keyctl `...`: Disk quota exceeded: OCI runtime error
podman machine ssh sudo sysctl -w kernel.keys.maxkeys=20000
podman machine ssh sudo sysctl -w kernel.keys.maxbytes=200000
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
- [x] [amqpcat](https://github.com/cloudamqp/amqpcat)
