// Speech recognition where the browser offers it (the Web Speech API).
//
// Honest limits, shown to the owner before first use:
// - The browser's speech service does the recognising, not the ZORO server. Depending on the
//   browser and device it may send audio to Apple or Google.
// - It works only while the page is open and the orb is listening. There is no wake word and no
//   background listening.
// - Safari does not always offer it to web apps opened from the Home Screen. When it is missing
//   or refused, the composer points to the keyboard's dictation key instead.

/** @returns {any} the recognition constructor, or null */
export function recognitionConstructor(scope = globalThis) {
  return scope.SpeechRecognition || scope.webkitSpeechRecognition || null;
}

/** Map a Web Speech error to what the interface should say.
 * @param {string} error */
export function recognitionProblem(error) {
  switch (error) {
    case 'not-allowed':
    case 'service-not-allowed':
      return 'denied';
    case 'audio-capture':
      return 'no_microphone';
    case 'network':
      return 'network';
    case 'language-not-supported':
      return 'language';
    case 'no-speech':
      return 'no_speech';
    case 'aborted':
      return 'aborted';
    default:
      return 'unavailable';
  }
}

export class Recognizer {
  /** @param {{Recognition?: any}} [options] */
  constructor({ Recognition = recognitionConstructor() } = {}) {
    this._Recognition = Recognition;
    this._session = null;
    this.listening = false;
  }

  get supported() {
    return typeof this._Recognition === 'function';
  }

  /** Start listening. One utterance: recognition ends by itself after a pause.
   * @param {{lang: string, onInterim?: (text: string) => void, onActivity?: () => void,
   *   onDone: (result: {text: string, problem: string | null}) => void}} handlers */
  start({ lang, onInterim = () => {}, onActivity = () => {}, onDone }) {
    if (!this.supported) {
      onDone({ text: '', problem: 'unavailable' });
      return false;
    }
    this.abort();
    let recognition;
    try {
      recognition = new this._Recognition();
    } catch {
      onDone({ text: '', problem: 'unavailable' });
      return false;
    }
    const session = { recognition, finalText: '', interim: '', problem: null, finished: false };
    this._session = session;
    recognition.lang = lang;
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.maxAlternatives = 1;

    recognition.onresult = (event) => {
      if (this._session !== session) return;
      let finalText = '';
      let interim = '';
      for (let i = 0; i < event.results.length; i += 1) {
        const result = event.results[i];
        const transcript = result[0]?.transcript ?? '';
        if (result.isFinal) finalText += transcript;
        else interim += transcript;
      }
      session.finalText = finalText;
      session.interim = interim;
      onActivity();
      onInterim(`${finalText}${interim}`.trim());
    };
    recognition.onspeechstart = () => onActivity();
    recognition.onerror = (event) => {
      session.problem = recognitionProblem(event?.error);
    };
    recognition.onend = () => {
      if (session.finished) return;
      session.finished = true;
      if (this._session === session) {
        this._session = null;
        this.listening = false;
      }
      const text = `${session.finalText}${session.interim}`.trim();
      const problem = session.problem === 'aborted' ? null : session.problem;
      // Words that were heard win over a late "no speech" report.
      onDone({ text, problem: text ? null : problem });
    };

    try {
      recognition.start();
    } catch {
      session.finished = true;
      this._session = null;
      onDone({ text: '', problem: 'unavailable' });
      return false;
    }
    this.listening = true;
    return true;
  }

  /** Finish the utterance and deliver what was heard (push-to-talk release, "Tap to finish"). */
  stop() {
    try {
      this._session?.recognition.stop();
    } catch {
      /* already stopped */
    }
  }

  /** Stop without delivering anything. */
  abort() {
    const session = this._session;
    if (!session) return;
    session.finished = true;
    this._session = null;
    this.listening = false;
    try {
      session.recognition.abort();
    } catch {
      /* already stopped */
    }
  }
}
