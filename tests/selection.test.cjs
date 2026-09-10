const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

// Exercise the widget's actual selection code with transient collector data.
const qml = fs.readFileSync(path.join(__dirname, '..', 'Widget.qml'), 'utf8');
function functionSource(name) {
  const start = qml.indexOf(`  function ${name}(`);
  const end = qml.indexOf('\n  }', start) + 4;
  assert.ok(start >= 0 && end > start);
  return qml.slice(start, end);
}
function widget(selection) {
  const context = vm.createContext({
    effectiveSettings: selection === undefined ? {} : { tracked: selection },
    trackedSettings: selection ?? ['claude:session-5-hour', 'grok:weekly'],
    trackedItems: [],
    limitsData: { allLimits: [] },
  });
  context.root = context;
  vm.runInContext(functionSource('toList') + '\n' + functionSource('updateTrackedItems'), context);
  return {
    refresh(ids) {
      context.limitsData = { allLimits: ids.map(id => ({ id })) };
      context.updateTrackedItems();
      return Array.from(context.trackedItems, item => item.id);
    },
  };
}

test('selected limits survive missing data and return in selected order', () => {
  const selected = ['codex:weekly-7-day', 'claude:fable-weekly'];
  const w = widget(selected);
  assert.deepEqual(w.refresh([...selected].reverse()), selected);
  assert.deepEqual(w.refresh(['claude:session-5-hour', 'grok:weekly']), []);
  assert.deepEqual(w.refresh([]), []);
  assert.deepEqual(w.refresh([selected[1], 'grok:weekly']), [selected[1]]);
  assert.deepEqual(w.refresh([...selected].reverse()), selected);
});

test('an explicitly empty selection stays empty', () => {
  assert.deepEqual(widget([]).refresh(['claude:session-5-hour', 'grok:weekly']), []);
});

test('first-run automatic selection still works', () => {
  assert.deepEqual(widget().refresh(['codex:weekly-7-day']), ['codex:weekly-7-day']);
});

test('a saved selection never displays more than two limits', () => {
  assert.deepEqual(widget(['a', 'b', 'c']).refresh(['c', 'b', 'a']), ['a', 'b']);
});
