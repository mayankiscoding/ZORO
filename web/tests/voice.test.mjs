// Voice: sentence cutting, voice choice (on-device voices only), spoken replies, push-to-talk
// and barge-in. Browser speech objects are replaced by small fakes.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { LevelMeter, LevelRing, sharesMicrophone } from '../js/voice/levels.js';
import { Recognizer, recognitionProblem } from '../js/voice/recognizer.js';
import { detectLanguage, forSpeech, looksHinglish, rankVoices, SentenceChunker, speechLanguage, splitSentences } from '../js/voice/sentences.js';
import { Speaker } from '../js/voice/speaker.js';
import { VoiceSession } from '../js/voice/voice-session.js';

// ---------------------------------------------------------------- sentences

test('sentences are cut at full stops, question marks and the danda, not inside numbers', () => {
  assert.deepEqual(splitSentences('Store A has all three for ₹1,234.50, the lowest. Open the basket there?'), ['Store A has all three for ₹1,234.50, the lowest.', 'Open the basket there?']);
  assert.deepEqual(splitSentences('अलार्म लग गया। कल सुबह 6 बजे बजेगा।'), ['अलार्म लग गया।', 'कल सुबह 6 बजे बजेगा।']);
  assert.deepEqual(splitSentences('You ran 4.5 km at 6:12 pm. Dr. Rao said e.g. rest.'), ['You ran 4.5 km at 6:12 pm.', 'Dr. Rao said e.g. rest.']);
  assert.deepEqual(splitSentences('First line\nSecond line'), ['First line', 'Second line']);
  assert.deepEqual(splitSentences('He said "done." Then left.'), ['He said "done."', 'Then left.']);
  assert.deepEqual(splitSentences('   '), []);
});

test('streamed text gives the same sentences however it is split', () => {
  const text = 'Saved to your profile memory. Spent ₹12.50 on tea! और कुछ? हाँ। Done';
  const whole = splitSentences(text);
  assert.equal(whole.length, 5);
  for (let cut = 1; cut < text.length; cut += 1) {
    const chunker = new SentenceChunker();
    const parts = [...chunker.push(text.slice(0, cut)), ...chunker.push(text.slice(cut)), ...chunker.flush()];
    assert.deepEqual(parts, whole, `cut at ${cut}`);
  }
});

test('a full stop at the end of a chunk waits for what follows; a long run breaks at a pause', () => {
  const chunker = new SentenceChunker();
  assert.deepEqual(chunker.push('The total is ₹12.'), []);
  assert.deepEqual(chunker.push('50 today. Next'), ['The total is ₹12.50 today.']);
  assert.deepEqual(chunker.flush(), ['Next']);
  const long = `${'word, '.repeat(80)}end.`;
  const parts = splitSentences(long);
  assert.ok(parts.length >= 2 && parts.every((part) => part.length <= 300));
  assert.equal(parts.join(' ').replace(/\s+/g, ' '), long.replace(/\s+/g, ' ').trim());
});

test('language for speech: Devanagari and Hinglish use a Hindi voice, English an English one', () => {
  assert.equal(detectLanguage('कल सुबह 6 बजे अलार्म लगा दो'), 'hi');
  assert.equal(detectLanguage('kal subah 6 baje alarm laga do'), 'hinglish');
  assert.equal(detectLanguage('set an alarm for 6 tomorrow morning'), 'en');
  assert.equal(detectLanguage('to do list for the week'), 'en'); // "to" and "do" alone are not Hinglish
  assert.equal(looksHinglish('mujhe doodh aur chawal chahiye'), true);
  assert.equal(speechLanguage('Instamart से दूध मँगा लिया।', 'en'), 'hi'); // script wins over the hint
  assert.equal(speechLanguage('Alarm lag gaya.', 'hinglish'), 'hi');
  assert.equal(speechLanguage('Alarm set.', 'en'), 'en');
  assert.equal(speechLanguage('Alarm lag gaya hai kal ke liye.', null), 'hi');
});

test('text is tidied for speech: no markup, links said as "link", a spoken minus', () => {
  assert.equal(forSpeech('**Done.** See [the bill](https://example.com/b) or https://example.com/x'), 'Done. See the bill or link');
  assert.equal(forSpeech('Net −₹500 this month'), 'Net minus ₹500 this month');
  assert.equal(forSpeech('```code```  plain'), 'plain');
  assert.equal(forSpeech(null), '');
});

// ---------------------------------------------------------------- voices

const VOICES = [
  { voiceURI: 'g-en', name: 'Google UK English Female', lang: 'en-GB', localService: false },
  { voiceURI: 'samantha', name: 'Samantha', lang: 'en-US', localService: true, default: true },
  { voiceURI: 'rishi', name: 'Rishi', lang: 'en-IN', localService: true },
  { voiceURI: 'rishi-p', name: 'Rishi (Enhanced)', lang: 'en_IN', localService: true },
  { voiceURI: 'lekha', name: 'Lekha', lang: 'hi-IN', localService: true },
  { voiceURI: 'g-hi', name: 'Google हिन्दी', lang: 'hi-IN', localService: false },
  { voiceURI: 'thomas', name: 'Thomas', lang: 'fr-FR', localService: true },
];

test('only on-device voices are offered, Indian variants first', () => {
  assert.deepEqual(rankVoices(VOICES, 'en').map((voice) => voice.voiceURI), ['rishi-p', 'rishi', 'samantha']);
  assert.deepEqual(rankVoices(VOICES, 'hi').map((voice) => voice.voiceURI), ['lekha']);
  assert.deepEqual(rankVoices(VOICES.filter((voice) => !voice.localService), 'en'), []); // network voices are never used
  assert.deepEqual(rankVoices([], 'hi'), []);
});

function fakeSynth(voices = VOICES) {
  const spoken = [];
  return {
    spoken,
    cancelled: 0,
    getVoices: () => voices,
    speak(utterance) {
      spoken.push(utterance);
    },
    cancel() {
      this.cancelled += 1;
    },
    addEventListener() {},
  };
}

class FakeUtterance {
  constructor(text) {
    this.text = text;
  }
}

function fakePrefs(values = {}) {
  const all = { speakReplies: 'voice', rate: 1, voiceEn: null, voiceHi: null, listenLang: 'en-IN', speechConsent: true, ...values };
  return { get: (key) => all[key], set: (patch) => Object.assign(all, patch) };
}

test('replies are spoken sentence by sentence with a voice for each language', () => {
  const synth = fakeSynth();
  const states = [];
  const speaker = new Speaker({ synth, Utterance: FakeUtterance, prefs: fakePrefs({ rate: 1.15 }), onChange: (speaking) => states.push(speaking) });
  speaker.begin('en', 'voice');
  speaker.feed('Alarm set. ');
  speaker.feed('कल सुबह 6 बजे');
  assert.deepEqual(synth.spoken.map((u) => u.text), ['Alarm set.']);
  speaker.end('hi');
  assert.deepEqual(synth.spoken.map((u) => [u.text, u.voice.voiceURI, u.lang, u.rate]), [['Alarm set.', 'rishi-p', 'en_IN', 1.15], ['कल सुबह 6 बजे', 'lekha', 'hi-IN', 1.15]]);
  assert.equal(speaker.speaking, true);
  synth.spoken[0].onend();
  assert.equal(speaker.speaking, true); // one sentence is still queued
  synth.spoken[1].onend();
  assert.equal(speaker.speaking, false);
  assert.deepEqual(states, [true, false]);
});

test('typed turns stay silent unless the owner chose "always"; "never" silences voice turns too', () => {
  for (const [pref, modality, expected] of [['voice', 'text', 0], ['voice', 'voice', 1], ['always', 'text', 1], ['never', 'voice', 0]]) {
    const synth = fakeSynth();
    const speaker = new Speaker({ synth, Utterance: FakeUtterance, prefs: fakePrefs({ speakReplies: pref }) });
    speaker.begin('en', modality);
    speaker.feed('Done. ');
    speaker.end('en');
    assert.equal(synth.spoken.length, expected, `${pref}/${modality}`);
  }
});

test('with no on-device voice for a language the reply is shown, not spoken; the chosen voice is honoured', () => {
  const noHindi = fakeSynth(VOICES.filter((voice) => !voice.lang.startsWith('hi') || !voice.localService));
  const speaker = new Speaker({ synth: noHindi, Utterance: FakeUtterance, prefs: fakePrefs({ voiceEn: 'samantha' }) });
  assert.equal(speaker.voiceFor('hi'), null);
  assert.equal(speaker.voiceFor('en').voiceURI, 'samantha');
  speaker.begin('hinglish', 'voice');
  speaker.feed('हो गया। Ho gaya. ');
  speaker.end('hinglish');
  assert.deepEqual(noHindi.spoken.map((u) => u.text), []); // a Hindi voice is wanted and there is none on the device
  assert.equal(speaker.say('Sample.', 'en'), true);
  assert.equal(noHindi.spoken[0].voice.voiceURI, 'samantha');
  assert.equal(speaker.say('नमूना।', 'hi'), false);
});

test('stop() cancels speech at once and late callbacks from old utterances are ignored', () => {
  const synth = fakeSynth();
  const speaker = new Speaker({ synth, Utterance: FakeUtterance, prefs: fakePrefs() });
  speaker.begin('en', 'voice');
  speaker.feed('One. Two. ');
  const old = synth.spoken[0];
  speaker.stop();
  assert.equal(synth.cancelled, 1);
  assert.equal(speaker.speaking, false);
  old.onstart();
  old.onend();
  assert.equal(speaker.speaking, false);
  const none = new Speaker({ synth: null, Utterance: null, prefs: fakePrefs() });
  assert.equal(none.supported, false);
  none.begin('en', 'voice');
  none.feed('x. ');
  none.end();
  none.stop();
  assert.deepEqual(none.voicesFor('en'), []);
});

// ---------------------------------------------------------------- recognition

class FakeRecognition {
  static last = null;
  constructor() {
    FakeRecognition.last = this;
    this.started = false;
  }
  start() {
    this.started = true;
  }
  stop() {
    this.stopped = true;
    this.onend?.();
  }
  abort() {
    this.aborted = true;
  }
  result(final, interim = '') {
    const results = [];
    if (final) results.push(Object.assign([{ transcript: final }], { isFinal: true }));
    if (interim) results.push(Object.assign([{ transcript: interim }], { isFinal: false }));
    this.onresult?.({ results });
  }
}

test('recognition delivers interim words, then one result; words heard win over a late error', () => {
  const recognizer = new Recognizer({ Recognition: FakeRecognition });
  const interim = [];
  let done = null;
  assert.equal(recognizer.start({ lang: 'hi-IN', onInterim: (text) => interim.push(text), onDone: (result) => (done = result) }), true);
  const r = FakeRecognition.last;
  assert.deepEqual([r.lang, r.continuous, r.interimResults], ['hi-IN', false, true]);
  r.result('', 'दूध');
  r.result('दूध और ', 'चावल');
  r.onerror({ error: 'no-speech' });
  r.onend();
  assert.deepEqual(interim, ['दूध', 'दूध और चावल']);
  assert.deepEqual(done, { text: 'दूध और चावल', problem: null });
  assert.equal(recognizer.listening, false);
});

test('recognition problems are named; abort delivers nothing; an unsupported browser says so', () => {
  assert.deepEqual(['not-allowed', 'service-not-allowed', 'audio-capture', 'network', 'language-not-supported', 'no-speech', 'aborted', 'weird'].map(recognitionProblem), ['denied', 'denied', 'no_microphone', 'network', 'language', 'no_speech', 'aborted', 'unavailable']);
  const recognizer = new Recognizer({ Recognition: FakeRecognition });
  let done = null;
  recognizer.start({ lang: 'en-IN', onDone: (result) => (done = result) });
  FakeRecognition.last.onerror({ error: 'not-allowed' });
  FakeRecognition.last.onend();
  assert.deepEqual(done, { text: '', problem: 'denied' });

  let aborted = 'untouched';
  recognizer.start({ lang: 'en-IN', onDone: () => (aborted = 'delivered') });
  const session = FakeRecognition.last;
  recognizer.abort();
  session.onend?.();
  assert.equal(aborted, 'untouched');
  assert.equal(session.aborted, true);

  const none = new Recognizer({ Recognition: null });
  assert.equal(none.supported, false);
  let result = null;
  assert.equal(none.start({ lang: 'en-IN', onDone: (value) => (result = value) }), false);
  assert.deepEqual(result, { text: '', problem: 'unavailable' });
});

// ---------------------------------------------------------------- session: push-to-talk and barge-in

function sessionSetup({ busy = false } = {}) {
  const log = [];
  const listeners = new Set();
  const conversation = {
    busy,
    state: { turn: { ownerText: '', modality: 'text' } },
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    cancel: async () => {
      log.push('cancel');
      conversation.busy = false;
    },
    send: async (text, options) => {
      log.push(`send:${text}:${options.modality}`);
    },
    emit: (change) => listeners.forEach((listener) => listener(conversation.state, change)),
  };
  const speaker = {
    supported: true,
    prime: () => log.push('prime'),
    stop: () => log.push('speaker.stop'),
    begin: (language, modality) => log.push(`begin:${language}:${modality}`),
    feed: (text) => log.push(`feed:${text}`),
    end: (language) => log.push(`end:${language}`),
  };
  const recognizer = new Recognizer({ Recognition: FakeRecognition });
  let clock = 0;
  const states = [];
  const voice = new VoiceSession({
    recognizer,
    speaker,
    conversation,
    prefs: fakePrefs({ listenLang: 'hi-IN' }),
    ownerLevel: new LevelMeter({ now: () => clock }),
    zoroLevel: new LevelMeter({ now: () => clock }),
    onChange: (state) => states.push({ ...state }),
    now: () => clock,
  });
  return { voice, conversation, log, states, advance: (ms) => (clock += ms) };
}

test('barge-in: starting to listen stops speech and cancels the running turn, then listens', async () => {
  const { voice, log } = sessionSetup({ busy: true });
  voice.speakingChanged(true);
  await voice.startListening();
  assert.deepEqual(log.slice(0, 3), ['prime', 'speaker.stop', 'cancel']);
  assert.equal(voice.state.listening, true);
  assert.equal(FakeRecognition.last.lang, 'hi-IN');
  assert.equal(FakeRecognition.last.started, true);
});

test('with nothing running, listening does not cancel anything; what was heard is sent as a voice turn', async () => {
  const { voice, log, states } = sessionSetup();
  await voice.startListening();
  assert.ok(!log.includes('cancel'));
  FakeRecognition.last.result('', 'doodh');
  assert.equal(voice.state.interim, 'doodh');
  FakeRecognition.last.result('doodh aur chawal chahiye');
  voice.finishListening();
  assert.ok(log.includes('send:doodh aur chawal chahiye:voice'));
  assert.equal(voice.state.listening, false);
  assert.equal(voice.state.interim, '');
  assert.ok(states.some((state) => state.listening));
});

test('push-to-talk: a held press listens until release; a short tap keeps listening until the next tap', async () => {
  const held = sessionSetup();
  await held.voice.pressStart();
  held.advance(900);
  FakeRecognition.last.result('hold to talk');
  held.voice.pressEnd();
  assert.ok(held.log.includes('send:hold to talk:voice'));

  const tapped = sessionSetup();
  await tapped.voice.pressStart();
  tapped.advance(120);
  tapped.voice.pressEnd();
  assert.equal(tapped.voice.state.listening, true); // still listening after a short tap
  FakeRecognition.last.result('tap to talk');
  await tapped.voice.pressStart();
  tapped.advance(100);
  tapped.voice.pressEnd(); // second tap finishes
  assert.ok(tapped.log.includes('send:tap to talk:voice'));
});

test('nothing heard, a refusal and an unsupported browser each leave a named problem and send nothing', async () => {
  const quiet = sessionSetup();
  await quiet.voice.startListening();
  FakeRecognition.last.onerror({ error: 'no-speech' });
  FakeRecognition.last.onend();
  assert.equal(quiet.voice.state.problem, 'no_speech');
  assert.ok(!quiet.log.some((entry) => entry.startsWith('send')));
  quiet.voice.clearProblem();
  assert.equal(quiet.voice.state.problem, null);

  const cancelled = sessionSetup();
  await cancelled.voice.startListening();
  FakeRecognition.last.result('half a sent');
  cancelled.voice.cancelListening(); // the app went to the background
  assert.equal(cancelled.voice.state.listening, false);
  assert.ok(!cancelled.log.some((entry) => entry.startsWith('send')));
});

test('replies are routed to the speaker: begin on the turn, feed on deltas, end with the server language', () => {
  const { conversation, log } = sessionSetup();
  conversation.state.turn = { ownerText: 'kal subah alarm laga do', modality: 'voice' };
  conversation.emit({ type: 'turn_begin' });
  conversation.emit({ type: 'event', event: { type: 'text_delta', text: 'Alarm lag gaya.' } });
  conversation.emit({ type: 'event', event: { type: 'route', agents: [] } });
  conversation.emit({ type: 'turn_end', outcome: 'completed', turn: { completed: { language: 'hinglish' } } });
  assert.deepEqual(log, ['begin:hinglish:voice', 'feed:Alarm lag gaya.', 'end:hinglish']);
  conversation.emit({ type: 'turn_end', outcome: 'cancelled' });
  assert.equal(log.at(-1), 'speaker.stop');
});

// ---------------------------------------------------------------- levels

test('levels: a pulse rises fast and decays; silence is stored as nothing', () => {
  let clock = 0;
  const meter = new LevelMeter({ now: () => clock });
  assert.equal(meter.sample(), 0);
  meter.pulse(0.8);
  const first = meter.sample();
  assert.ok(first > 0.4);
  clock += 2000;
  let last = first;
  for (let i = 0; i < 60; i += 1) last = meter.sample();
  assert.equal(last, 0);
  meter.setSource(() => 0.5);
  for (let i = 0; i < 20; i += 1) last = meter.sample();
  assert.ok(Math.abs(last - 0.5) < 0.01);
  meter.setSource(() => { throw new Error('mic gone'); });
  assert.ok(meter.sample() <= 0.5);

  const ring = new LevelRing(4);
  assert.equal(ring.silent, true);
  for (const value of [0.01, 0.5, 2, 0.02, 0.3]) ring.push(value);
  assert.deepEqual(ring.values().map((value) => Number(value.toFixed(2))), [0.5, 1, 0, 0.3]);
  ring.clear();
  assert.equal(ring.silent, true);
});

test('iPhone and iPad share one microphone session, so the analyser is not opened there', () => {
  assert.equal(sharesMicrophone({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' }), true);
  assert.equal(sharesMicrophone({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 5 }), true);
  assert.equal(sharesMicrophone({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 0 }), false);
});
