const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');
const I = require('./i18n.cjs');
const root = path.join(__dirname, '..');
const tokens = s => [...String(s).matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
const forms = v => (typeof v === 'object' ? Object.values(v) : [v]);
const source = file => fs.readFileSync(path.join(root, file), 'utf8');
const qmlFiles = fs.readdirSync(root).filter(f => f.endsWith('.qml'));
const view = source('MonitorView.qml');

// A "…" literal that is compared (x === "saving") is no text to translate.
const STRING = /"((?:[^"\\]|\\.)*)"/g;
function compared(text, match) {
  const before = text.slice(0, match.index);
  const after = text.slice(match.index + match[0].length);
  return /[=!]==\s*$/.test(before) || /^\s*[=!]==/.test(after);
}

// The first argument of the call whose "(" is at `open`: up to the first
// comma outside nested brackets, or the closing ")". Strings are skipped
// while counting, so a "," or ")" inside one does not end the argument.
function firstArgument(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === '\\') i++;
    } else if ('([{'.includes(c)) {
      depth++;
    } else if (')]}'.includes(c)) {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    } else if (c === ',' && depth === 1) {
      return text.slice(open + 1, i);
    }
  }
  throw new Error(`unclosed call at ${open}`);
}

test('catalog parity and placeholders', () => {
  for (const [key, value] of Object.entries(I.en)) {
    assert.equal(typeof value === 'object' ? value.other : value, key, `English source key: ${key}`);
    assert.ok(Object.hasOwn(I.no, key), `Norwegian entry: ${key}`);
    for (const form of forms(I.no[key])) assert.deepEqual(tokens(form), tokens(key), key);
    if (typeof value === 'object') {
      // A plural keeps its forms in Norwegian, and the singular its placeholders.
      assert.equal(typeof I.no[key], 'object', `Norwegian plural: ${key}`);
      for (const form of ['one', 'other']) assert.equal(typeof I.no[key][form], 'string', `${key}: ${form}`);
      assert.deepEqual(tokens(value.one), tokens(key), `${key}: one`);
    } else {
      // An empty entry would fall back to English without a failure.
      assert.notEqual(I.no[key], '', `Norwegian text: ${key}`);
    }
  }
  assert.deepEqual(Object.keys(I.no).sort(), Object.keys(I.en).sort());
});

test('every literal passed to tr, FoamyI18n.t or tn has an entry', () => {
  const used = new Set();
  for (const file of qmlFiles) {
    const text = source(file);
    for (const call of text.matchAll(/(?:FoamyI18n\.tn?|\btr)\(/g)) {
      const argument = firstArgument(text, call.index + call[0].length - 1);
      for (const match of argument.matchAll(STRING)) {
        if (compared(argument, match)) continue;
        used.add(match[1]);
        assert.ok(Object.hasOwn(I.en, match[1]), `${file}: missing catalog entry ${match[1]}`);
      }
    }
  }
  // Ternaries included (`tr(running ? "Stop" : "Scan")`): a scan that stops
  // matching would find far fewer.
  assert.ok(used.size >= 40, `found only ${used.size} translated literals`);
});

test('field labels and orientation names go through tr() as data', () => {
  for (const match of view.matchAll(/\blabel: "((?:[^"\\]|\\.)+)"/g))
    assert.ok(Object.hasOwn(I.en, match[1]), `MonitorView.qml: missing catalog entry ${match[1]}`);
});

test('messages the service and the model set for tr() have entries', () => {
  // Whole literals on a line that sets an error, fallbacks after || included;
  // the parts of "Cast ended (" + code + ")" form the template checked below.
  const messages = new Set([require('../kit/node-loader.cjs').load('FoamyNative').UNAVAILABLE_TEXT]);
  for (const file of ['MonitorService.qml', 'Model.js']) {
    for (const line of source(file).split('\n')) {
      if (!/\b(?:error|wirelessError)\s*=(?!=)|\berror:/.test(line)) continue;
      for (const match of line.matchAll(STRING)) {
        const joined = /\+\s*$/.test(line.slice(0, match.index)) || /^\s*\+/.test(line.slice(match.index + match[0].length));
        if (match[1] === '' || joined || compared(line, match)) continue;
        messages.add(match[1]);
      }
    }
  }
  for (const key of messages) assert.ok(Object.hasOwn(I.en, key), `missing catalog entry ${key}`);
  assert.ok(messages.size >= 7, `found only ${messages.size} messages`);
});

test('strings the kit components in this popup look up have entries', () => {
  for (const key of ['Settings', 'Back']) assert.ok(Object.hasOwn(I.en, key), key);
});

test('a key named like an Object member is no catalog entry', () => {
  assert.equal(I.text('constructor', 'no'), 'constructor');
});

test('helper errors: the known prefix is translated, never the detail', () => {
  // The real tr() of MonitorView.qml, run against the catalogs.
  const wrapper = view.slice(view.indexOf('  function tr('), view.indexOf('  function friendlyDisplayName('));
  for (const language of ['en', 'no']) {
    const context = vm.createContext({ FoamyI18n: { t: (key, values) => I.text(key, language, values) } });
    vm.runInContext(wrapper, context);
    for (const prefix of ['Please install ', 'Could not read display settings: ', 'Unsupported scale for ', 'Unsupported resolution or refresh rate for ']) {
      const detail = 'Display $& %1 {name}';
      assert.equal(context.tr(prefix + detail), I.text(prefix + '%1', language, detail));
    }
    assert.equal(context.tr('Unknown error: Display %1'), 'Unknown error: Display %1');
    // The service's cast exit and the scan parser's errors, as they arrive.
    assert.equal(context.tr('Cast ended (143)'), I.text('Cast ended (%1)', language, '143'));
    assert.equal(context.tr('Cast ended ()'), 'Cast ended ()');
    assert.equal(context.tr('Could not read the FluxCast scan'), I.text('Could not read the FluxCast scan', language));
  }
  // Without an entry both sides above fall back to English and still agree;
  // with one, the parity case guarantees the Norwegian text and placeholders.
  for (const key of ['Please install %1', 'Could not read display settings: %1', 'Unsupported scale for %1', 'Unsupported resolution or refresh rate for %1', 'Cast ended (%1)', 'Could not read the FluxCast scan'])
    assert.ok(Object.hasOwn(I.en, key), `missing catalog entry ${key}`);
});
