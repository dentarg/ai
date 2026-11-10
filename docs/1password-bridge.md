# 1Password bridge

[README](../README.md)

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
