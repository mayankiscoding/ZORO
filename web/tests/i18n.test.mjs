// String completeness in both languages, the copy rules, and that every key the code asks for
// exists (a static scan of the source).

import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import en from '../js/i18n/en.js';
import hi from '../js/i18n/hi.js';
import { createI18n, fill, placeholders, preferredLanguage } from '../js/i18n/index.js';

const JS_ROOT = fileURLToPath(new URL('../js/', import.meta.url));

function sourceFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sourceFiles(path);
    return name.endsWith('.js') && !path.includes(`${join('js', 'i18n')}`) ? [path] : [];
  });
}

test('English and Hindi have exactly the same keys', () => {
  const enKeys = Object.keys(en).sort();
  const hiKeys = Object.keys(hi).sort();
  assert.deepEqual(hiKeys.filter((key) => !(key in en)), [], 'keys only in Hindi');
  assert.deepEqual(enKeys.filter((key) => !(key in hi)), [], 'keys missing in Hindi');
  assert.ok(enKeys.length > 300, `expected a full catalogue, found ${enKeys.length} keys`);
});

test('no string is empty and placeholders match between the languages', () => {
  for (const key of Object.keys(en)) {
    assert.equal(typeof en[key], 'string');
    assert.ok(en[key].trim().length > 0, `empty English string: ${key}`);
    assert.ok(hi[key].trim().length > 0, `empty Hindi string: ${key}`);
    assert.deepEqual(placeholders(hi[key]), placeholders(en[key]), `placeholders differ: ${key}`);
  }
});

test('every plural has both forms in both languages', () => {
  const bases = new Set(Object.keys(en).filter((key) => /_(one|other)$/.test(key)).map((key) => key.replace(/_(one|other)$/, '')));
  assert.ok(bases.size >= 5);
  for (const base of bases) {
    for (const catalogue of [en, hi]) {
      assert.ok(`${base}_one` in catalogue && `${base}_other` in catalogue, `plural pair incomplete: ${base}`);
      assert.ok(catalogue[`${base}_other`].includes('{count}'), `plural without a count: ${base}`);
    }
  }
});

test('copy rules: no exclamation marks, no arrows, no all-caps labels, sentence case', () => {
  const allowedCaps = new Set(['ZORO', 'HTTPS', 'MRP', 'ID', 'OK']);
  for (const [key, text] of [...Object.entries(en), ...Object.entries(hi)]) {
    assert.ok(!/[!！]/.test(text), `exclamation mark in ${key}`);
    assert.ok(!/[→←➜➔»›]|->/.test(text), `arrow in ${key}`);
    assert.ok(!/\b(sorry|oops|please)\b/i.test(text), `apology or filler in ${key}`);
  }
  for (const [key, text] of Object.entries(en)) {
    const words = text.replace(/\{\w+\}/g, '').match(/[A-Za-z]{2,}/g) || [];
    const shouting = words.filter((word) => word === word.toUpperCase() && !allowedCaps.has(word));
    assert.deepEqual(shouting, [], `all-caps word in ${key}`);
    // Sentence case: no Title Case Labels (a second capitalised common word after the first).
    if (!/[.:]/.test(text) && words.length >= 2 && words.length <= 4) {
      const proper = /^(ZORO|Face|Touch|ID|Safari|WhatsApp|Mac|iPhone|Health|HomeKit|Shortcuts|Siri|Tailscale|English|Hindi|Hinglish|India|Finance|Shopping|Investments|Fitness|Photos|Music|Memory|Action|Button|Lock|Screen|Apple|Google|MRP|Security|Settings)$/;
      const titleCased = words.slice(1).filter((word) => /^[A-Z][a-z]/.test(word) && !proper.test(word));
      assert.deepEqual(titleCased, [], `title case in ${key}: "${text}"`);
    }
  }
});

test('Hindi uses Western digits, the formal address, and keeps names in Latin script', () => {
  for (const [key, text] of Object.entries(hi)) {
    assert.ok(!/[०-९]/.test(text), `Devanagari digit in ${key}`);
    assert.ok(!/(^|\s)(तुम|तू|तुम्हारा|तेरा)(\s|$)/.test(text), `informal address in ${key}`);
    if (en[key].includes('ZORO')) assert.ok(text.includes('ZORO'), `ZORO not kept in Latin script: ${key}`);
    if (en[key].includes('Face ID')) assert.ok(text.includes('Face ID'), `Face ID not kept: ${key}`);
    if (en[key].includes('WhatsApp')) assert.ok(text.includes('WhatsApp'), `WhatsApp not kept: ${key}`);
  }
  const translated = Object.keys(hi).filter((key) => /[ऀ-ॿ]/.test(hi[key])).length;
  assert.ok(translated / Object.keys(hi).length > 0.9, 'most Hindi strings should be in Devanagari');
});

test('the reference strings of voice-and-copy.md are used as written', () => {
  assert.equal(en['orb.idle'], 'Ready. Tap to talk.');
  assert.equal(hi['orb.idle'], 'तैयार। बात करने के लिए टैप करें।');
  assert.equal(en['orb.private'], 'Private mode. Nothing leaves your server.');
  assert.equal(hi['orb.listening'], 'आपकी बात सुनी जा रही है');
  assert.equal(en['privacy.strict.line'], 'Nothing leaves your ZORO server.');
  assert.equal(hi['privacy.cloud.line'], 'सिर्फ़ वही बाहर भेजा जाता है जिसकी आपने अनुमति दी है, निजी जानकारी हटाकर।');
  assert.equal(en['agent.status.needs_owner'], 'Needs your approval');
  assert.equal(hi['agent.status.failed'], 'पूरा नहीं हो सका');
  assert.equal(en['approval.approve'], 'Approve');
  assert.equal(hi['approval.decline'], 'मना करें');
  assert.equal(en['approval.expired'], 'Expired. Ask again to approve.');
  assert.equal(en['state.disconnected'], "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale.");
  assert.equal(hi['memory.empty'], 'ZORO ने अभी आपके बारे में कुछ सेव नहीं किया है।');
  assert.equal(en['card.stale'], 'Price may have changed.');
});

test('one name per action: the button and its confirmation share the verb', () => {
  assert.ok(en['approval.approved'].startsWith('Approved'));
  assert.ok(en['approval.declined'].startsWith('Declined'));
  assert.ok(en['memory.deleted'].startsWith('Deleted'));
  assert.ok(en['memory.kept'].startsWith('Kept'));
  assert.ok(en['settings.forget.done'].includes('forgotten'));
});

test('every key the code asks for exists', () => {
  const files = sourceFiles(JS_ROOT);
  assert.ok(files.length >= 10, 'expected to scan the app source');
  const literal = /\bt(?:\.plural)?\(\s*'([a-z0-9_.]+)'/g;
  const pluralCall = /\bt\.plural\(\s*'([a-z0-9_.]+)'/g;
  const keyProp = /\b(?:key|titleKey|labelKey|lineKey|noteKey|messageKey|textKey)\s*:\s*'([a-z0-9_.]+)'/g;
  const missing = [];
  let checked = 0;
  for (const file of files) {
    const source = readFileSync(file, 'utf8');
    const plurals = new Set([...source.matchAll(pluralCall)].map((match) => match[1]));
    for (const match of [...source.matchAll(literal), ...source.matchAll(keyProp)]) {
      const key = match[1];
      if (!key.includes('.')) continue;
      checked += 1;
      if (plurals.has(key)) {
        if (!(`${key}_one` in en) || !(`${key}_other` in en)) missing.push(`${key} (plural) in ${file}`);
      } else if (!(key in en)) {
        missing.push(`${key} in ${file}`);
      }
    }
  }
  assert.deepEqual(missing, []);
  assert.ok(checked > 150, `expected many string uses, found ${checked}`);
});

test('every catalogue key is used somewhere in the code (no dead strings)', () => {
  const source = sourceFiles(JS_ROOT).map((file) => readFileSync(file, 'utf8')).join('\n');
  // Keys built from a value, such as t(`privacy.${key}.title`), become patterns.
  const patterns = [...source.matchAll(/`([a-z0-9_.]*\$\{[^`]*)`/g)]
    .map((match) => match[1])
    .filter((template) => /^[a-z0-9_.]+\.\$\{|\}\.[a-z0-9_.]+$/.test(template))
    .map((template) => new RegExp(`^${template.split(/\$\{[^}]*\}/).map((part) => part.replace(/\./g, '\\.')).join('[a-z0-9_]+')}$`));
  assert.ok(patterns.length >= 8, 'expected several built keys');
  const unused = Object.keys(en).filter((key) => {
    const base = key.replace(/_(one|other)$/, '');
    if (source.includes(`'${key}'`) || source.includes(`'${base}'`)) return false;
    return !patterns.some((pattern) => pattern.test(key));
  });
  assert.deepEqual(unused, []);
});

test('t fills placeholders, picks plurals, falls back and switches language', () => {
  const t = createI18n('en');
  assert.equal(t('orb.delegating', { agents: 'Shopping and Finance' }), 'Working with Shopping and Finance');
  assert.equal(t.plural('card.basket.items', 1), '1 item');
  assert.equal(t.plural('card.basket.items', 3), '3 items');
  assert.equal(t('no.such.key'), 'no.such.key');
  assert.equal(fill('{a} and {b}', { a: 1 }), '1 and {b}');
  const seen = [];
  t.onChange((lang) => seen.push(lang));
  t.setLang('hi');
  assert.equal(t.lang, 'hi');
  assert.equal(t('orb.delegating', { agents: 'Shopping और Finance' }), 'Shopping और Finance के साथ काम जारी है');
  assert.equal(t.plural('card.compare.missing', 3), '3 चीज़ें नहीं हैं');
  t.setLang('xx');
  assert.equal(t.lang, 'hi');
  assert.deepEqual(seen, ['hi']);
  assert.equal(createI18n('fr').lang, 'en');
});

test('the starting language follows the browser: Hindi only when it is asked for first', () => {
  assert.equal(preferredLanguage(['hi-IN', 'en-IN']), 'hi');
  assert.equal(preferredLanguage(['en-IN', 'hi-IN']), 'en');
  assert.equal(preferredLanguage(['fr-FR']), 'en');
  assert.equal(preferredLanguage([]), 'en');
});
