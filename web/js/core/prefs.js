// Interface preferences. These are not sensitive (language, voice, motion), so they may live in
// localStorage. Nothing else goes there: keys, tokens, device ids and conversation text are kept
// in IndexedDB (keys as non-extractable CryptoKey objects, text sealed with AES-GCM).

const STORAGE_KEY = 'zoro.prefs.v1';

export const DEFAULT_PREFS = Object.freeze({
  /** Interface language: 'en' | 'hi'. */
  lang: 'en',
  /** Hint sent with each turn: 'auto' | 'en' | 'hi' | 'hinglish'. */
  replyLanguage: 'auto',
  /** Speak ZORO's replies: 'voice' (only when the owner spoke), 'always' or 'never'. */
  speakReplies: 'voice',
  /** Language the browser's speech recognition listens for: 'en-IN' | 'hi-IN'. */
  listenLang: 'en-IN',
  /** The owner agreed to use the browser's speech recognition service (asked on first use). */
  speechConsent: false,
  /** Chosen voice per language (a `voiceURI`), or null for the browser's default. */
  voiceEn: null,
  voiceHi: null,
  /** Speech rate, 0.7 to 1.3. */
  rate: 1,
  /** 'system' follows the device setting; 'on' always reduces; 'off' never does. */
  reduceMotion: 'system',
  /** 'brief' | 'balanced' | 'detailed' for typed turns (voice turns default to brief). */
  responseLength: 'balanced',
  /** Ask for strict private mode on every turn from this browser (stricter is always allowed). */
  alwaysPrivate: false,
  /** First-run language and voice step was shown. */
  introduced: false,
});

const VALID = {
  lang: (v) => v === 'en' || v === 'hi',
  replyLanguage: (v) => ['auto', 'en', 'hi', 'hinglish'].includes(v),
  speakReplies: (v) => ['voice', 'always', 'never'].includes(v),
  listenLang: (v) => v === 'en-IN' || v === 'hi-IN',
  speechConsent: (v) => typeof v === 'boolean',
  voiceEn: (v) => v === null || (typeof v === 'string' && v.length <= 300),
  voiceHi: (v) => v === null || (typeof v === 'string' && v.length <= 300),
  rate: (v) => typeof v === 'number' && v >= 0.7 && v <= 1.3,
  reduceMotion: (v) => ['system', 'on', 'off'].includes(v),
  responseLength: (v) => ['brief', 'balanced', 'detailed'].includes(v),
  alwaysPrivate: (v) => typeof v === 'boolean',
  introduced: (v) => typeof v === 'boolean',
};

/** Keep only known keys with valid values; everything else falls back to the default.
 * @param {unknown} raw */
export function sanitizePrefs(raw) {
  const out = { ...DEFAULT_PREFS };
  if (raw && typeof raw === 'object') {
    for (const key of Object.keys(DEFAULT_PREFS)) {
      if (key in raw && VALID[key](raw[key])) out[key] = raw[key];
    }
  }
  return out;
}

function safeStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null; // storage blocked (private browsing in some browsers)
  }
}

export class Prefs {
  /** @param {{storage?: Storage | null}} [options] */
  constructor({ storage = safeStorage() } = {}) {
    this._storage = storage;
    this._listeners = new Set();
    this._value = this._read();
  }

  _read() {
    try {
      const text = this._storage?.getItem(STORAGE_KEY);
      return sanitizePrefs(text ? JSON.parse(text) : null);
    } catch {
      return { ...DEFAULT_PREFS };
    }
  }

  get all() {
    return { ...this._value };
  }

  /** @param {keyof typeof DEFAULT_PREFS} key */
  get(key) {
    return this._value[key];
  }

  /** @param {Partial<typeof DEFAULT_PREFS>} patch */
  set(patch) {
    const next = sanitizePrefs({ ...this._value, ...patch });
    const changed = Object.keys(next).filter((key) => next[key] !== this._value[key]);
    if (changed.length === 0) return;
    this._value = next;
    try {
      this._storage?.setItem(STORAGE_KEY, JSON.stringify(next));
    } catch {
      /* storage full or blocked: the choice still holds for this visit */
    }
    for (const listener of this._listeners) listener(this.all, changed);
  }

  /** @param {(prefs: typeof DEFAULT_PREFS, changed: string[]) => void} listener */
  subscribe(listener) {
    this._listeners.add(listener);
    return () => this._listeners.delete(listener);
  }

  /** Forget the preferences (used with "Forget this pairing"). */
  reset() {
    this._value = { ...DEFAULT_PREFS };
    try {
      this._storage?.removeItem(STORAGE_KEY);
    } catch {
      /* nothing to remove */
    }
    for (const listener of this._listeners) listener(this.all, Object.keys(DEFAULT_PREFS));
  }
}

/** Whether motion should be reduced, from the preference and the device setting.
 * @param {string} pref @param {boolean} systemReduces */
export function shouldReduceMotion(pref, systemReduces) {
  if (pref === 'on') return true;
  if (pref === 'off') return false;
  return Boolean(systemReduces);
}
