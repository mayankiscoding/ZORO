// You: Memory, Security and privacy, Settings, and what the web app can and cannot do.
// Security settings are shown, not changed: every change needs the approval key, which this
// browser does not have. That is said on the screen instead of offering a control that fails.

import { formatDate, formatTime, formatWhen } from '../core/format.js';
import { LANGUAGE_NAMES } from '../i18n/index.js';
import { badge, confirmDialog, errorView, facts, section, segmented, stateView, switchRow } from '../ui/components.js';
import { h, onAction, replace } from '../ui/dom.js';
import { icon } from '../ui/icons.js';

const PLATFORM_ICON = { ios: 'phone', macos: 'laptop', web: 'globe' };

export function createYou(app) {
  const { t, prefs } = app;
  let shown = false;
  let view = '';
  const column = h('div.column');
  const scroll = h('div.scroll', null, column);
  const root = h('section.screen', { 'aria-label': t('you.title') }, scroll);

  function header(title, back = true) {
    return h(
      'div',
      null,
      back ? h('a.back', { href: '#/you' }, icon('back', { size: 20 }), t('you.title')) : null,
      h('div.screen-header', null, h('h1.t-title', { text: title, tabindex: '-1' })),
    );
  }

  function privacyFacts() {
    const state = app.security.value;
    if (!state) return null;
    const strict = state.privacy_mode === 'strict_private';
    return h(
      'div.banner',
      { dataset: { mode: state.privacy_mode } },
      h('span.banner-mark', { 'aria-hidden': 'true' }, icon(strict ? 'lock' : 'cloud', { size: 18 })),
      h('span.banner-text', null, h('p.banner-title', { text: t(strict ? 'privacy.strict.title' : 'privacy.cloud.title') }), h('p.banner-line', { text: t(strict ? 'privacy.strict.line' : 'privacy.cloud.line') })),
    );
  }

  // ---------------------------------------------------------------- index

  function renderIndex() {
    const link = (path, glyph, titleKey, lineKey) =>
      h(
        'a.row',
        { href: `#/you/${path}` },
        h('span.row-icon', { 'aria-hidden': 'true' }, icon(glyph, { size: 18 })),
        h('div.row-main', null, h('p.row-title', { text: t(titleKey) }), h('p.row-detail', { text: t(lineKey) })),
        h('span.row-aside', { 'aria-hidden': 'true' }, icon('chevron', { size: 18 })),
      );
    replace(
      column,
      header(t('you.title'), false),
      privacyFacts() ?? (app.security.status === 'error' ? errorView(t, app.security.error, { retry: () => app.security.refresh(), pair: app.repair, fallbackKey: 'security.error' }) : null),
      h(
        'nav.section',
        { 'aria-label': t('you.title') },
        h('div.rows', null, link('memory', 'memory', 'you.memory', 'you.memory.line'), link('security', 'shield', 'you.security', 'you.security.line'), link('settings', 'gear', 'you.settings', 'you.settings.line'), link('about', 'info', 'you.about', 'you.about.line')),
      ),
    );
  }

  // ---------------------------------------------------------------- memory

  function memorySource(source) {
    const text = String(source ?? '');
    if (text === 'user') return t('memory.source.user');
    if (text.startsWith('conversation:')) return t('memory.source.conversation');
    return text.split(':')[0];
  }

  function memoryRow(record) {
    const meta = [t.has(`memory.category.${record.category}`) ? t(`memory.category.${record.category}`) : record.category, t('memory.source', { source: memorySource(record.source) }), formatDate(record.created_at, t.lang)];
    const remove = h('button.icon-btn.icon-btn--quiet', { type: 'button', 'aria-label': `${t('memory.delete')}: ${record.text}` }, icon('trash', { size: 20 }));
    onAction(remove, async () => {
      if (!(await confirmDialog(t, { message: t('memory.delete_confirm'), confirmLabel: t('memory.delete') }))) return;
      try {
        await app.client.deleteMemory(record.id);
        app.memory.set({ ...app.memory.value, items: app.memory.value.items.filter((item) => item.id !== record.id) });
        app.toast(t('memory.deleted'));
      } catch (error) {
        app.toastError(error);
      }
    });
    const keep =
      record.status === 'pending_review'
        ? onAction(h('button.btn.btn--secondary.btn--small', { type: 'button', text: t('memory.keep') }), async () => {
            try {
              const updated = await app.client.json('PATCH', `/v1/memory/${encodeURIComponent(record.id)}`, { body: { status: 'active', verified: true } });
              app.memory.set({ ...app.memory.value, items: app.memory.value.items.map((item) => (item.id === record.id ? updated : item)) });
              app.toast(t('memory.kept'));
            } catch (error) {
              app.toastError(error);
            }
          })
        : null;
    return h(
      'li.row',
      null,
      h(
        'div.row-main',
        null,
        h('p.zoro-body', { text: record.text }),
        h('p.row-detail', { text: meta.filter(Boolean).join(', ') }),
        record.status === 'pending_review' ? h('div.btn-row', null, badge(t('memory.pending'), 'genda'), keep) : null,
        record.status === 'archived' ? badge(t('memory.archived')) : null,
      ),
      record.user_editable === false ? null : remove,
    );
  }

  function renderMemory() {
    const resource = app.memory;
    let body;
    if (resource.status === 'error' && !resource.value) {
      body = errorView(t, resource.error, { retry: () => resource.refresh(), pair: app.repair, fallbackKey: 'memory.error' });
    } else if (!resource.value) {
      body = stateView('loading', t('memory.loading'), null, { plain: true });
    } else if (resource.value.items.length === 0) {
      body = stateView('empty', t('memory.empty'), null, { plain: true });
    } else {
      body = h(
        'div',
        null,
        h('ul.rows', null, resource.value.items.map(memoryRow)),
        resource.value.next_cursor ? h('div.btn-row', null, onAction(h('button.btn.btn--link', { type: 'button', text: t('common.load_more') }), () => app.loadMoreMemory())) : null,
      );
    }
    replace(column, header(t('memory.title')), body, h('p.note.section', { text: t('memory.native_note') }));
  }

  // ---------------------------------------------------------------- security

  function deviceRow(device) {
    const mine = device.device_id === app.deviceId;
    const seen = device.online ? t('security.device.online') : device.last_seen_at ? t('security.device.seen', { when: formatWhen(device.last_seen_at, t.lang) }) : t('security.device.never');
    const platform = t.has(`security.platform.${device.platform}`) ? t(`security.platform.${device.platform}`) : device.platform;
    return h(
      'li.row',
      null,
      h('span.row-icon', { 'aria-hidden': 'true' }, icon(PLATFORM_ICON[device.platform] ?? 'phone', { size: 18 })),
      h('div.row-main', null, h('p.row-title', { text: device.name }), h('p.row-detail', { text: `${platform}, ${seen}` })),
      mine ? h('div.row-aside', null, badge(t('common.this_device'), 'neel')) : null,
    );
  }

  function renderSecurity() {
    const resource = app.security;
    if (resource.status === 'error' && !resource.value) {
      replace(column, header(t('security.title')), errorView(t, resource.error, { retry: () => resource.refresh(), pair: app.repair, fallbackKey: 'security.error' }));
      return;
    }
    if (!resource.value) {
      replace(column, header(t('security.title')), stateView('loading', t('security.loading'), null, { plain: true }));
      return;
    }
    const state = resource.value;
    const onOff = (value) => t(value ? 'common.on' : 'common.off');
    const audit = app.audit;
    let auditBody;
    if (audit.status === 'error' && !audit.value) auditBody = errorView(t, audit.error, { retry: () => audit.refresh(), fallbackKey: 'security.audit.error', plain: true });
    else if (!audit.value) auditBody = stateView('loading', t('common.loading'), null, { plain: true });
    else if (audit.value.items.length === 0) auditBody = stateView('empty', t('security.audit.empty'), null, { plain: true });
    else {
      auditBody = h(
        'ul.rows',
        null,
        audit.value.items.map((record) =>
          h(
            'li.row',
            null,
            h('div.row-main', null, h('p.row-title', { text: record.tool ? `${record.action}: ${record.tool}` : record.action }), h('p.row-detail', { text: `${formatWhen(record.ts, t.lang)}${record.detail ? `, ${record.detail}` : ''}` })),
            h('div.row-aside', null, badge(t(`security.audit.decision.${['allowed', 'approved', 'denied', 'blocked', 'failed', 'info'].includes(record.decision) ? record.decision : 'info'}`), { allowed: 'mor', approved: 'mor', denied: 'lac', blocked: 'lac', failed: 'lac', info: null }[record.decision] ?? null)),
          ),
        ),
      );
    }
    replace(
      column,
      header(t('security.title')),
      h('p.callout.callout--moon', { role: 'note' }, icon('lock', { size: 18 }), h('span', { text: t('security.readonly') })),
      section(
        t('security.mode'),
        {},
        privacyFacts(),
        h(
          'div.settings-group.section',
          null,
          switchRow({
            label: t('security.local_private'),
            note: t('security.local_private.note'),
            checked: prefs.get('alwaysPrivate'),
            onChange: (checked) => {
              prefs.set({ alwaysPrivate: checked });
              app.toast(t(checked ? 'security.local_private.on' : 'security.local_private.off'));
            },
          }),
        ),
        h(
          'div.card.section',
          null,
          facts([
            { label: t('security.kill_switch'), value: t(state.kill_switch ? 'security.kill_switch.on' : 'security.kill_switch.off') },
            { label: t('security.biometric_high'), value: onOff(state.biometric_for_high_risk) },
            { label: t('security.public_external'), value: onOff(state.strict_allow_public_external) },
          ], { wide: true }),
          state.session_expires_at ? h('p.source-line', { text: t('security.session', { time: formatTime(state.session_expires_at, t.lang) }) }) : null,
        ),
      ),
      section(t('security.devices'), {}, h('ul.rows', null, (state.devices ?? []).map(deviceRow)), h('p.note.section', { text: t('security.device.revoke_note') })),
      section(
        t('security.permissions'),
        {},
        h(
          'ul.rows',
          null,
          (state.permissions ?? []).map((grant) =>
            h('li.row', null, h('div.row-main', null, h('p.row-title', { text: grant.title }), h('p.row-detail.mono', { text: grant.key })), h('div.row-aside', null, badge(t(grant.granted ? 'security.permission.granted' : 'security.permission.denied'), grant.granted ? 'mor' : null))),
          ),
        ),
      ),
      section(t('security.audit'), {}, auditBody),
    );
  }

  // ---------------------------------------------------------------- settings

  function voicePicker(language, labelKey) {
    const voices = app.speaker.voicesFor(language);
    const prefKey = language === 'hi' ? 'voiceHi' : 'voiceEn';
    if (!app.speaker.supported) return null;
    if (voices.length === 0) return h('div.field', null, h('p.field-label', { text: t(labelKey) }), h('p.field-hint', { text: t('settings.voice.none') }));
    const id = `voice-${language}`;
    const select = h('select.input', { id }, h('option', { value: '', text: t('settings.voice.default') }), voices.map((voice) => h('option', { value: voice.voiceURI, text: `${voice.name} (${voice.lang})` })));
    select.value = voices.some((voice) => voice.voiceURI === prefs.get(prefKey)) ? prefs.get(prefKey) : '';
    select.addEventListener('change', () => prefs.set({ [prefKey]: select.value || null }));
    return h(
      'div.field',
      null,
      h('label', { for: id, text: t(labelKey) }),
      select,
      h('div.btn-row', null, onAction(h('button.btn.btn--secondary.btn--small', { type: 'button' }, icon('speaker', { size: 18 }), t('settings.voice.sample')), () => { app.speaker.stop(); app.speaker.say(t(`settings.voice.sample.${language}`), language); })),
    );
  }

  function renderSettings() {
    const facts_ = app.pairing;
    const health = app.health;
    const statusKey = health.status === 'error' ? 'settings.server.unreachable' : !health.value ? 'settings.server.checking' : health.value.status === 'ok' ? 'settings.server.ok' : 'settings.server.degraded';
    const update = h('p.field-hint', { role: 'status' });
    const recognition = !app.voice.canListen ? 'unsupported' : prefs.get('speechConsent') ? 'on' : 'off';
    replace(
      column,
      header(t('settings.title')),
      section(
        t('settings.server'),
        {},
        h(
          'div.card',
          null,
          facts([
            { label: t('settings.server.name'), value: facts_?.serverName },
            { label: t('settings.server.address'), value: globalThis.location?.origin ?? '' },
            { label: t('settings.server.status'), value: t(statusKey) },
            { label: t('settings.server.device'), value: facts_?.deviceName },
          ]),
          facts_ ? h('p.source-line', { text: `${t('settings.server.paired_at', { date: formatDate(facts_.pairedAt, t.lang) })}. ${t('settings.server.registered_as', { platform: t.has(`security.platform.${facts_.platform}`) ? t(`security.platform.${facts_.platform}`) : facts_.platform })}.` }) : null,
        ),
        h('p.note.section', { text: t('settings.server.address_note') }),
      ),
      section(
        t('settings.language'),
        {},
        h(
          'div.settings-group',
          null,
          segmented({ legend: t('settings.language.app'), name: 'set-lang', value: prefs.get('lang'), options: Object.entries(LANGUAGE_NAMES).map(([value, label]) => ({ value, label })), onChange: (value) => prefs.set({ lang: value }) }),
          segmented({ legend: t('settings.language.reply'), name: 'set-reply', value: prefs.get('replyLanguage'), options: ['auto', 'en', 'hi', 'hinglish'].map((value) => ({ value, label: t(`settings.language.reply.${value}`) })), onChange: (value) => prefs.set({ replyLanguage: value }) }),
          segmented({ legend: t('settings.language.listen'), name: 'set-listen', value: prefs.get('listenLang'), options: [{ value: 'en-IN', label: t('settings.language.listen.en') }, { value: 'hi-IN', label: t('settings.language.listen.hi') }], onChange: (value) => prefs.set({ listenLang: value }) }),
        ),
      ),
      section(
        t('settings.voice'),
        {},
        h(
          'div.settings-group',
          null,
          app.speaker.supported
            ? segmented({ legend: t('settings.voice.speak'), name: 'set-speak', value: prefs.get('speakReplies'), options: ['voice', 'always', 'never'].map((value) => ({ value, label: t(`settings.voice.speak.${value}`) })), onChange: (value) => prefs.set({ speakReplies: value }) })
            : h('p.note', { text: t('settings.voice.unsupported') }),
          voicePicker('en', 'settings.voice.english'),
          voicePicker('hi', 'settings.voice.hindi'),
          app.speaker.supported
            ? segmented({ legend: t('settings.voice.rate'), name: 'set-rate', value: String(prefs.get('rate')), options: [{ value: '0.85', label: t('settings.voice.rate.slow') }, { value: '1', label: t('settings.voice.rate.normal') }, { value: '1.15', label: t('settings.voice.rate.fast') }], onChange: (value) => prefs.set({ rate: Number(value) }) })
            : null,
          h('p.field-hint', { text: t('settings.voice.local_note') }),
          h(
            'div.field',
            null,
            h('p.field-label', { text: t('settings.voice.recognition') }),
            h('p', { text: t(`settings.voice.recognition.${recognition}`) }),
            recognition === 'on'
              ? h('div.btn-row', null, h('button.btn.btn--secondary.btn--small', { type: 'button', text: t('settings.voice.recognition.turn_off'), on: { click: () => { prefs.set({ speechConsent: false }); app.toast(t('settings.voice.recognition.turned_off')); } } }))
              : null,
          ),
        ),
      ),
      section(
        t('settings.answers'),
        {},
        h('div.settings-group', null, segmented({ legend: t('settings.answers.length'), name: 'set-length', value: prefs.get('responseLength'), options: ['brief', 'balanced', 'detailed'].map((value) => ({ value, label: t(`settings.answers.${value}`) })), onChange: (value) => prefs.set({ responseLength: value }) })),
      ),
      section(
        t('settings.motion'),
        {},
        h('div.settings-group', null, segmented({ legend: t('settings.motion.reduce'), name: 'set-motion', value: prefs.get('reduceMotion'), options: ['system', 'on', 'off'].map((value) => ({ value, label: t(`settings.motion.${value}`) })), onChange: (value) => prefs.set({ reduceMotion: value }) }), h('p.field-hint', { text: t('settings.motion.note') })),
      ),
      section(
        t('settings.app'),
        {},
        h(
          'div.settings-group',
          null,
          h('p', { text: t('settings.app.version', { version: app.version }) }),
          h('p.field-hint', { text: t('settings.app.offline_note') }),
          h('div.btn-row', null, onAction(h('button.btn.btn--secondary.btn--small', { type: 'button' }, icon('refresh', { size: 18 }), t('settings.app.update')), async () => { update.textContent = t(`settings.app.${await app.checkForUpdate()}`); })),
          update,
        ),
      ),
      section(
        t('settings.forget'),
        {},
        h('p.note', { text: t('settings.forget.note') }),
        h(
          'div.btn-row.section',
          null,
          onAction(h('button.btn.btn--danger.btn--small', { type: 'button', text: t('settings.forget') }), async () => {
            if (!(await confirmDialog(t, { message: t('settings.forget.confirm'), confirmLabel: t('settings.forget') }))) return;
            await app.forgetPairing();
            app.toast(t('settings.forget.done'));
          }),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- about

  function renderAbout() {
    const bullets = (keys, glyph, cls) => h(`ul.bullets${cls}`, null, keys.map((key) => h('li', null, icon(glyph, { size: 18 }), h('span', { text: t(key) }))));
    replace(
      column,
      header(t('about.title')),
      section(t('about.works'), {}, bullets(['about.works.conversation', 'about.works.cards', 'about.works.approvals', 'about.works.links', 'about.works.views', 'about.works.voice'], 'check', '.bullets--works')),
      section(t('about.native'), {}, bullets(['about.native.biometric', 'about.native.device', 'about.native.health', 'about.native.voice', 'about.native.background', 'about.native.offline'], 'phone', '')),
      section(t('about.never'), {}, h('p.note', { text: t('about.never.line') })),
    );
  }

  function render() {
    if (!shown) return;
    if (view === 'memory') renderMemory();
    else if (view === 'security') renderSecurity();
    else if (view === 'settings') renderSettings();
    else if (view === 'about') renderAbout();
    else renderIndex();
  }

  const rerender = (only) => () => {
    if (shown && (!only || only.includes(view))) render();
  };
  const unsubscribe = [
    app.security.subscribe(rerender(['', 'security'])),
    app.audit.subscribe(rerender(['security'])),
    app.memory.subscribe(rerender(['memory'])),
    app.health.subscribe(rerender(['settings'])),
    prefs.subscribe((_all, changed) => {
      // The controls keep their own state, so a choice does not redraw the screen (and focus
      // stays where it is). Only the speech recognition line depends on a preference.
      if (shown && view === 'settings' && changed.includes('speechConsent')) render();
    }),
  ];

  return {
    root,
    title: () => t(view === 'memory' ? 'memory.title' : view === 'security' ? 'security.title' : view === 'settings' ? 'settings.title' : view === 'about' ? 'about.title' : 'you.title'),
    show(sub = '') {
      const changed = !shown || sub !== view;
      shown = true;
      view = ['memory', 'security', 'settings', 'about'].includes(sub) ? sub : '';
      render();
      if (changed) scroll.scrollTop = 0;
      if (view === 'memory') app.memory.refresh();
      if (view === 'security' || view === '') app.security.refresh();
      if (view === 'security') app.audit.refresh();
      if (view === 'settings') {
        app.health.refresh();
        app.speaker.onVoicesChanged = rerender(['settings']);
      }
    },
    hide() {
      shown = false;
      app.speaker.stop();
    },
    destroy() {
      for (const off of unsubscribe) off();
    },
  };
}
