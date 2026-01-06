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

```shell
podman run --rm -it --cap-add=NET_RAW --cap-add=NET_ADMIN --net=container:<container> nicolaka/netshoot tcpdump -i eth0

# to see current settings
podman machine inspect

# when we can't build because we're out of space
podman system prune--all
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
