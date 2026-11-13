// Spoken replies with the browser's speech synthesis, sentence by sentence.
//
// Only on-device voices are used (`localService === true`): a network voice would send ZORO's
// reply to the browser maker, which strict private mode forbids and `cloud_voice_allowed: false`
// rules out for a reply. When the browser has no on-device voice for a language, the reply is
// shown and not spoken, and Settings says why.

import { forSpeech, rankVoices, SentenceChunker, speechLanguage } from './sentences.js';

export class Speaker {
  /** @param {{synth?: SpeechSynthesis, Utterance?: typeof SpeechSynthesisUtterance,
   *   prefs: {get: (key: string) => any}, onChange?: (speaking: boolean) => void,
   *   onPulse?: () => void}} options */
  constructor({
    synth = globalThis.speechSynthesis,
    Utterance = globalThis.SpeechSynthesisUtterance,
    prefs,
    onChange = () => {},
    onPulse = () => {},
  }) {
    this._synth = synth ?? null;
    this._Utterance = Utterance ?? null;
    this._prefs = prefs;
    this._onChange = onChange;
    this._onPulse = onPulse;
    this._chunker = new SentenceChunker();
    this._pending = 0;
    this._generation = 0;
    this._primed = false;
    this._turnLanguage = null;
    this._active = false;
    this.speaking = false;
    this._voicesChanged = () => {};
    if (this._synth && typeof this._synth.addEventListener === 'function') {
      this._synth.addEventListener('voiceschanged', () => this._voicesChanged());
    }
  }

  get supported() {
    return Boolean(this._synth && this._Utterance);
  }

  /** Called when the browser's voice list arrives (it loads late in most browsers). */
  set onVoicesChanged(listener) {
    this._voicesChanged = listener;
  }

  /** On-device voices for a language, best first. @param {'en' | 'hi'} language */
  voicesFor(language) {
    if (!this.supported) return [];
    let voices = [];
    try {
      voices = this._synth.getVoices() || [];
    } catch {
      voices = [];
    }
    return rankVoices(voices, language);
  }

  /** The voice that will be used for a language, or null when there is none on this device. */
  voiceFor(language) {
    const voices = this.voicesFor(language);
    const chosen = this._prefs.get(language === 'hi' ? 'voiceHi' : 'voiceEn');
    return voices.find((voice) => voice.voiceURI === chosen) ?? voices[0] ?? null;
  }

  /** Browsers only allow speech after the owner has touched the page. Call this from a tap so
   * replies that arrive later may be spoken. */
  prime() {
    if (!this.supported || this._primed) return;
    this._primed = true;
    try {
      const silent = new this._Utterance(' ');
      silent.volume = 0;
      this._synth.speak(silent);
    } catch {
      /* the browser refused; a later tap will try again */
      this._primed = false;
    }
  }

  /** Start a reply. @param {string | null} turnLanguage the owner's language, when known
   * @param {'text' | 'voice'} [modality] how the owner asked */
  begin(turnLanguage = null, modality = 'text') {
    this._chunker.reset();
    this._turnLanguage = turnLanguage;
    const when = this._prefs.get('speakReplies');
    this._active = when === 'always' || (when === 'voice' && modality === 'voice');
  }

  /** Feed streamed text; complete sentences are spoken as they arrive. */
  feed(text) {
    if (!this._enabled()) return;
    for (const sentence of this._chunker.push(text)) this._say(sentence);
  }

  /** The reply is complete. @param {string | null} [language] the server's word on the language */
  end(language = null) {
    if (language) this._turnLanguage = language;
    if (!this._enabled()) {
      this._chunker.reset();
      return;
    }
    for (const sentence of this._chunker.flush()) this._say(sentence);
  }

  /** Speak one piece of text now (voice samples in Settings, a repeat of the last reply). */
  say(text, language = null) {
    if (!this.supported) return false;
    const before = this._pending;
    this._turnLanguage = language;
    for (const sentence of new SentenceChunker().push(`${text}\n`)) this._say(sentence, language === 'hi' || language === 'en' ? language : null);
    return this._pending > before;
  }

  _enabled() {
    return this.supported && this._active === true;
  }

  _say(sentence, forced = null) {
    const text = forSpeech(sentence);
    if (!text) return;
    const language = forced ?? speechLanguage(text, this._turnLanguage);
    const voice = this.voiceFor(language);
    if (!voice) return; // no on-device voice for this language: shown, not spoken
    const utterance = new this._Utterance(text);
    utterance.voice = voice;
    utterance.lang = voice.lang;
    utterance.rate = this._prefs.get('rate') ?? 1;
    const generation = this._generation;
    const done = () => {
      if (generation !== this._generation) return;
      this._pending = Math.max(0, this._pending - 1);
      if (this._pending === 0) this._setSpeaking(false);
    };
    utterance.onstart = () => {
      if (generation === this._generation) this._setSpeaking(true);
    };
    utterance.onboundary = () => {
      if (generation === this._generation) this._onPulse();
    };
    utterance.onend = done;
    utterance.onerror = done;
    this._pending += 1;
    try {
      this._synth.speak(utterance);
      this._setSpeaking(true);
    } catch {
      done();
    }
  }

  _setSpeaking(speaking) {
    if (this.speaking === speaking) return;
    this.speaking = speaking;
    this._onChange(speaking);
  }

  /** Stop at once (barge-in, Stop button, leaving the screen). */
  stop() {
    this._generation += 1;
    this._pending = 0;
    this._chunker.reset();
    if (this.supported) {
      try {
        this._synth.cancel();
      } catch {
        /* nothing was speaking */
      }
    }
    this._setSpeaking(false);
  }
}
