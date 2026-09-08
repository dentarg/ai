const assert = require('node:assert/strict');
const { mkdtempSync, readFileSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

test('browser switches profile stats and restores all profiles', () => {
  const dir = mkdtempSync(join(tmpdir(), 'history-profiles-'));
  try {
    const html = readFileSync(`${__dirname}/viewer.html`, 'utf8');
    const check = `<script>
      try {
        state.sessions = ['work', 'personal', '', 'a"<&'].map((profile, i) => ({
          tool: 'codex', profile, repo: 'repo-' + i, models: ['model-' + i],
          startedAt: new Date().toISOString(), tokens: {input_tokens: 100},
          tokensByModel: {['model-' + i]: {input_tokens: 100}}, cost: i + 1
        }));
        renderStatsPage();
        const verify = (condition) => { if (!condition) throw Error('Incorrect profile stats'); };
        for (const [i, profile] of ['work', 'personal', '', 'a"<&'].entries()) {
          const select = document.getElementById('stats-profile');
          select.selectedIndex = [...select.options].findIndex(option =>
            option.textContent === (profile || 'Default / unspecified'));
          select.dispatchEvent(new Event('change'));
          verify(state.statsProfile === profile);
          verify(document.querySelector('.stats-totals').textContent.includes('1 sessions'));
          verify(document.querySelector('.stats-table').textContent.includes('100'));
          verify(document.querySelector('.stats-chart').textContent.includes('model-' + i));
        }
        const select = document.getElementById('stats-profile');
        select.selectedIndex = 0;
        select.dispatchEvent(new Event('change'));
        verify(state.statsProfile === null);
        verify(document.querySelector('.stats-totals').textContent.includes('4 sessions'));
        document.body.textContent = 'PROFILE_TEST_PASSED';
      } catch (error) { document.body.textContent = 'PROFILE_TEST_FAILED: ' + error.message; }
    </script>`;
    const path = join(dir, 'test.html');
    const page = html.replace('bootstrap().catch', 'new Promise(() => {}).catch');
    const end = page.lastIndexOf('</body>');
    writeFileSync(path, page.slice(0, end) + check + page.slice(end));
    const result = spawnSync('chromium', ['--headless', '--no-sandbox', '--disable-gpu',
      `--user-data-dir=${join(dir, 'browser')}`, '--dump-dom', `file://${path}`],
    { encoding: 'utf8', timeout: 30000 });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.includes('<body>PROFILE_TEST_PASSED'),
      result.stdout.match(/PROFILE_TEST_FAILED[^<]*/)?.[0] || 'Browser check did not finish');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
