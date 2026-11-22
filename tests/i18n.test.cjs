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

// Refusals of the helper that MonitorView shows through tr(): the display
// error line, the GTK scale line and the cast error. Each row is the message
// as the helper sends it, and for a template its catalog key and detail.
const HELPER_MESSAGES = [
  ['GTK scale must be 1, 2, 3, or 4'],
  ['GTK scale must be a standalone hl.env call in monitors.lua'],
  ['GTK scale must be a whole-number string or tostring of a local whole number in monitors.lua'],
  ['GTK scale must use a standalone local whole number without reassignments or other uses in monitors.lua'],
  ['GTK scale requires the unmodified tostring function in monitors.lua'],
  ['Remove duplicate GDK_SCALE settings from monitors.lua'],
  ['Conditional monitor configuration must be edited in monitors.lua'],
  ['Use literal hl.monitor({...}) rules in monitors.lua before saving'],
  ['Monitor rules must be standalone calls in monitors.lua'],
  ['Monitor output must be a literal string in monitors.lua'],
  ['Duplicate monitor field; simplify monitors.lua before saving'],
  ['Cannot update this monitor rule in monitors.lua'],
  ['A monitor description matches multiple displays; use a unique description'],
  ['Duplicate rules for DP-1; remove the duplicate before saving', 'Duplicate rules for %1; remove the duplicate before saving', 'DP-1'],
  ['Invalid wireless display address'],
  ["Could not start FluxCast: [Errno 13] Permission denied: 'fluxcast'", 'Could not start FluxCast: %1', "[Errno 13] Permission denied: 'fluxcast'"],
  ['FluxCast failed'],
  ['FluxCast ended before casting started'],
  ['FluxCast exited with code 5', 'FluxCast exited with code %1', '5'],
];

test('helper refusals the user sees are shown in Norwegian', () => {
  const wrapper = view.slice(view.indexOf('  function tr('), view.indexOf('  function friendlyDisplayName('));
  const context = vm.createContext({ FoamyI18n: { t: (key, values) => I.text(key, 'no', values) } });
  vm.runInContext(wrapper, context);
  // The helper's source holds each text (a template with its {…} detail), so
  // a message renamed there fails here rather than showing in English.
  const helper = fs.readdirSync(path.join(root, 'native/src')).map(f => source(`native/src/${f}`)).join('\n');
  const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  for (const [message, key = message, detail] of HELPER_MESSAGES) {
    const [head, tail = ''] = key.split('%1');
    const literal = detail === undefined ? escape(JSON.stringify(key)) : `"${escape(head)}\\{\\w*\\}${escape(tail)}"`;
    assert.match(helper, new RegExp(literal), `the helper no longer sends ${key}`);
    assert.notEqual(context.tr(message), message, `shown in English: ${message}`);
    assert.equal(context.tr(message), I.text(key, 'no', detail), message);
  }
});

test('a cast error shows translated while the cast is still running', () => {
  // The real wirelessPhaseLabel() and tr(), with the service in the error phase.
  const functions = view.slice(view.indexOf('  function tr('), view.indexOf('  readonly property var rotationOptions'));
  const service = { castPhase: 'error', castDetail: '', castTargetName: 'Living Room TV' };
  const context = vm.createContext({ MonitorService: service, FoamyI18n: { t: (key, values) => I.text(key, 'no', values) } });
  vm.runInContext(functions, context);
  for (const [detail, key = detail, value] of [['FluxCast failed'], ['Please install fluxcast-git', 'Please install %1', 'fluxcast-git'], ['FluxCast exited with code 5', 'FluxCast exited with code %1', '5']]) {
    service.castDetail = detail;
    assert.equal(context.wirelessPhaseLabel(), I.text(key, 'no', value), detail);
    assert.notEqual(context.wirelessPhaseLabel(), detail, `shown in English: ${detail}`);
  }
  // FluxCast's own words after "ERROR:" have no entry and stay as they are.
  service.castDetail = 'receiver rejected the session';
  assert.equal(context.wirelessPhaseLabel(), 'receiver rejected the session');
});
