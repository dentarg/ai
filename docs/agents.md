# Agent features and plugins

[README](../README.md)

## Claude Code sessions

`c` starts services before launching Claude. The bundled `PermissionRequest`
hook approves Bash requests, including the critical-path `rm` safeguard that
bypass-permissions mode leaves enabled.

## Codex sessions

`bin/ai` mounts the project at `/app`, and `cx` preserves that working
directory when it launches Codex. Terminal tabs show
`project [oauth-profile] - Codex`, with the host working directory name
first so it stays visible in narrow tabs. Hostnames are omitted from the title.
Containers still use matching names and hostnames of `ai-c-XX-<project>`,
distinct from the VM prefixes `ai-l-`, `ai-g-`, and `ai-m-`. Containers
choose the first free number from `00` to `99`, including stopped containers
when checking availability. Codex title updates are disabled so they do not
replace the title with `app`. Its generated statusline
shows the current directory, git branch, model/reasoning, context used, and
thread id. TUI notifications are disabled for quieter terminal sessions. Codex defaults to
`gpt-6-astra`. To override the default for an OAuth profile, add native Codex
configuration such as
`model = "gpt-6-sol"` to
`~/ai/settings/codex_<oauth-profile>/default.config.toml`. Use
`~/ai/settings/codex/default.config.toml` for the unprofiled account.
`cx --resume <id>` searches archived Codex rollouts under `/history` and
reuses the original Codex home before launching `codex resume <id>`.

Use `cx [<oauth-profile>] --profile <config-profile>` to load a named native
configuration from `~/ai/settings/codex[_<oauth-profile>]/<config-profile>.config.toml`.
See [configuration](configuration.md) for profile and model defaults, and
[usage](usage.md#resume-or-fork) for resuming or forking conversations.

## Antigravity CLI

[Google Antigravity CLI](https://antigravity.google/docs/getting-started/)
runs inside the same sandbox as the other agents. Rebuild the image or Lima
base to install it, then launch it with:

```shell
bin/ai g
bin/ai g work
bin/ai g work --vm
bin/ai antigravity work --macos
bin/ai g work --resume <conversation-id>
```

On first launch, select Google OAuth, open the displayed URL in your host
browser, and paste the authorization response back into the CLI when prompted.
Each profile creates its own persistent state automatically; `ai profile`
continues to manage Claude and Codex profiles. Resume with the same profile
used to create the conversation, or use `/resume` inside the CLI. Use `/fork`
inside Antigravity to fork a conversation.

Global configuration lives under
`~/ai/settings/antigravity` (or `antigravity_<profile>`). The CLI state directory
is linked to `~/ai/history/antigravity` (or `antigravity_<profile>`), keeping
conversations, OAuth fallback credentials, logs, settings, and installed plugins
across sandbox restarts. The keyring scope under `~/.config/antigravity` is
linked to the profile's `keyring` directory in settings.
The launcher points `~/.gemini` at the selected profile. Any existing real
`~/.gemini` directory is saved under `~/.gemini-backup.*` first. Shared
`~/ai/settings/AGENTS.md` instructions and the bundled host skills are loaded
for Antigravity.

Inside an existing sandbox, use the wrapper and native CLI options:

```shell
g
g --profile work
g --profile work --conversation <conversation-id>
g --profile work models
```

The wrapper enables `--dangerously-skip-permissions`. Release URLs and SHA-512
checksums for Linux and macOS on AMD64 and ARM64 are pinned in
`versions/antigravity-cli.json`. Both builders accept `--update-antigravity`;
`--update-agents` refreshes these pins too.

## Remote control

[Remote control](https://code.claude.com/docs/en/remote-control) lets you
monitor and steer a running Claude Code session from claude.ai or the Claude
mobile app. The session keeps running in the container — only its I/O is
mirrored, over the same outbound HTTPS the agent already uses.

It is **off by default** and opt-in per session, because it exposes the
session (filesystem, MCP servers, every tool call) to anyone with your
claude.ai login. Turn it on with either:

```shell
bin/ai c <profile> --remote      # one-off flag
AI_REMOTE=1 bin/ai c <profile>   # or set the env in your shell
```

`bin/ai` forwards this into the container as `AI_REMOTE=1`; `c` then sets
`remoteControlAtStartup` in the session's `~/.claude/settings.json` — the same
key the `/config` "Enable Remote Control for all sessions" toggle writes, so the
bridge starts automatically. Running `c` directly honours the same `--remote`
flag and `AI_REMOTE` env. To make it the default for every session, export
`AI_REMOTE=1` in your host shell profile.

Remote sessions are labelled by the host directory in the claude.ai/mobile
list — `c` sets `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX` from `HOST_DIR`, so
they show as `<dir>-<random-words>` instead of the container hostname.

To enable it on an already-running session, run `/remote-control` (or `/rc`)
in the TUI; a `/rc active` link then appears in the footer.

## Fast mode

[Fast mode](https://code.claude.com/docs/en/fast-mode) runs Opus with
higher-speed output. It is **off by default** and opt-in per session, because
it draws from usage credits at a higher rate and has separate rate limits.
Turn it on with either:

```shell
bin/ai c <profile> --fast      # one-off flag
AI_FAST=1 bin/ai c <profile>   # or set the env in your shell
```

`bin/ai` forwards this into the container as `AI_FAST=1`; `c` then sets
`fastMode` in the session's `~/.claude/settings.json` — the same key the
`/fast` toggle writes. Running `c` directly honours the same `--fast` flag and
`AI_FAST` env. To make it the default for every session, export `AI_FAST=1` in
your host shell profile. Toggle it within a session with `/fast [on|off]`.

`c` also exports `CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK=1` in the fast path.
Without it the persisted `fastMode` is evaluated once at startup, while the
async fast-mode availability check is still pending, so in a fresh container it
resolves to off and never re-applies; skipping that check lets the setting
engage immediately.

## Claude Code plugins

Plugin marketplaces are baked into the image, so their commands are there in
every session and every project with no per-project configuration. List one per
line in `versions/claude-plugins`:

```
# <name>  <git url>  <commit>
84codes  https://github.com/84codes/claude-plugins.git  d53b7805…
```

At build time each is cloned to `/opt/claude-plugins/marketplaces/<name>`,
validated, and every plugin it declares with an in-repo source is symlinked
into `/opt/claude-plugins/enabled/`. On launch, `c` links those into the
session's `~/.claude/skills/`, where Claude Code auto-loads each as
`<name>@skills-dir`, enabled by default. Today that gives you `/gem:bump`.

Plugins a marketplace sources from *another* repo are skipped, with a count in
the build log — add that repo as its own line to vendor them. Two marketplaces
providing the same plugin name is a build error rather than a coin flip.

```shell
# re-pin every marketplace to its remote HEAD, then rebuild
./build_image --update-plugins
```

### Blocking a plugin

Everything baked in loads by default. To keep one off, name it in
`claude/plugins.blocklist` (version controlled, ships in the image) or in
`~/ai/settings/plugins.blocklist` on the host (no rebuild needed) — the two are
merged:

```
# one plugin name per line
code-simplifier
```

Blocked plugins are still installed and still listed by `/plugin`; they just
start disabled, so you can turn one on for a single session:

```shell
claude plugin list
#   ❯ gem@skills-dir            ✔ loaded
#   ❯ code-simplifier@skills-dir  ✘ disabled

claude plugin enable code-simplifier@skills-dir
```

`c` rewrites the session's `settings.json` on every launch by merging
`claude/settings.json` with the selected profile's
`~/ai/settings/claude_<profile>/settings.json`. Removing a name from the
blocklist therefore re-enables it next time — nothing to undo.

### Why not `claude plugin install`

`~/.claude` is a fresh per-session directory under `/history` (see
`tools/claude.sh`). A real install writes `known_marketplaces.json`,
`installed_plugins.json` and `enabledPlugins` into it, all carrying absolute
paths into that throwaway directory, so it would be discarded on every launch.
`extraKnownMarketplaces` in settings doesn't help either: it is only acted on by
the interactive trust dialog. Symlinking into `~/.claude/skills/` sidesteps all
of it — and because they're symlinks into the image, a rebuild reaches resumed
sessions too.

## Codex plugins

Codex marketplaces are pinned separately in `versions/codex-plugins`:

```
# <name>  <git url>  <commit>
dentarg  https://github.com/dentarg/codex-plugins.git  d9eeb3d3…
```

Image and VM builds clone each marketplace, install every local plugin into a
validated Codex cache, and enable it in a reusable configuration fragment.
`cx` copies that cache and configuration into every new or resumed session.
The `dentarg/codex-plugins` marketplace currently provides the `gem@84codes`
plugin and its `$gem-bump` skill.

`./build_image --update-plugins` refreshes the Claude Code and Codex pins;
`./build_vm --update-plugins` refreshes the Codex pins used by the VM. A
selected Codex configuration profile can disable a baked plugin because profile
configuration is layered above the generated base configuration.

## MCP Servers

### Sentry

To enable Sentry's MCP server so the agent can fetch issues, events, and
stack traces directly, drop your Sentry
[user auth token](https://sentry.io/settings/account/api/auth-tokens/) in
`$HOME/ai/settings/sentry.token` (just the token, no quotes or whitespace).

When you launch `c <profile>`, an `mcpServers.sentry` entry is injected into
the session's `~/.claude.json` that runs
[`@sentry/mcp-server`](https://github.com/getsentry/sentry-mcp) locally over
stdio with `SENTRY_ACCESS_TOKEN` set. We don't use the hosted
`mcp.sentry.dev` because its OAuth flow expects a callback on
`localhost:62880` inside the browser host — unreachable from this container.

For self-hosted Sentry, additionally drop the hostname in
`$HOME/ai/settings/sentry.host` (e.g. `sentry.example.com`) — it's passed
through as `--host=...`.

No `sentry.token` → no MCP server registered.
