const assert = require('node:assert/strict')
const { test } = require('node:test')
const Preferences = require('../Preferences.js')
const manifest = require('../manifest.json')

test('manifest and language validation agree with Omarchy widget settings', () => {
  assert.equal(manifest.id, 'foamy.monitor')
  assert.deepEqual(manifest.barWidget.defaults, { language: 'system' })
  const field = manifest.barWidget.schema.find(field => field.key === 'language')
  for (const value of field.options) assert.equal(Preferences.valid('language', value), true)
  for (const value of [null, true, {}, 'nb_NO', 'invalid']) assert.equal(Preferences.valid('language', value), false)
  assert.equal(Preferences.valid('scale', 1.25), false)
  assert.equal(Preferences.value({}, 'language'), 'system')
  assert.equal(Preferences.value({ language: 'invalid' }, 'language'), 'system')
})

test('system language recognizes Norwegian locales and explicit choice wins', () => {
  for (const locale of ['nb_NO', 'nn-NO', 'no', 'NB-no']) assert.equal(Preferences.language('system', locale), 'nb')
  for (const locale of ['en_US', 'fr_FR', '']) assert.equal(Preferences.language('system', locale), 'en')
  assert.equal(Preferences.language('en', 'nb_NO'), 'en')
  assert.equal(Preferences.language('nb', 'en_US'), 'nb')
})

test('translations preserve diagnostic detail and device names', () => {
  assert.equal(Preferences.text('Plugin settings', 'nb'), 'Plugininnstillinger')
  assert.equal(Preferences.text('Resolution', 'en'), 'Resolution')
  assert.equal(Preferences.text('Display Product 27', 'nb'), 'Display Product 27')
  assert.equal(Preferences.text('Please install fluxcast, ffmpeg', 'nb'), 'Installer fluxcast, ffmpeg')
  assert.equal(Preferences.text('Unsupported scale for DP-1', 'nb'), 'Skaleringen støttes ikke for DP-1')
})
