// Sound levels for the orb and the rekha waveform.
//
// `LevelMeter` turns either a live source (the microphone analyser) or single pulses (a word
// recognised, a word spoken) into a smooth 0..1 value. These levels only drive drawing; they
// are never stored or sent anywhere.

const DECAY_MS = 240;

export class LevelMeter {
  /** @param {{now?: () => number}} [options] */
  constructor({ now = () => globalThis.performance?.now() ?? Date.now() } = {}) {
    this._now = now;
    this._source = null;
    this._impulse = 0;
    this._impulseAt = 0;
    this._smooth = 0;
  }

  /** A live source returning 0..1, or null to use pulses only. */
  setSource(source) {
    this._source = source;
  }

  /** One beat (a recognised word, a spoken word boundary). */
  pulse(strength = 0.8) {
    this._impulse = Math.max(this._decayed(), Math.min(1, strength));
    this._impulseAt = this._now();
  }

  _decayed() {
    const age = this._now() - this._impulseAt;
    return age <= 0 ? this._impulse : this._impulse * Math.exp(-age / DECAY_MS);
  }

  /** Current level, 0..1. */
  sample() {
    let live = 0;
    if (this._source) {
      try {
        live = Math.max(0, Math.min(1, this._source() || 0));
      } catch {
        live = 0;
      }
    }
    const target = Math.max(live, this._decayed());
    // Rise fast, fall slowly, so the drawing does not flicker.
    this._smooth += (target - this._smooth) * (target > this._smooth ? 0.6 : 0.18);
    if (this._smooth < 0.004) this._smooth = 0;
    return this._smooth;
  }

  reset() {
    this._impulse = 0;
    this._smooth = 0;
  }
}

/** Fixed-size history of levels for the waveform. Silence stores zero, which draws nothing. */
export class LevelRing {
  /** @param {number} size */
  constructor(size = 48) {
    this._values = new Float32Array(size);
    this._next = 0;
    this.size = size;
  }

  push(value) {
    this._values[this._next] = value < 0.03 ? 0 : Math.min(1, value);
    this._next = (this._next + 1) % this.size;
  }

  /** Oldest to newest. */
  values() {
    const out = new Array(this.size);
    for (let i = 0; i < this.size; i += 1) out[i] = this._values[(this._next + i) % this.size];
    return out;
  }

  get silent() {
    return this._values.every((value) => value === 0);
  }

  clear() {
    this._values.fill(0);
  }
}

/** iPhone and iPad browsers share one microphone session between speech recognition and
 * `getUserMedia`; opening both stops recognition. There the orb follows recognised words. */
export function sharesMicrophone(nav = globalThis.navigator) {
  const ua = nav?.userAgent ?? '';
  return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && (nav?.maxTouchPoints ?? 0) > 1);
}

/** Microphone loudness through an AnalyserNode. Audio is measured in the page and dropped. */
export class MicLevels {
  /** @param {{mediaDevices?: MediaDevices, AudioContextImpl?: typeof AudioContext}} [options] */
  constructor({
    mediaDevices = globalThis.navigator?.mediaDevices,
    AudioContextImpl = globalThis.AudioContext || globalThis.webkitAudioContext,
  } = {}) {
    this._media = mediaDevices;
    this._AudioContext = AudioContextImpl;
    this._stream = null;
    this._context = null;
    this._analyser = null;
    this._buffer = null;
  }

  get supported() {
    return Boolean(this._media?.getUserMedia && this._AudioContext);
  }

  /** @returns {Promise<boolean>} false when the microphone is unavailable or refused */
  async start() {
    if (!this.supported || this._stream) return Boolean(this._stream);
    try {
      this._stream = await this._media.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
      this._context = new this._AudioContext();
      const source = this._context.createMediaStreamSource(this._stream);
      this._analyser = this._context.createAnalyser();
      this._analyser.fftSize = 512;
      this._buffer = new Uint8Array(this._analyser.fftSize);
      source.connect(this._analyser);
      return true;
    } catch {
      this.stop();
      return false;
    }
  }

  /** Root-mean-square loudness scaled to 0..1. */
  read() {
    if (!this._analyser) return 0;
    this._analyser.getByteTimeDomainData(this._buffer);
    let sum = 0;
    for (let i = 0; i < this._buffer.length; i += 1) {
      const centred = (this._buffer[i] - 128) / 128;
      sum += centred * centred;
    }
    return Math.min(1, Math.sqrt(sum / this._buffer.length) * 4);
  }

  stop() {
    for (const track of this._stream?.getTracks?.() ?? []) track.stop();
    this._stream = null;
    this._analyser = null;
    this._buffer = null;
    const context = this._context;
    this._context = null;
    context?.close?.().catch?.(() => {});
  }
}
