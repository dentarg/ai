const { test } = require('node:test');
const { assertBrowserCheck } = require('./browser_check.cjs');

test('index renders lazily and jumps to days not yet rendered', () => {
  assertBrowserCheck('INDEX_TEST', `
    try {
      const verify = (condition, why) => { if (!condition) throw Error(why); };
      const now = Date.now();
      state.sessions = Array.from({ length: 1000 }, (_, i) => ({
        path: 'run/projects/p/' + i + '.jsonl', tool: 'claude', name: 'Session ' + i,
        endedAt: new Date(now - i * 3600e3).toISOString(), messages: 1, tokens: {}, cost: 0,
      }));
      renderIndexPage();
      const cards = () => document.querySelectorAll('.session-card').length;
      verify(cards() >= 100 && cards() < 200, 'first page rendered ' + cards() + ' cards');

      const oldest = [...document.querySelectorAll('#month-jump-list a[data-day]')].at(-1);
      oldest.click();
      verify(document.getElementById('day-' + oldest.dataset.day), 'jump renders the target day');
      document.body.textContent = 'INDEX_TEST_PASSED';
    } catch (error) { document.body.textContent = 'INDEX_TEST_FAILED: ' + error.message; }
  `);
});
