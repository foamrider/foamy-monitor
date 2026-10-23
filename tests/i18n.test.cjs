const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const I = require('./i18n.cjs');
const manifest = require('../manifest.json');
const tokens = s => [...s.matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
for (const [key, value] of Object.entries(I.en)) {
  assert.equal(value, key, `English source key: ${key}`);
  if (Object.hasOwn(I.no, key)) assert.deepEqual(tokens(I.no[key]), tokens(value), key);
}
assert.equal(manifest.barWidget?.defaults?.language, undefined);
assert.equal((manifest.barWidget?.schema || []).some(f => f.key === 'language'), false);
assert.equal(I.text('Unknown %1 {name}', 'no', ['$& %2']), '$& %2 {name}'.replace(/^/, 'Unknown '));
assert.equal(I.text('constructor', 'no'), 'constructor');
const ui = fs.readFileSync(path.join(__dirname, '../FoamyI18n.qml'), 'utf8');
assert.ok(ui.includes('Qt.createQmlObject'), '4.0 must not statically require a 4.5 QML type');

// Verify the same boundary used by helper errors in the panel.
const vm = require('node:vm');
const panel = fs.readFileSync(path.join(__dirname, '../Panel.qml'), 'utf8');
const wrapper = panel.slice(panel.indexOf('  function tr('), panel.indexOf('  function openSettings('));
for (const language of ['en', 'no']) {
  const context = vm.createContext({FoamyI18n: {t: (key, values) => I.text(key, language, values)}});
  vm.runInContext(wrapper, context);
  for (const prefix of ['Please install ', 'Could not read display settings: ', 'Unsupported scale for ', 'Unsupported resolution or refresh rate for ']) {
    const detail = 'Display $& %1 {name}';
    assert.equal(context.tr(prefix + detail), I.text(prefix + '%1', language, detail));
  }
  assert.equal(context.tr('Unknown error: Display %1'), 'Unknown error: Display %1');
}
