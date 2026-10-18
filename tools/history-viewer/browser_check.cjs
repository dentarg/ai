// Runs `script` inside viewer.html in headless Chromium. The script reports
// by replacing the body text with `<name>_PASSED` or `<name>_FAILED: why`.
const assert = require('node:assert/strict');
const { mkdtempSync, readFileSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { spawnSync } = require('node:child_process');

function assertBrowserCheck(name, script) {
  const dir = mkdtempSync(join(tmpdir(), 'history-viewer-'));
  try {
    const html = readFileSync(`${__dirname}/viewer.html`, 'utf8');
    const page = html.replace('bootstrap().catch', 'new Promise(() => {}).catch');
    const end = page.lastIndexOf('</body>');
    const path = join(dir, 'test.html');
    writeFileSync(path, page.slice(0, end) + `<script>${script}</script>` + page.slice(end));
    const result = spawnSync('chromium', ['--headless', '--no-sandbox', '--disable-gpu',
      `--user-data-dir=${join(dir, 'browser')}`, '--window-size=1200,900',
      '--virtual-time-budget=5000', '--dump-dom', `file://${path}`],
    { encoding: 'utf8', timeout: 30000 });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.includes(`<body>${name}_PASSED`),
      result.stdout.match(new RegExp(`${name}_FAILED[^<]*`))?.[0] || 'Browser check did not finish');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { assertBrowserCheck };
