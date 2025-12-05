# `ai` image

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

```json
{
  "bypassPermissionsModeAccepted": true,
  "hasCompletedOnboarding": true,
  "primaryApiKey": "...",
}
```

```shell
# This triggers prompt "Detected a custom API key in your environment"
# primaryApiKey in JSON config does not
export ANTHROPIC_API_KEY=your-api-key-here

IS_SANDBOX=1 claude --dangerously-skip-permissions --model opus
```

## Tricks

```shell
docker run --rm -it --net=container:<container> nicolaka/netshoot tcpdump -i any

docker image inspect ai:latest
```
