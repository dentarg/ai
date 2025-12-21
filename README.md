# `ai` image

Create `$HOME/ai/settings` with `.claude.tmpl.json`:

```json
{
  "bypassPermissionsModeAccepted": true,
  "hasCompletedOnboarding": true,
  "primaryApiKey": "op://vault-name/long-id/password",
}
```

Add `CLAUDE.md` to `$HOME/ai/settings` if you want.

```shell
# start podman and share the current working directory
bin/ai

# launch claude
cool_claude
```

## Prerequisites

Your Anthropic API key in 1Password.

```shell
brew install podman
podman machine init
podman machine start
./build_image
```

## Tricks

```shell
docker run --rm -it --net=container:<container> nicolaka/netshoot tcpdump -i any
podman run --rm -it --cap-add=NET_RAW --cap-add=NET_ADMIN --net=container:<container> nicolaka/netshoot tcpdump -i eth0

docker image inspect ai:latest

# give more disk/memory (memory is in MiB, disk in GiB)
podman machine stop
podman machine set --disk-size 200
podman machine set --memory 8192
podman machine start

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
