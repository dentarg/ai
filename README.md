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

docker image inspect ai:latest
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
- [ ] PostgreSQL
- [ ] LavinMQ
