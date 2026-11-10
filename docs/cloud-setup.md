# Claude Code cloud setup

[README](../README.md)

Paste this into the cloud environment's **Setup script** field:

```bash
#!/bin/bash
# provisioning-revision: 2026-11-10-1 (change to refresh the cache)
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
See the [setup script](../tools/claude-cloud-setup.sh) for what it installs.
