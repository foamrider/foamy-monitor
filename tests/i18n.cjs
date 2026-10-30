// Exercise the kit's real substitution function with catalog data in pure tests.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../kit/FoamyI18n.qml'), 'utf8');
const start = source.indexOf('  function substitute(');
const end = source.indexOf('\n  function t(', start);
const scope = vm.createContext({ root: { number: value => String(value) } });
vm.runInContext(source.slice(start, end), scope);
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
function text(key, language, values) {
  const catalog = language === 'no' || language === 'nb' ? no : en;
  const value = Object.hasOwn(catalog, key) ? catalog[key] : key;
  return scope.substitute(typeof value === 'object' ? value.other : value, values);
}
module.exports = { text, no, en, norwegian: no, nb: no, source };
