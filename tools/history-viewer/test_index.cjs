const { test } = require('node:test');
const { assertBrowserCheck } = require('./browser_check.cjs');

test('index renders lazily and j/k selection loads cards on demand', () => {
  assertBrowserCheck('INDEX_TEST', `
    try {
      const verify = (condition, why) => { if (!condition) throw Error(why); };
      const key = (k) => document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true }));
      const now = Date.now();
      state.sessions = Array.from({ length: 1000 }, (_, i) => ({
        path: 'run/projects/p/' + i + '.jsonl', tool: 'claude', name: 'Session ' + i,
        endedAt: new Date(now - i * 3600e3).toISOString(), messages: 1, tokens: {}, cost: 0,
      }));
      const help = document.getElementById('kbd-help');
      verify(getComputedStyle(help).display === 'none', 'hidden help overlay must not cover the page');
      renderIndexPage();
      const cards = () => document.querySelectorAll('.session-card').length;
      verify(cards() >= 100 && cards() < 200, 'first page rendered ' + cards() + ' cards');

      key('j');
      verify(state.selectedPath === state.sessions[0].path, 'j selects the first session');
      for (let i = 0; i < 400; i++) key('j');
      key('k');
      const selected = document.querySelector('.session-card.selected');
      verify(state.selectedPath === state.sessions[399].path, 'selection is ' + state.selectedPath);
      verify(selected?.textContent.includes('Session 399'), 'selected card rendered');
      verify(cards() < 1000, 'list stayed lazy');

      // Returning to the index keeps the selection in view.
      renderIndexPage();
      verify(document.querySelector('.session-card.selected')?.textContent.includes('Session 399'),
        'selection restored');

      const oldest = [...document.querySelectorAll('#month-jump-list a[data-day]')].at(-1);
      oldest.click();
      verify(document.getElementById('day-' + oldest.dataset.day), 'jump renders the target day');

      key('/');
      verify(document.activeElement.id === 'f-search', '/ focuses search');
      key('?');
      verify(document.getElementById('kbd-help').hidden, 'typing in search ignores shortcuts');
      document.activeElement.blur();
      key('?');
      verify(!document.getElementById('kbd-help').hidden, '? opens help');
      key('Escape');
      verify(document.getElementById('kbd-help').hidden, 'Escape closes help');
      document.body.textContent = 'INDEX_TEST_PASSED';
    } catch (error) { document.body.textContent = 'INDEX_TEST_FAILED: ' + error.message; }
  `);
});
