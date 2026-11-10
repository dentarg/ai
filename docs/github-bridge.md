# GitHub bridge

[README](../README.md)

Use `bin/ai c --github=work` (or `AI_GITHUB=1 AI_GITHUB_PROFILE=work`) to enable restricted host `gh`
operations. Like the 1Password bridge, this requires a macOS host with `ruby`,
`op`, and the 1Password desktop integration enabled. Install `gh` on the host
as well. The container and Lima guests use the `gh-host` client; rebuild the
image or VM base to install it.

The image and both VM bases also ship the shared
[`gh-host` skill](../skills/gh-host/SKILL.md). On bridge-enabled launches, `c`
links it into the session's `~/.claude/skills/` and `cx` links it into
`~/.agents/skills/`. Both agents can select it automatically for PR and issue tasks;
you can also invoke `/gh-host` in Claude Code or `$gh-host` in Codex.
It explains repository selection, supported commands, approval, and safe
handling of denied or uncertain requests. Launching without the bridge removes
only the link managed by the wrapper; an existing user-authored skill is
preserved. The host broker remains responsible for enforcing permissions.

## Setup

Store a fine-grained GitHub token in 1Password, restricted to the repositories
needed and with an expiration. Grant Pull requests read permission for PR reads
and Issues read permission for issue reads. CI runs, logs, and artifacts need
Actions read permission. Pull requests write permission is
needed to create PRs, edit descriptions, reply to comments, or resolve review
threads, and Issues write permission is needed to create issues. Media uploads
also require repository write access. The bridge resolves the
configured reference through host `op` for each request and passes the token
only to host `gh`. It does not use your normal `gh` login or expose a token-read
operation to the container.

Resolving review threads currently also requires
[`Contents: write`](https://github.com/orgs/community/discussions/204269).

Configure access once on the host, from any directory:

```shell
bin/github-bridge init \
  work my.1password.com op://Agent/GitHub/token \
  'company/*' 'another-org/*' owner/example
bin/github-bridge show work

# Optional: replace the allowed operations, including PR and issue writes.
bin/github-bridge allow work \
  pr-list pr-view pr-diff pr-comments pr-reviews pr-review-comments pr-review-threads \
  issue-list issue-view issue-comments issue-timeline issue-create \
  pr-create pr-edit-body pr-comment pr-review-reply pr-review-resolve asset-upload \
  run-list run-view run-jobs job-log run-artifacts run-logs artifact-download
bin/github-bridge check work
bin/github-bridge list
bin/ai cx --github=work
```

Each named profile has its own token, repository scopes, and allowed operations,
independent of checkout. Mix exact `OWNER/REPO` entries with quoted `ORG/*`
entries to allow all current and future repositories under one or more owners.
Matching is case-insensitive; owner scopes also work for personal accounts.
Only an entire repository component may be `*`; arbitrary globs are rejected.
The token must also have access to each target repository.

`init` replaces only the named profile and resets its operations to read-only;
`allow` replaces only that profile's operation list. Other profiles are preserved.
Both validate and save atomically with mode `0600`. The 1Password reference is
configurable per profile. Each session uses exactly one profile and cannot switch
tokens through `gh-host`. Bare `--github` selects `AI_GITHUB_PROFILE`, defaulting
to `default`; unknown profiles fail at startup.
The launch directory is included only in audit logs and approval dialogs.

## Policy configuration

The policy lives at `~/.config/ai/github-bridge.json`, honoring an absolute
`XDG_CONFIG_HOME`, with the same defaults as the 1Password policy. `--file`
selects a different file for the configuration CLI only. The launcher reads
the standard location. Restart enabled sessions after policy changes.

```json
{
  "profiles": {
    "work": {
      "account": "my.1password.com",
      "token": "op://Agent/GitHub/token",
      "repositories": ["company/*", "another-org/*", "owner/example"],
      "operations": [
        "pr-list", "pr-view", "pr-diff", "pr-comments", "pr-reviews",
        "pr-review-comments", "issue-list", "issue-view",
        "issue-comments", "issue-timeline"
      ]
    }
  }
}
```

## Pull requests and issues

Inside an enabled container or VM:

```shell
gh-host pr-list owner/example
gh-host pr-view owner/example 123
gh-host pr-diff owner/example 123
gh-host pr-comments owner/example 123
gh-host pr-reviews owner/example 123
gh-host pr-review-comments owner/example 123
gh-host pr-review-threads owner/example 123
gh-host pr-comment owner/example 123 < reply.txt
gh-host pr-review-reply owner/example 123 THREAD_ID < reply.txt
gh-host pr-review-resolve owner/example 123 THREAD_ID
gh-host issue-list owner/example
gh-host issue-view owner/example 456
gh-host issue-comments owner/example 456
gh-host issue-timeline owner/example 456
gh-host issue-create owner/example 'Issue title' < issue-body.txt
printf '%s\n' 'Describe the change here.' | \
  gh-host pr-create owner/example feature-branch main 'PR title'
gh-host pr-edit-body owner/example 123 < pr-body.txt
```

`pr-comments` reads discussion comments, `pr-reviews` reads review summaries and
verdicts, and `pr-review-comments` reads inline comments and replies with their
file/line context. `issue-list` reads open and closed issues, excluding PRs;
`issue-view` reads the issue body and metadata (including labels, assignees,
milestone, and reaction counts). `issue-comments` reads the conversation and
`issue-timeline` reads activity such as label changes and cross-references.
These collection commands follow all pages and return one JSON array. Existing
output and time limits still apply: oversized reads fail rather than return
partial results. Attachment links remain links; their contents are not fetched.
Existing profiles must enable the new operations with `allow` and restart their
sessions; `allow` replaces the complete operation list.

`pr-list` returns up to 30 open PRs. Read operations return GitHub JSON or a
plain diff. PR creation uses an already-pushed branch in the selected repository,
creates a draft with maintainer edits disabled, and requires a macOS dialog
showing the exact request. Denial or a 60-second approval timeout prevents the
write. Reads rely on the host allowlist without an extra approval dialog;
1Password may still require authorization. Creating a PR may trigger repository
automation. A failed or timed-out create can have succeeded remotely; inspect
the PR list before retrying.

`issue-create` creates an issue using a title argument and the exact body from
stdin, returning the created issue as JSON. Titles must be nonblank and at most
256 bytes; bodies may be empty and are limited to 8 KiB. Enable `issue-create`
in the host operation allowlist and grant the token Issues write permission.
The host dialog shows the repository, title, and body; denial or a 60-second
approval timeout prevents the write. Labels, assignees, and milestones are not
supported. Creation may trigger repository automation. If the result is
uncertain, inspect `issue-list` and `issue-view` before retrying to avoid duplicates.
New profiles remain read-only.

`pr-comment` posts a general PR discussion comment. `pr-review-reply` replies
to an existing review thread; `pr-review-resolve` marks that thread resolved.
Each write requires its own allowlist entry, Pull requests write permission,
and host approval. Reply bodies come from stdin, must be nonblank, and are
limited to 8 KiB. Replies do not automatically resolve threads. General PR
discussion comments cannot be resolved.

Use `pr-review-threads` to obtain thread IDs and resolution state. It follows
all pages and returns a JSON array with `id`, `isResolved`, `isOutdated`,
file/line context, and the first comment of each thread. The first comment's
`databaseId` maps to `id` in `pr-review-comments`, which returns the full
conversation. Supply the thread's GraphQL `id`, not a comment ID, for replies
and resolution. The host verifies its repository and PR before either write.
After an uncertain reply, reread comments before retrying; after uncertain
resolution, reread threads. Thread operations use fixed GraphQL queries and
mutations, with a 60-second total deadline and 2 MiB combined response limit.

## Attachments

Upload an image or video from the guest with `asset-upload`, then insert its
returned Markdown into a comment or description:

```shell
gh-host asset-upload owner/example screenshot.png > asset.json
jq -r .markdown asset.json > comment.md
gh-host pr-comment owner/example 123 < comment.md
```

The response contains `url` and `markdown`. Images use Markdown image syntax;
videos use a bare URL, which should occupy its own paragraph. The same Markdown
works in `issue-create`, `pr-create`, `pr-edit-body`, and `pr-review-reply` bodies.
Existing body text is preserved by composing the full body file before posting.
Uploading requires the separate `asset-upload` allowlist entry and host approval
showing the repository, filename, media type, size, and SHA-256 digest. The client
sends file bytes; the host never opens a guest-supplied file path. Received files
are stored temporarily with mode `0600` and removed after the request.

This uses the upload endpoint behind GitHub CLI's
[`--attach` support](https://github.blog/changelog/2026-09-01-github-cli-media-in-issues-pull-requests-and-comments/).
Use host `gh` 2.99.0 or newer. Supported formats are PNG, JPEG, GIF, WebP, SVG,
MP4, MOV, and WebM. Images are limited to 10 MiB and videos to 100 MiB; GitHub
may enforce a lower video limit for the account's plan. Uploads are separate
from posting text, so retain the returned URL if posting fails and reuse it
instead of uploading again. An uncertain upload may have left an unattached
asset; the bridge cannot list or delete uploaded assets.

`pr-edit-body` replaces an existing PR's description with the exact text from
stdin (up to 8 KiB); empty input clears it. It sends only the body field and
returns the updated PR as JSON. Enable `pr-edit-body` in the host operation
allowlist and restart the session. Like creation, it requires Pull requests
write permission and a host dialog showing the repository, PR number, and new
body. Read the current description with `pr-view` before editing. Replacement
can overwrite concurrent edits; after a failed or timed-out update, read the
PR again before deciding whether to retry. New profiles remain read-only.

## CI runs and artifacts

Read GitHub Actions runs, logs, and artifacts with:

```shell
gh-host run-list owner/example
gh-host run-list owner/example HEAD_SHA
gh-host run-view owner/example RUN_ID
gh-host run-jobs owner/example RUN_ID
gh-host job-log owner/example JOB_ID
gh-host run-artifacts owner/example RUN_ID
gh-host run-logs owner/example RUN_ID logs.zip
gh-host artifact-download owner/example ARTIFACT_ID artifact.zip
```

`run-list` returns up to 30 recent runs, optionally filtered by a full 40-character
commit SHA. For a PR, get its `head.sha` from `pr-view`. Use the returned run's
`id`, not its display `run_number`, with the other run commands. `run-view`
returns status and conclusion as JSON. `run-jobs` follows all pages for the
latest attempt, including job IDs and step status. `job-log` returns plain text
with terminal control sequences removed, limited to 10 MiB.

`run-artifacts` follows all pages and returns artifact IDs, names, sizes, expiry,
and any available digests. `run-logs` downloads the run's log archive, and
`artifact-download` downloads one artifact by ID. Artifacts may be ZIP archives
or individual files uploaded with `archive: false`; choose a matching filename.
Both downloads require a new local destination file and preserve the original
bytes without extracting them on the host. Downloads are limited to 100 MiB
and are published to the requested path only after a successful transfer.
Existing files are never overwritten;
failed downloads remove their temporary files. Expired or unavailable logs and
artifacts fail rather than returning partial files.

Use host `gh` 2.102.0 or newer for CI reads. New profiles include these read
operations; existing profiles must add them to their complete `allow` list.
They use repository allowlists and Actions read permission without a host
write-approval dialog. The bridge does not rerun, cancel, or dispatch workflows.
Third-party CI logs are not supported.

## Permissions, limits, and audit logs

The broker supports github.com and the operations listed above only. It constructs
fixed `gh api` requests, validates all arguments on the host, and rejects extra
fields. Each `gh` process uses an empty configuration directory and a restricted
environment, outside the project checkout. Neither arbitrary commands, API
paths, host file paths, nor caller-supplied environment variables are accepted.

Each enabled session gets a bearer token and ephemeral TLS certificate valid
for 45 days. The 1Password bridge shares this certificate lifetime. Only
the public bridge directory is mounted into the guest; the policy and command
configuration stay on the host. JSON requests are limited to 16 KiB, text bodies to
8 KiB, metadata output to 2 MiB, and each `op`/`gh` process to 60 seconds. Job
logs and binary downloads use the limits above; downloads stay in private temporary
files until transferred and are not modified by text redaction. TLS and
request reads have a 10-second deadline, except binary asset transfers, which
have a 60-second deadline and the media size limits above. Binary downloads also
have a 60-second transfer deadline. The broker handles
one request at a time. It exits with the session and removes its runtime directory.

Audit events go to `$AI_DIR/logs/github-bridge.log` (default
`~/ai/logs/github-bridge.log`). Every event includes a UTC `timestamp` with
millisecond precision and `session_id`, the unique `github.…` bridge identifier
for that container/VM launch. Startup, request, and shutdown events share this
ID; it identifies the bridge session rather than a Claude/Codex conversation.
Failed requests include the failing stage and exception class. GitHub API
failures also include a bounded, redacted `error_message`, the command's
`exit_status`, and `http_status` or `github_error_type` when available. Review
thread failures distinguish lookup, reply, and resolution. A failed request
produces one `request_failed` record; it is not also logged as rejected.
Tokens, token references, supplied text bodies, raw response data, and
1Password command output are omitted. API diagnostics stay on the host; the
guest receives a generic failure. Returned repository content is visible to
the agent.

## Tests

Run the bridge tests with:

```shell
for test in tools/github-bridge/test_*.rb; do ruby "$test" || break; done
bash tools/test_github_bridge.sh
bash tools/test_agent_skills.sh
```
