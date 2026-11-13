// The composer on Home: type, or talk. One round button changes its job with the moment:
// talk (tap, or hold while speaking), finish listening, stop, send, or point to the keyboard's
// dictation key when the browser offers no speech recognition.

import { isActive } from '../core/turn-reducer.js';
import { createSheet } from '../ui/components.js';
import { h, replace, setText } from '../ui/dom.js';
import { icon } from '../ui/icons.js';

const GLYPH = { talk: 'waveform', listening: 'check', stop: 'stop', send: 'send', dictate: 'keyboard' };

/** @param {any} app @param {{send: (text: string, modality?: string) => any}} actions */
export function createComposer(app, { send }) {
  const { t, conversation, voice, prefs } = app;
  let pointerActive = false;
  let pointerEndedAt = 0;
  let mode = 'talk';

  const hint = h('p.composer-hint', { hidden: true, role: 'status' });
  const input = h('textarea', { rows: '1', placeholder: t('home.composer.placeholder'), 'aria-label': t('home.composer.label'), enterkeyhint: 'send', autocapitalize: 'sentences', maxlength: '8000' });
  const button = h('button.composer-btn', { type: 'submit' });
  const form = h('form.composer', { novalidate: true }, input, button);
  const finishButton = h('button.btn.btn--block.btn--mor.finish-btn', { type: 'button', hidden: true, text: t('home.finish') });
  const root = h('div.composer-wrap', null, hint, finishButton, form);

  function render() {
    const turn = conversation.state.turn;
    let next = 'talk';
    if (voice.state.listening) next = 'listening';
    else if (isActive(turn)) next = 'stop';
    else if (input.value.trim().length > 0) next = 'send';
    else if (voice.state.speaking) next = 'stop';
    else if (!voice.canListen) next = 'dictate';
    mode = next;
    if (button.dataset.mode !== mode) {
      const label = { talk: t('home.talk_hold'), listening: t('home.finish'), stop: t('home.stop'), send: t('home.send'), dictate: t('home.dictate') }[mode];
      button.dataset.mode = mode;
      button.setAttribute('aria-label', label);
      button.title = label;
      replace(button, icon(GLYPH[mode], { size: 22 }));
    }
    // The composer stays in place while listening: a held button must not vanish under the finger.
    finishButton.hidden = !voice.state.listening;

    const problem = voice.state.problem;
    if (problem && problem !== 'aborted') {
      hint.hidden = false;
      setText(hint, t(problem === 'unavailable' && !voice.canListen ? 'home.dictation_hint' : `voice.problem.${problem}`));
    } else {
      hint.hidden = true;
    }
  }

  function autosize() {
    input.style.height = 'auto';
    input.style.height = `${Math.min(input.scrollHeight, 145)}px`;
  }

  function submit() {
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    autosize();
    send(text);
  }

  /** Ask once before the browser's speech service is used. Listening starts from the tap on
   * "Turn on", so it still counts as the owner's gesture. */
  function askSpeechConsent() {
    const { dialog, body } = createSheet('consent-title');
    body.append(
      h('h2#consent-title.t-heading', { text: t('voice.consent.title') }),
      h('p.zoro-body', { text: t('voice.consent.body') }),
      h(
        'div.btn-stack',
        null,
        h('button.btn.btn--block.btn--primary', { type: 'button', text: t('voice.consent.agree'), on: { click: () => dialog.close('agree') } }),
        h('button.btn.btn--block.btn--secondary', { type: 'button', text: t('voice.consent.decline'), autofocus: true, on: { click: () => dialog.close('decline') } }),
      ),
    );
    dialog.addEventListener('close', () => {
      const agreed = dialog.returnValue === 'agree';
      dialog.remove();
      if (agreed) {
        prefs.set({ speechConsent: true });
        voice.startListening();
      } else {
        input.focus();
      }
    });
    document.body.append(dialog);
    dialog.showModal();
  }

  /** Start talking by whatever `start` does, after the checks that come first. */
  function talk(start) {
    if (!voice.canListen) {
      voice.startListening(); // records the 'unavailable' problem, which shows the dictation hint
      input.focus();
    } else if (!prefs.get('speechConsent')) {
      askSpeechConsent();
    } else {
      start();
    }
  }

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    if (pointerActive || Date.now() - pointerEndedAt < 500) return; // the press already handled it
    if (mode === 'send') submit();
    else if (mode === 'stop') {
      app.speaker.stop();
      conversation.cancel();
    } else if (mode === 'listening') voice.finishListening();
    else talk(() => voice.toggle());
  });

  // Push-to-talk: hold the button while speaking; a short press listens until a pause.
  button.addEventListener('pointerdown', (event) => {
    if (mode !== 'talk' || event.button > 0) return;
    if (!voice.canListen || !prefs.get('speechConsent')) return; // the click that follows asks first
    pointerActive = true;
    try {
      button.setPointerCapture(event.pointerId);
    } catch {
      /* capture is a convenience */
    }
    voice.pressStart();
  });
  const release = () => {
    if (!pointerActive) return;
    pointerActive = false;
    pointerEndedAt = Date.now();
    voice.pressEnd();
  };
  button.addEventListener('pointerup', release);
  button.addEventListener('pointercancel', release);
  button.addEventListener('contextmenu', (event) => event.preventDefault());
  finishButton.addEventListener('click', () => voice.finishListening());

  input.addEventListener('input', () => {
    autosize();
    render();
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      submit();
    }
  });

  return { root, render, talk, focus: () => input.focus() };
}
