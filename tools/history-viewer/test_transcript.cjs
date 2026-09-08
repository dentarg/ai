const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const vm = require('node:vm');

const html = readFileSync(`${__dirname}/viewer.html`, 'utf8');
const start = html.indexOf('<script>', html.indexOf('</head>')) + '<script>'.length;
const content = { innerHTML: '', querySelectorAll: () => [], querySelector: () => null };
const profileSelect = { addEventListener(type, handler) { this.change = handler; } };
const context = vm.createContext({
  document: {
    getElementById: id => ({ content, 'stats-profile': profileSelect })[id] || null,
    body: { addEventListener() {} },
  },
  window: { addEventListener() {} },
  fetch: () => new Promise(() => {}),
});
vm.runInContext(html.slice(start, html.lastIndexOf('</script>')), context);

test('profile selection scopes stats and chart and can restore combined stats', () => {
  context.sessions = ['work', 'personal', ''].map((profile, i) => ({
    tool: 'codex', profile, repo: `repo-${i}`, models: [`model-${i}`],
    startedAt: new Date().toISOString(), tokens: { input_tokens: 100 }, cost: i + 1,
    tokensByModel: { [`model-${i}`]: { input_tokens: 100 } },
    costByModel: { [`model-${i}`]: i + 1 },
  }));
  vm.runInContext('state.sessions = sessions; renderStatsPage()', context);
  assert.match(content.innerHTML, /<b>3<\/b> sessions/);
  assert.match(content.innerHTML, /All profiles/);
  for (const profile of ['work', 'personal', '']) {
    profileSelect.change({ target: { value: String(["", "personal", "work"].indexOf(profile)) } });
    assert.match(content.innerHTML, /<b>1<\/b> sessions/);
    const index = ['work', 'personal', ''].indexOf(profile);
    for (let i = 0; i < 3; i++) {
      assert.equal(content.innerHTML.includes(`repo-${i}`), i === index);
      assert.equal(content.innerHTML.includes(`model-${i}`), i === index);
    }
    vm.runInContext('state.statsRange = "7d"', context);
    const chart = vm.runInContext('renderTokenChartBlock().html', context);
    assert.ok(chart.includes(`model-${index}`));
    assert.ok(!chart.includes(`model-${(index + 1) % 3}`));
  }
  profileSelect.change({ target: { value: '' } });
  assert.match(content.innerHTML, /<b>3<\/b> sessions/);
  vm.runInContext('state.sessions = []; state.statsRange = "all"', context);
});

test('default transcript shows prompts and answers; toggles restore steps and internals', () => {
  const event = (type, content, uuid) => ({ type, message: { content }, uuid });
  const text = (text, channel) => ({ type: 'text', text, channel });
  context.events = [
    event('user', 'First prompt', 'prompt-1'),
    event('assistant', [text('Progress update'), { type: 'tool_use', name: 'shell' }]),
    event('user', [{ type: 'tool_result', content: 'Tool output' }]),
    event('assistant', [{ type: 'thinking', thinking: 'Private reasoning' }, text('First answer')], 'answer-1'),
    event('user', [text('Second prompt')], 'prompt-2'),
    event('assistant', [text('Earlier progress')]),
    event('assistant', [text('More progress', 'commentary'), text('Second answer', 'final')], 'answer-2'),
    { type: 'system' },
  ];
  const render = () => vm.runInContext('transcriptHtml(events)', context);
  const compact = render();
  for (const expected of ['First prompt', 'First answer', 'Second prompt', 'Second answer', 'evt-answer-1', 'evt-answer-2']) {
    assert.ok(compact.includes(expected), expected);
  }
  for (const hidden of ['Progress update', 'Tool output', 'Private reasoning', 'Earlier progress', 'More progress', 'internal-block', 'assistant-aux']) {
    assert.ok(!compact.includes(hidden), hidden);
  }
  vm.runInContext('state.showIntermediateSteps = true', context);
  const expanded = render();
  for (const expected of ['Progress update', 'Tool output', 'Private reasoning', 'Earlier progress', 'More progress']) {
    assert.ok(expanded.includes(expected), expected);
  }
  assert.ok(!expanded.includes('internal-block'));
  vm.runInContext('state.showInternals = true', context);
  assert.ok(render().includes('internal-block'));
  vm.runInContext('state.showIntermediateSteps = false; state.showInternals = false', context);
  assert.equal(render(), compact);
});
