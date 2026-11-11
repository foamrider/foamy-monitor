// Exercise the kit's real substitution and lookup (kit/FoamyI18nText.js, which
// FoamyI18n.qml substitutes through) with catalog data in pure tests.
const I18n = require('../kit/node-loader.cjs').load('FoamyI18nText');
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
const translators = { en: I18n.translator(en, en), no: I18n.translator(no, en) };
function text(key, language, values) {
  return translators[language === 'no' || language === 'nb' ? 'no' : 'en'].t(key, values);
}
module.exports = { text, no, en, norwegian: no, nb: no };
