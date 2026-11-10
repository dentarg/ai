# Profiles and configuration

[README](../README.md)

## Profiles and models

```shell
# create configuration files for a named Codex and Claude profile
bin/ai profile create <profile>

# remove a profile's Codex settings, Claude settings, and credentials
bin/ai profile remove <profile>

# authenticate either agent for the profile
bin/ai profile login <profile> codex
bin/ai profile login <profile> claude

# set the model each agent starts with for this profile
bin/ai profile set-model <profile> codex gpt-6-astra
bin/ai profile set-model <profile> claude claude-opus-4-8

# refresh the cached OpenAI and Anthropic model catalog
bin/ai models refresh

# show configured profiles and authentication status
bin/ai profile list
```

Drop per-profile OAuth credentials in `$HOME/ai/settings` as
`.credentials.<profile>.json`. They get mounted into the container and copied
into `~/.claude/` when you launch claude with a matching profile. See the
[OAuth login](#oauth-login) section for how to generate these.

Codex profiles are stored as `$HOME/ai/settings/codex_<profile>/auth.json`.
The unprofiled default remains `$HOME/ai/settings/codex/auth.json`.
Claude profile settings are stored as
`$HOME/ai/settings/claude_<profile>/settings.json` and are merged over the
baked defaults at launch.

Profile model values are validated against a small bundled catalog. Run
`bin/ai models refresh` to download RubyLLM's model registry, retain only the
OpenAI and Anthropic fields used here, and cache the compact result under
`$HOME/ai/cache/models.json`. Launching, completing commands, and setting a
model never downloads the registry.

## Shared instructions and dotfiles

Put shared agent instructions in `~/ai/settings/AGENTS.md`. The wrappers load
them as `CLAUDE.md` for Claude, `GEMINI.md` for Antigravity, and session
instructions for Codex. Files in `~/ai/settings/dotfiles` are linked into the
sandbox home; `.bashrc` is sourced after sandbox setup, and `.bash_profile`
is reserved for the image.

[`gitignore-global`](../gitignore-global) supplies `.DS_Store` through
`/etc/gitignore`. A mounted `.gitconfig` with a missing personal ignore file
falls back to this default without editing the mounted settings.

For Sentry tokens and plugin settings, see [agent features](agents.md).

## OAuth Login

First-time setup to get OAuth credentials.

Claude Code:

```shell
# inside the container, or via podman run
refresh-tokens --login
refresh-tokens --login <profile>
```

This generates an OAuth authorization URL. Open it in your browser, sign in, and paste the code back into the terminal. Credentials are saved to `~/.claude/.credentials.json` (or `.credentials.<profile>.json`).

OpenAI Codex:

```shell
# inside the container
codex-login
codex-login <profile>

# or from the host
bin/codex-login
bin/codex-login <profile>
```

This standalone helper starts Codex's "Sign in with Device Code" flow without
running the Codex CLI. Open the displayed URL, enter the one-time code, and
finish sign-in in your browser. Credentials are saved to
`/settings/codex/auth.json` in the container, or
`$HOME/ai/settings/codex/auth.json` from the host.
For a named profile, `codex_<profile>` replaces the `codex` directory name.

## Token Refresh

OAuth tokens expire periodically. `bin/ai` refreshes the profile's
credentials in `~/ai/settings` before each launch, and inside a session
Claude Code refreshes its own copy when it nears expiry. Sessions do not run
a refresh daemon: each refresh rotates the token, and extra rotations from
idle sessions sharing a profile can invalidate each other's copies. Use `l`
in Claude Code to recover the freshest credentials from session history.

```shell
# one-shot refresh (e.g. before launching a session)
refresh-tokens --once

# inspect active credentials saved in recent Claude session history
refresh-tokens --list-active
refresh-tokens --list-active <profile>

# print or copy the freshest active credentials for a profile
refresh-tokens --find-active <profile>
refresh-tokens --copy-active <profile> /path/to/.credentials.json
```

The service can also run as a standalone container to refresh `/settings` credentials:

```shell
podman run -d --name token-refresh \
  --env CREDENTIALS_DIR=/settings \
  --volume ${HOME}/ai/settings:/settings \
  ai:latest /usr/local/bin/refresh-tokens --daemon
```

Environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `CREDENTIALS_DIR` | `~/.claude` | Directory containing `.credentials*.json` files |
| `CHECK_INTERVAL` | `300` | Seconds between checks |
| `REFRESH_BEFORE` | `3600` | Seconds before expiry to trigger refresh |
| `HISTORY_DIR` | `~/ai/history` | Claude session history to search |
| `HISTORY_DAYS` | `2` | Recent file-age window to search |
