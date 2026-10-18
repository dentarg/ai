const { test } = require('node:test');
const { assertBrowserCheck } = require('./browser_check.cjs');

test('browser switches profile stats and restores all profiles', () => {
  assertBrowserCheck('PROFILE_TEST', `
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
  `);
});
