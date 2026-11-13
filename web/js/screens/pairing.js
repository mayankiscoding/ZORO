// First run: welcome, connect with a one-time code, then language and voice.
// Permissions are not asked here; each is asked the first time a feature needs it.

import { pairingErrorKey } from '../core/errors.js';
import { CODE_LENGTH, defaultDeviceName, displayCode, normaliseCode, pairDevice } from '../core/pairing.js';
import { LANGUAGE_NAMES } from '../i18n/index.js';
import { segmented, stateView } from '../ui/components.js';
import { h, onAction, replace } from '../ui/dom.js';
import { icon } from '../ui/icons.js';
import { Orb } from '../ui/orb.js';

/** A pairing code handed over in the address fragment (`#pair=K7QM-2XWD`), which never reaches
 * the server. @param {string} hash */
export function codeFromHash(hash) {
  const match = /[#&]pair=([A-Za-z0-9-]{4,12})/.exec(hash || '');
  const code = match ? normaliseCode(match[1]) : '';
  return code.length === CODE_LENGTH ? code : '';
}

export function createPairing(app, { onPaired }) {
  const { t, prefs } = app;
  const column = h('div.column');
  const root = h('section.screen', { 'aria-label': t('pair.title') }, h('div.scroll', null, column));
  let orb = null;
  let step = 'welcome';

  function limits() {
    return h(
      'ul.bullets',
      null,
      ['background', 'device', 'biometric'].map((key) => h('li', null, icon('info', { size: 18 }), h('span', { text: t(`intro.limit.${key}`) }))),
    );
  }

  function welcome() {
    const canvas = h('canvas.orb-canvas', { 'aria-hidden': 'true' });
    replace(
      column,
      h(
        'div.welcome',
        null,
        h('div.welcome-orb', null, canvas),
        h(
          'div.welcome-copy',
          null,
          h('h1.t-title', { text: t('welcome.title') }),
          h('p.welcome-line', { text: t('welcome.line') }),
          h('p.note', { text: t('welcome.companion') }),
          app.secure ? null : stateView('error', `${t('secure.title')}. ${t('secure.body')} ${t('secure.how')}`),
          app.storagePersistent ? null : stateView('disconnected', t('storage.temporary')),
          h('button.btn.btn--block.btn--primary', { type: 'button', text: t('welcome.start'), disabled: !app.secure, on: { click: () => go('connect') } }),
        ),
      ),
    );
    orb?.destroy();
    orb = new Orb(canvas, { reduceMotion: app.reduceMotion });
    orb.setState('idle');
  }

  function connect() {
    orb?.destroy();
    orb = null;
    const error = h('p.field-error', { role: 'alert', hidden: true });
    const code = h('input#pair-code.input.input--code', {
      type: 'text',
      inputmode: 'text',
      autocomplete: 'one-time-code',
      autocapitalize: 'characters',
      autocorrect: 'off',
      spellcheck: 'false',
      maxlength: '9',
      placeholder: 'XXXX-XXXX',
      'aria-describedby': 'pair-code-hint',
      required: true,
    });
    code.value = displayCode(app.prefilledCode ?? '');
    code.addEventListener('input', () => {
      const end = code.selectionStart === code.value.length;
      code.value = displayCode(code.value);
      if (end) code.setSelectionRange(code.value.length, code.value.length);
      error.hidden = true;
    });
    const name = h('input#pair-name.input', { type: 'text', maxlength: '200', autocomplete: 'off', 'aria-describedby': 'pair-name-hint', required: true });
    name.value = defaultDeviceName();
    const submit = h('button.btn.btn--block.btn--primary', { type: 'submit', text: t('pair.connect') });
    const progress = h('div', { 'aria-live': 'polite' });
    const form = h(
      'form',
      { novalidate: true },
      h('div.field', null, h('label', { for: 'pair-server', text: t('pair.server') }), h('input#pair-server.input', { type: 'text', readonly: true, value: globalThis.location?.host ?? '', 'aria-describedby': 'pair-server-hint' }), h('p#pair-server-hint.field-hint', { text: t('pair.server_note') })),
      h('div.field', null, h('label', { for: 'pair-code', text: t('pair.code') }), code, h('p#pair-code-hint.field-hint', { text: t('pair.code_hint') })),
      h('div.field', null, h('label', { for: 'pair-name', text: t('pair.name') }), name, h('p#pair-name-hint.field-hint', { text: t('pair.name_hint') })),
      h('div.field', null, error, progress, submit, h('p.field-hint', { text: t('pair.keys_note') })),
    );
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      if (submit.disabled) return;
      error.hidden = true;
      submit.disabled = true;
      replace(progress, stateView('loading', t('pair.connecting'), null, { plain: true }));
      try {
        const record = await pairDevice({ client: app.client, identity: app.identity, code: code.value, deviceName: name.value.trim() || defaultDeviceName() });
        app.client.signOut(); // a token of an earlier pairing must not outlive it
        app.toast(t('pair.done', { server: record.serverName }));
        if (prefs.get('introduced')) onPaired();
        else go('intro');
      } catch (failure) {
        const key = pairingErrorKey(failure);
        error.textContent = t(key, { code: String(failure?.code ?? 'error') });
        error.hidden = false;
        (key === 'pair.error.name' ? name : code).focus();
      } finally {
        submit.disabled = false;
        replace(progress);
      }
    });
    replace(
      column,
      h('div.screen-header', null, h('button.back', { type: 'button', on: { click: () => go('welcome') } }, icon('back', { size: 20 }), t('nav.back'))),
      h('h1.t-title', { text: t('pair.title') }),
      h('div.section', null, form),
    );
    (code.value.length === CODE_LENGTH + 1 ? submit : code).focus();
  }

  function intro() {
    const voiceNote = h('div');
    const renderVoice = () => {
      const lang = prefs.get('lang') === 'hi' ? 'hi' : 'en';
      const available = app.speaker.voiceFor(lang) !== null;
      replace(
        voiceNote,
        available
          ? onAction(h('button.btn.btn--secondary.btn--small', { type: 'button' }, icon('speaker', { size: 18 }), t('intro.sample')), () => {
              app.speaker.stop();
              app.speaker.say(t(`settings.voice.sample.${lang}`), lang);
            })
          : h('p.note', { text: t(app.speaker.supported ? 'intro.no_voice' : 'settings.voice.unsupported') }),
      );
    };
    app.speaker.onVoicesChanged = renderVoice;
    renderVoice();
    replace(
      column,
      h('h1.t-title', { text: t('intro.title') }),
      h(
        'div.section.steps',
        null,
        h(
          'div.settings-group',
          null,
          segmented({
            legend: t('intro.language'),
            name: 'intro-lang',
            value: prefs.get('lang'),
            options: Object.entries(LANGUAGE_NAMES).map(([value, label]) => ({ value, label })),
            onChange: (value) => {
              prefs.set({ lang: value, listenLang: value === 'hi' ? 'hi-IN' : 'en-IN' });
              intro(); // the screen is redrawn in the chosen language
            },
          }),
          h('p.field-hint', { text: t('intro.language_note') }),
        ),
        h('div.settings-group', null, h('p.field-label', { text: t('intro.voice') }), h('p.field-hint', { text: t('intro.voice_note') }), voiceNote),
        h('div.settings-group', null, h('h2.t-heading', { text: t('intro.limits_title') }), limits()),
        h('button.btn.btn--block.btn--primary', {
          type: 'button',
          text: t('intro.start'),
          on: {
            click: () => {
              app.speaker.stop();
              app.speaker.onVoicesChanged = () => {};
              prefs.set({ introduced: true });
              onPaired();
            },
          },
        }),
      ),
    );
    column.querySelector('h1')?.focus?.();
  }

  function go(next) {
    step = next;
    if (next === 'welcome') welcome();
    else if (next === 'connect') connect();
    else intro();
    root.querySelector('.scroll').scrollTop = 0;
  }

  return {
    root,
    title: () => t('pair.title'),
    show(startAt = 'welcome') {
      go(startAt === 'welcome' && app.prefilledCode && app.secure ? 'connect' : startAt);
    },
    hide() {
      orb?.destroy();
      orb = null;
    },
    get step() {
      return step;
    },
  };
}
