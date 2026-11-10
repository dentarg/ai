# Environment and services

[README](../README.md)

## Files and persistence

The project is mounted at `/app`. Other persistent data lives under `AI_DIR`
(default `~/ai` on the host):

| Host directory under `AI_DIR` | Sandbox path | Contents |
| --- | --- | --- |
| `settings` | `/settings` | Credentials, profiles, and dotfiles |
| `history` | `/history` | Agent transcripts |
| `share` | `/share` | Shared files |
| `repos` | `/repos` | Cloned repositories |
| `bundle` (`bundle-macos` for macOS) | `/bundle` | Installed gems |
| `commandhistory` | `/commandhistory` | Shell history |

See [configuration](configuration.md) for dotfiles, credentials, and Git ignores.

Use [the history viewer](../tools/history-viewer/README.md) to browse archived
Claude, Codex, and Pi sessions with `bin/history-viewer`.

## Installed tools

The Linux image includes the following tools. See
[macOS VMs](virtual-machines.md#macos-lima-vm-backend) for platform differences.

- Claude Code
- OpenAI Codex
- GitHub Copilot
- Google Antigravity CLI
- Node.js
- Bun
- Ruby
- Crystal 1.21.1 (official bundled release, checksum verified)
- Python
- Rust
- Go
- [Terraform](https://developer.hashicorp.com/terraform)
- ast-grep
- [jactionlint](https://github.com/jdx/jactionlint) for GitHub Actions workflow checks (Linux and macOS)
- [fnox](https://fnox.jdx.dev/) — encrypted and remote secret manager
- tmux
- SSH (`ssh-keygen`, ...)
- SQLite
- PostgreSQL
- LavinMQ
- RabbitMQ and Erlang
- Redis
- [Toxiproxy](https://github.com/Shopify/toxiproxy) — network failure simulation
- [amqpcat](https://github.com/cloudamqp/amqpcat)
- [tailcat](https://github.com/tailscale/tailcat) — netcat over Tailscale's data plane
- [rusage](https://justine.lol/rusage/) — better `time(1)`, prints full `getrusage(2)` stats
- [logcli](https://grafana.com/docs/loki/latest/query/logcli/) — Grafana Loki CLI

Claude Code and Codex receive a shared [jactionlint skill](../skills/jactionlint/SKILL.md)
on launch to validate workflow and composite action changes.

## RabbitMQ

RabbitMQ and Erlang are installed in the container, both VM backends, and
Claude cloud setup. Linux uses Ubuntu packages; macOS uses Homebrew.
LavinMQ remains the default broker. Both use port 5672,
so stop LavinMQ before starting RabbitMQ:

```shell
# Linux container or VM
sudo systemctl stop lavinmq
sudo systemctl start rabbitmq-server

# Claude cloud sandbox (root)
service lavinmq stop
service rabbitmq-server start

# macOS VM
sudo brew services stop lavinmq
brew services start rabbitmq
```
