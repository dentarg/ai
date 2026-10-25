# git-history-ui reviews

Add new dated reviews above existing entries, newest first. Keep the
[update procedure](#updating-git-history-ui-review-then-pin) current.

## 2026-10-25: version 5.5.0

Upstream **5.5.0**, commit
[`8dbb85e8a2371338c5fbd90ba3ce313ddb1869df`](https://github.com/beingmartinbmc/git-history-ui/tree/8dbb85e8a2371338c5fbd90ba3ce313ddb1869df),
pinned in [`versions/git-history-ui`](../versions/git-history-ui).
[`inside_deps/install-git-history-ui.sh`](../inside_deps/install-git-history-ui.sh)
verifies that exact checkout, applies our locked dependency fixes, and builds
the backend, frontend, and SQLite addon. It uses `npm ci --ignore-scripts`,
explicit build commands, and disables Angular build analytics. Development
dependencies are removed from the installed application. No `latest` or
runtime `npx` install is used by the wrapper.

Source review covered the CLI, server middleware/routes, Git execution and
validation, persistence, external requests, frontend HTML rendering, package
manifests/lockfiles, and install/build/protocol scripts:

- Git queries use argument arrays with `execFile`/`spawn`, validate refs and
  paths, and separate file arguments with `--`. Normal browsing reads Git
  history; annotations, presets, and SQLite data are written under
  `~/.git-history-ui`. Local Git configuration can still invoke helpers such
  as textconv filters: use trusted repositories.
- The server requires a token on non-loopback listeners, accepts HTTP Basic
  passwords or bearer tokens, and exempts loopback requests. The wrapper
  listens on `0.0.0.0` inside the container and publishes only `127.0.0.1` on
  the host. It supplies a token for forwarded requests.
- The optional AI providers send queries, commit text, and diffs to Anthropic
  or OpenAI; GitHub enrichment can request PR data. The wrapper selects the
  local heuristic provider and mounts no agent settings or API credentials.
  Direct use of `git-history-ui` in an agent shell retains upstream's
  environment-based provider selection.
- The frontend's custom Markdown renderer escapes input before trusting its
  generated HTML. No runtime telemetry was found in the reviewed application
  paths. The Angular build configuration enables analytics upstream, so the
  installer explicitly disables it.
- The upstream install hook can rebuild SQLite, and the optional protocol
  launcher can fall back to `npx git-history-ui@latest`. Installation skips
  those lifecycle hooks; SQLite is compiled explicitly, and the wrapper
  directly executes the installed CLI.
- Upstream's production dependency audits reported 4 backend and 6 frontend
  affected packages. Our
  [`dependency patch`](../inside_deps/git-history-ui-dependencies.patch) pins
  body-parser 1.20.9, compression 1.8.2, proxy-addr 2.0.8, qs 6.16.1, and
  Angular 20.3.34, with their locked supporting dependencies and integrity
  hashes. This fixes, among others, the
  [proxy-addr IP spoofing issue](https://github.com/advisories/GHSA-jqcg-44mw-7w3h),
  [compression memory leak](https://github.com/advisories/GHSA-vc2v-76pw-4v95),
  and [Angular i18n XSS](https://github.com/advisories/GHSA-jj27-h5hq-8x99).
  Both production audits reported zero vulnerabilities after the patch.

## Updating git-history-ui: review, then pin

This pin is deliberately excluded from `build_image --update-agents` and the
other automatic update flags.

1. Clone upstream into a separate review directory. Select a release and
   resolve it with `git rev-parse 'vVERSION^{commit}'`. Record the full SHA,
   version, and review date; do not pin a mutable branch or tag.
2. Before running its scripts, review the diff from the current SHA,
   especially CLI/server authentication, Git arguments, filesystem writes,
   outbound requests, HTML rendering, build/install scripts, and both
   manifests and lockfiles. Check release notes and security advisories.
3. Reconcile our dependency patch against the candidate. Remove fixes already
   included upstream; review and lock any remaining dependency fixes. Do not
   run `npm update` or `npm audit fix` during image builds. Regenerate the patch
   from the reviewed checkout with `git diff --unified=0 -- package-lock.json
   frontend/package-lock.json`; zero context avoids trailing whitespace in
   the patch file. The installer applies it only after verifying the SHA.
4. Install both dependency trees with `npm ci --ignore-scripts`, explicitly
   build SQLite as the installer does, and run the following in the candidate
   checkout. Investigate failures before changing the pin:

   ```shell
   npm run lint
   npm run typecheck
   npm test -- --runInBand
   npm audit --omit=dev
   npm audit --prefix frontend --omit=dev
   NG_CLI_ANALYTICS=false npm run build
   npm run test:frontend
   ```

5. Update `versions/git-history-ui` and the dependency patch together. Prepend
   a new dated review above the existing reviews in this file, preserving older
   entries, and update the [review index](README.md). From the repository root,
   run `bash tools/test_git_story.sh` and ShellCheck on the wrapper and installer,
   then `./build_image`. Smoke-test the rebuilt image
   with `bin/git-story .`, `bin/git-story . wrapped --all-authors --json`, and
   `bin/git-story . pr-impact --base main --head main`. Confirm the frontend,
   authentication, SQLite index, and read-only repository mounts still work.
