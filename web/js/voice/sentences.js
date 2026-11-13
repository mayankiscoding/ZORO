// Text handling for speech: cut a streamed reply into sentences, decide which voice language a
// sentence needs, and tidy text that reads badly aloud. Pure functions, tested in Node.

const DEVANAGARI = /[ऀ-ॿ]/;
const TERMINATORS = new Set(['.', '!', '?', '।', '॥', '\n']);
const CLOSERS = new Set(['"', "'", '”', '’', ')', ']']);
const ABBREVIATIONS = /(?:\b(?:mr|mrs|ms|dr|prof|st|no|vs|etc|approx|rs|inc|ltd|e\.g|i\.e)|\b[a-z])$/i;
const MAX_SENTENCE = 280;

/** True when the text has Devanagari letters. @param {string} text */
export function hasDevanagari(text) {
  return DEVANAGARI.test(text);
}

// Common Hindi words written in Latin script (none that is also an everyday English word). Enough to tell "kal subah alarm laga do" from
// English; the server's own language detection decides the reply, this only picks a voice.
const HINGLISH_WORDS = new Set(
  ('hai hain ho hoon hu tha thi ka ki ke ko se mein aur ya nahi nahin haan ji kya kyun kyon ' +
    'kaise kab kahan kaun kitna kitne kitni mera meri mere mujhe mujhko aap aapka aapki tum ' +
    'tumhara yeh ye woh wo kar karo karna kiya kijiye dena diya lo lena liya bhejo bhej ' +
    'batao bata dikhao dikha chahiye raha rahi rahe gaya gayi gaye hoga hogi abhi kal aaj ' +
    'subah shaam raat baje laga lagao jodo hatao khol kholo chalu sabse sasta mehnga kharcha ' +
    'paisa rupaye doodh chawal accha theek bahut thoda zyada kam wala wali wale liye saath ' +
    'bhi sirf phir fir toh').split(' '),
);

/** Latin-script Hindi ("Hinglish"): at least two known words, and a fifth of all words.
 * @param {string} text */
export function looksHinglish(text) {
  if (!text || hasDevanagari(text)) return false;
  const words = text.toLowerCase().match(/[a-z]+/g) || [];
  if (words.length === 0) return false;
  const hits = words.filter((word) => HINGLISH_WORDS.has(word)).length;
  return hits >= 2 && hits / words.length >= 0.2;
}

/** 'en' | 'hi' | 'hinglish' for a piece of text. */
export function detectLanguage(text) {
  if (hasDevanagari(text)) return 'hi';
  return looksHinglish(text) ? 'hinglish' : 'en';
}

/** The voice language for a sentence. Devanagari always needs a Hindi voice; Latin-script
 * Hinglish is read far better by a Hindi voice than by an English one.
 * @param {string} sentence @param {string | null} [turnLanguage] 'en' | 'hi' | 'hinglish' */
export function speechLanguage(sentence, turnLanguage = null) {
  if (hasDevanagari(sentence)) return 'hi';
  if (turnLanguage === 'hinglish' || (turnLanguage == null && looksHinglish(sentence))) return 'hi';
  return 'en';
}

/** Make text speakable: no markup, links said as "link", a real word for the minus sign.
 * @param {string} text */
export function forSpeech(text) {
  return String(text ?? '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/\[([^\]]+)\]\((?:https?:\/\/)[^)]+\)/g, '$1')
    .replace(/https?:\/\/\S+/g, 'link')
    .replace(/[*_`#>|]+/g, ' ')
    .replace(/−(?=\s?[₹\d])/g, 'minus ')
    .replace(/\s+/g, ' ')
    .trim();
}

function isBoundary(buffer, index) {
  const ch = buffer[index];
  if (!TERMINATORS.has(ch)) return false;
  if (ch === '\n' || ch === '।' || ch === '॥') return true;
  // Skip closing quotes and brackets, then require whitespace: "12.50" and "4.5 km" stay whole,
  // and a full stop at the very end of the buffer waits for what comes next.
  let next = index + 1;
  while (next < buffer.length && (CLOSERS.has(buffer[next]) || buffer[next] === ch)) next += 1;
  if (next >= buffer.length || !/\s/.test(buffer[next])) return false;
  if (ch === '.' && ABBREVIATIONS.test(buffer.slice(Math.max(0, index - 8), index))) return false;
  return true;
}

/** Cuts streamed text into sentences as they complete. */
export class SentenceChunker {
  constructor() {
    this._buffer = '';
  }

  /** @param {string} text @returns {string[]} the sentences completed by this text */
  push(text) {
    this._buffer += text ?? '';
    const out = [];
    let start = 0;
    for (let i = 0; i < this._buffer.length; i += 1) {
      let cut = -1;
      if (isBoundary(this._buffer, i)) {
        cut = i + 1;
        while (cut < this._buffer.length && (CLOSERS.has(this._buffer[cut]) || TERMINATORS.has(this._buffer[cut])) && this._buffer[cut] !== '\n') cut += 1;
      } else if (i - start >= MAX_SENTENCE && /[\s,;:]/.test(this._buffer[i])) {
        cut = i + 1; // a very long run without a full stop: break at a pause
      }
      if (cut !== -1) {
        const sentence = this._buffer.slice(start, cut).trim();
        if (sentence) out.push(sentence);
        start = cut;
        i = cut - 1;
      }
    }
    this._buffer = this._buffer.slice(start);
    return out;
  }

  /** The unfinished rest, at the end of the reply. @returns {string[]} */
  flush() {
    const rest = this._buffer.trim();
    this._buffer = '';
    return rest ? [rest] : [];
  }

  reset() {
    this._buffer = '';
  }
}

/** All sentences of a complete text. @param {string} text */
export function splitSentences(text) {
  const chunker = new SentenceChunker();
  return [...chunker.push(text), ...chunker.flush()];
}

/** Order the browser's voices for a language: on-device voices only (a network voice would send
 * ZORO's reply to the browser maker), Indian variants first, the platform default before others.
 * @param {{voiceURI: string, name: string, lang: string, localService: boolean, default?: boolean}[]} voices
 * @param {'en' | 'hi'} language */
export function rankVoices(voices, language) {
  const wanted = language === 'hi' ? ['hi-in', 'hi'] : ['en-in', 'en-gb', 'en-au', 'en-us', 'en'];
  const score = (voice) => {
    const lang = String(voice.lang || '').replace('_', '-').toLowerCase();
    let rank = wanted.findIndex((prefix) => lang === prefix || lang.startsWith(`${prefix}-`) || (prefix.length === 2 && lang.startsWith(prefix)));
    if (rank === -1) return -1;
    rank = (wanted.length - rank) * 10;
    if (/premium|enhanced|natural/i.test(voice.name)) rank += 3;
    if (voice.default) rank += 1;
    return rank;
  };
  return voices
    .filter((voice) => voice && voice.localService === true)
    .map((voice) => ({ voice, rank: score(voice) }))
    .filter((item) => item.rank >= 0)
    .sort((a, b) => b.rank - a.rank || a.voice.name.localeCompare(b.voice.name))
    .map((item) => item.voice);
}
