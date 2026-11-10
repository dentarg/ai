# Host browser

[README](../README.md)

`--host-browser` launches Google Chrome Canary on macOS with a dedicated
profile and makes its Chrome DevTools Protocol endpoint available inside either
the Podman container or Lima VM. Canary and the proxy stop when the session
exits. The profile remains under `$HOME/ai/host-browser/profile`, preserving
browser state such as cookies, logins, and extensions across sessions and host
reboots. Only one host-browser session may use the profile at a time.

On every launch, translation offers and password-saving prompts are disabled
for both new and existing profiles. Other preferences and saved browser state
are preserved.

Use a named profile to run isolated browser identities concurrently. Named
profiles remain under `$HOME/ai/host-browser/profiles/<name>`:

```shell
bin/ai c --host-browser=work
bin/ai c --host-browser=personal
```

The host-facing Chrome debugging socket remains on loopback. A TLS proxy
accepts guest connections using a random bearer token, rewrites the advertised
WebSocket endpoint, and strips the token before forwarding traffic to Chrome.
Its per-session certificate is valid for one year so long-running sessions do
not lose access.
The guest receives `HOST_BROWSER_URL`, `HOST_BROWSER_TOKEN`,
`HOST_BROWSER_CA`, and `NODE_EXTRA_CA_CERTS`. The token is passed to Lima
through a temporary file rather than a process argument.

Connect with the preinstalled `puppeteer-core` package:

```javascript
const puppeteer = require("puppeteer-core");
const authorization = `Bearer ${process.env.HOST_BROWSER_TOKEN}`;
const browser = await puppeteer.connect({
  browserURL: process.env.HOST_BROWSER_URL,
  wsOptions: {headers: {Authorization: authorization}},
});

const page = await browser.newPage({background: true});
await page.goto("https://example.com");
await browser.disconnect();
```

Run the script with the globally installed package on Node's module path:

```shell
NODE_PATH="$(npm root -g)" node browser-script.cjs
```

Canary starts without an initial window so launching it does not activate the
application. Always create pages with `{background: true}` and do not call
`page.bringToFront()`; foreground targets can cause macOS to switch focus to
Canary. Select Canary yourself when you want to inspect its windows.

Chrome Canary must be installed at its normal application path. Override it
with `AI_CHROME_CANARY_PATH` when necessary. Set `AI_HOST_BROWSER=1` instead
of passing the flag to enable the same behavior. Set
`AI_HOST_BROWSER_PROFILE=<name>` to select a named profile through the
environment.

The isolated profile supports extension development. Load an unpacked
extension in Canary, then use Puppeteer to inspect its extension pages,
content-script pages, and Manifest V3 service-worker targets. Manually loaded
extensions persist in the dedicated profile between sessions.

Applications running in the guest still need `--ports` so the host browser can
reach them. For example, `bin/ai c --host-browser --ports 3000` exposes a guest
server on `http://127.0.0.1:3000` to Canary.
