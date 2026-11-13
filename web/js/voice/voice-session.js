// Voice on the web: push-to-talk, spoken replies, barge-in.
//
// Listening starts only from a tap or a held button and ends with the utterance. Starting to
// listen while ZORO is speaking or working is a barge-in: speech stops at once and the running
// turn is cancelled on the server, then the orb listens.

import { detectLanguage } from './sentences.js';

const HOLD_MS = 350;

export class VoiceSession {
  /** @param {{recognizer: any, speaker: any, conversation: any, prefs: any,
   *   ownerLevel: any, zoroLevel: any, mic?: any, useMic?: boolean,
   *   onChange?: (state: VoiceSession['state']) => void, now?: () => number}} options */
  constructor({
    recognizer,
    speaker,
    conversation,
    prefs,
    ownerLevel,
    zoroLevel,
    mic = null,
    useMic = false,
    onChange = () => {},
    now = () => Date.now(),
  }) {
    this._recognizer = recognizer;
    this._speaker = speaker;
    this._conversation = conversation;
    this._prefs = prefs;
    this._ownerLevel = ownerLevel;
    this._zoroLevel = zoroLevel;
    this._mic = mic;
    this._useMic = useMic && Boolean(mic?.supported);
    this._onChange = onChange;
    this._now = now;
    this._pressedAt = 0;
    this._startedByPress = false;
    this.state = {
      listening: false,
      speaking: false,
      /** Words recognised so far in this utterance. */
      interim: '',
      /** Why listening did not work: 'denied' | 'no_microphone' | 'network' | 'language' |
       * 'no_speech' | 'unavailable' | null */
      problem: null,
    };
    this._unsubscribe = conversation.subscribe((_state, change) => this._onConversation(change));
  }

  get canListen() {
    return this._recognizer.supported;
  }

  get canSpeak() {
    return this._speaker.supported;
  }

  _set(patch) {
    this.state = { ...this.state, ...patch };
    this._onChange(this.state);
  }

  /** Called by the speaker when speech starts or ends. */
  speakingChanged(speaking) {
    if (!speaking) this._zoroLevel.reset();
    this._set({ speaking });
  }

  /** Called by the speaker at word boundaries, so the orb moves with ZORO's voice. */
  spokenPulse() {
    this._zoroLevel.pulse(0.75);
  }

  // ---------------------------------------------------------------- replies

  _onConversation(change) {
    if (change.type === 'turn_begin') {
      const turn = this._conversation.state.turn;
      this._speaker.begin(detectLanguage(turn.ownerText), turn.modality);
    } else if (change.type === 'event' && change.event.type === 'text_delta') {
      this._speaker.feed(change.event.text ?? '');
    } else if (change.type === 'turn_end') {
      if (change.outcome === 'completed') this._speaker.end(change.turn?.completed?.language ?? null);
      else if (change.outcome !== 'disconnected') this._speaker.stop();
    }
  }

  stopSpeaking() {
    this._speaker.stop();
  }

  // ---------------------------------------------------------------- listening

  /** Start listening. Barge-in: stops speech and cancels the running turn first. */
  async startListening() {
    if (this.state.listening) return true;
    if (!this.canListen) {
      this._set({ problem: 'unavailable' });
      return false;
    }
    this._speaker.prime(); // inside the owner's tap, so the reply may be spoken later
    const interrupting = this.state.speaking || this._conversation.busy;
    this._speaker.stop();
    if (interrupting) {
      // Not awaited before listening starts: the owner is already talking.
      this._conversation.cancel().catch(() => {});
    }
    this._set({ listening: true, interim: '', problem: null });
    this._ownerLevel.reset();
    if (this._useMic) {
      this._mic.start().then((ok) => {
        if (ok && this.state.listening) this._ownerLevel.setSource(() => this._mic.read());
        else if (ok) this._mic.stop();
      });
    }
    const started = this._recognizer.start({
      lang: this._prefs.get('listenLang'),
      onInterim: (text) => this._set({ interim: text }),
      onActivity: () => this._ownerLevel.pulse(0.7),
      onDone: (result) => this._heard(result),
    });
    return started;
  }

  _heard({ text, problem }) {
    this._ownerLevel.setSource(null);
    this._mic?.stop();
    this._set({ listening: false, interim: text ? text : '', problem: text ? null : problem });
    if (text) {
      this._conversation.send(text, { modality: 'voice' }).catch(() => {});
      this._set({ interim: '' });
    }
  }

  /** Finish the utterance now and send what was heard. */
  finishListening() {
    if (this.state.listening) this._recognizer.stop();
  }

  /** Stop listening and send nothing. */
  cancelListening() {
    if (!this.state.listening) return;
    this._recognizer.abort();
    this._ownerLevel.setSource(null);
    this._mic?.stop();
    this._set({ listening: false, interim: '', problem: null });
  }

  /** Tap: start, or finish when already listening. */
  toggle() {
    if (this.state.listening) {
      this.finishListening();
      return Promise.resolve(true);
    }
    return this.startListening();
  }

  /** Button pressed. A short press is a tap (listen until a pause or the next tap); a long
   * press is push-to-talk (listen while held). */
  pressStart() {
    this._pressedAt = this._now();
    this._startedByPress = !this.state.listening;
    if (this._startedByPress) return this.startListening();
    return Promise.resolve(true);
  }

  pressEnd() {
    const held = this._now() - this._pressedAt;
    if (!this._startedByPress) {
      this.finishListening(); // second tap: finish
    } else if (held >= HOLD_MS) {
      this.finishListening(); // push-to-talk released
    }
    this._startedByPress = false;
  }

  clearProblem() {
    if (this.state.problem) this._set({ problem: null });
  }

  dispose() {
    this._unsubscribe();
    this.cancelListening();
    this._speaker.stop();
  }
}
