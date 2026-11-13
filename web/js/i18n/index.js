// Interface strings in English and Hindi. `t('key', {name})` fills `{name}` placeholders;
// `t.plural('key', count)` picks `key_one` or `key_other`. Text is always inserted as text
// nodes, never as markup.

import en from './en.js';
import hi from './hi.js';

export const LANGUAGES = Object.freeze({ en, hi });
export const LANGUAGE_NAMES = Object.freeze({ en: 'English', hi: 'हिन्दी' });

/** @param {string} template @param {Record<string, string | number>} [params] */
export function fill(template, params) {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name) => (name in params ? String(params[name]) : whole));
}

/** Placeholder names in a template, sorted. @param {string} template */
export function placeholders(template) {
  return [...template.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();
}

/** @param {string} [initial] 'en' | 'hi' */
export function createI18n(initial = 'en') {
  let lang = initial in LANGUAGES ? initial : 'en';
  const listeners = new Set();

  /** @param {string} key @param {Record<string, string | number>} [params] */
  function t(key, params) {
    const template = LANGUAGES[lang][key] ?? LANGUAGES.en[key];
    return template === undefined ? key : fill(template, params);
  }

  /** @param {string} key base key; `_one` / `_other` are looked up @param {number} count */
  t.plural = (key, count, params = {}) => t(`${key}_${count === 1 ? 'one' : 'other'}`, { count, ...params });

  t.has = (key) => key in LANGUAGES.en;

  Object.defineProperty(t, 'lang', { get: () => lang });

  t.setLang = (next) => {
    if (!(next in LANGUAGES) || next === lang) return;
    lang = next;
    for (const listener of listeners) listener(lang);
  };

  t.onChange = (listener) => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  };

  return t;
}

/** The interface language to start with when none was chosen: Hindi if the browser asks for it.
 * @param {readonly string[]} [preferred] */
export function preferredLanguage(preferred = globalThis.navigator?.languages ?? []) {
  for (const tag of preferred) {
    const base = String(tag).toLowerCase().split('-')[0];
    if (base === 'hi') return 'hi';
    if (base === 'en') return 'en';
  }
  return 'en';
}
