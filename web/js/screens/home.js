// Home: the orb, the rekha with the current exchange, cards, the composer.
// ZORO's words stand on the line in the serif; the owner's hang below it. Nothing else moves.

import { toExchanges } from '../core/messages.js';
import { openedResult, openLink, planDeviceAction, refusedResult } from '../core/device-actions.js';
import { approvalErrorKey, describeTurnError } from '../core/errors.js';
import { agentName } from '../core/format.js';
import { canSignApproval } from '../core/identity.js';
import { activityRows, isActive, orbStateFor, satellitesFor } from '../core/turn-reducer.js';
import { approvalCard, linkBlock } from '../ui/approval.js';
import { renderCard } from '../ui/cards.js';
import { badge, errorView, section, stateView } from '../ui/components.js';
import { h, onAction, reconcile, replace, setText } from '../ui/dom.js';
import { icon } from '../ui/icons.js';
import { Orb } from '../ui/orb.js';
import { orbValue } from '../ui/orb-params.js';
import { RekhaWaveform } from '../ui/rekha.js';
import { createComposer } from './home-composer.js';

const EARLIER_PAGE = 12;
const ERROR_FLASH_MS = 2400;
const STATUS_TONE = { working: 'neel', needs_owner: 'genda', done: 'mor', failed: 'lac' };

export function createHome(app) {
  const { t, conversation, voice, prefs } = app;
  let shown = false;
  let errorFlash = false;
  let errorTimer = 0;
  let earlierLimit = EARLIER_PAGE;
  let sheetFor = null; // approval id whose sheet was already offered
  let deviceTimer = 0;
  let deviceTimerFor = null;

  // ---------------------------------------------------------------- structure

  const bannerTitle = h('p.banner-title');
  const bannerLine = h('p.banner-line');
  const bannerMark = h('span.banner-mark', { 'aria-hidden': 'true' });
  const banner = h('a.banner', { href: '#/you/security' }, bannerMark, h('span.banner-text', null, bannerTitle, bannerLine), h('span.banner-action', { text: t('privacy.change') }));
  const newButton = h('button.icon-btn', { type: 'button', 'aria-label': t('home.new'), title: t('home.new') }, icon('plus'));

  const orbCanvas = h('canvas.orb-canvas', { 'aria-hidden': 'true' });
  const orbStatus = h('p#orb-status.orb-status', { role: 'status', 'aria-live': 'polite' });
  const orbNote = h('span#orb-note.visually-hidden');
  const orbButton = h('button.orb-btn', { type: 'button', 'aria-label': t('orb.label'), 'aria-describedby': 'orb-status orb-note' }, orbCanvas);

  const notice = h('div');
  const zoroText = h('p.zoro-voice', { lang: 'en' });
  const speakButton = h('button.btn.btn--link.exchange-speak', { type: 'button', hidden: true }, icon('speaker', { size: 18 }), t('home.speak_reply'));
  const waveCanvas = h('canvas.rekha-wave', { 'aria-hidden': 'true' });
  const ownerText = h('p.owner-voice');
  const stage = h(
    'div.exchange.exchange--live',
    { 'aria-live': 'polite', 'aria-atomic': 'false' },
    h('div.exchange-zoro', null, h('span.visually-hidden', { text: `${t('home.zoro_said')}: ` }), zoroText, speakButton),
    h('div.rekha', null, waveCanvas),
    h('div.exchange-owner', null, h('span.visually-hidden', { text: `${t('home.you_said')}: ` }), ownerText),
  );
  const extras = h('div.turn-extras');
  const cards = h('div.turn-cards');
  const waiting = h('div.home-block');
  const earlier = h('div.home-block');

  const scroll = h(
    'div.scroll',
    null,
    h('div.column', null, h('div.home-top', null, banner, newButton), h('div.orb-stage', null, orbButton, orbStatus, orbNote), notice, stage, extras, cards, waiting, earlier),
  );

  const composer = createComposer(app, { send: (text) => send(text) });
  const root = h('section.screen.home', { 'aria-label': t('home.title') }, scroll, composer.root);

  const orb = new Orb(orbCanvas, { reduceMotion: app.reduceMotion, level: () => (voice.state.listening ? app.ownerLevel.sample() : voice.state.speaking ? app.zoroLevel.sample() : 0) });
  const wave = new RekhaWaveform(waveCanvas, { ownerLevel: () => app.ownerLevel.sample(), zoroLevel: () => app.zoroLevel.sample(), reduceMotion: app.reduceMotion });

  // ---------------------------------------------------------------- derived view

  function privateMode() {
    const server = app.security.value?.privacy_mode ?? conversation.state.turn.privacyMode;
    return prefs.get('alwaysPrivate') || server === 'strict_private';
  }

  function stageView() {
    const { turn, messages } = conversation.state;
    const exchanges = toExchanges(messages);
    if (turn.ownerText) {
      return { key: turn.turnId ? `turn:${turn.turnId}` : 'turn:pending', owner: turn.ownerText, zoro: turn.text, language: turn.completed?.language ?? null, cards: turn.cards, earlier: exchanges, live: true };
    }
    const last = exchanges[exchanges.length - 1] ?? null;
    return {
      key: last?.key ?? 'empty',
      owner: last?.owner?.text ?? '',
      zoro: last?.zoro?.text ?? '',
      language: last?.zoro?.language ?? null,
      cards: last?.zoro?.cards ?? [],
      earlier: exchanges.slice(0, -1),
      live: false,
    };
  }

  // ---------------------------------------------------------------- rendering

  function renderBanner() {
    const mode = app.security.value?.privacy_mode ?? conversation.state.turn.privacyMode ?? null;
    const local = prefs.get('alwaysPrivate') && mode !== 'strict_private';
    const key = local ? 'local' : mode === 'strict_private' ? 'strict' : mode === 'cloud_intelligence' ? 'cloud' : 'unknown';
    banner.dataset.mode = local ? 'strict_private' : mode ?? 'unknown';
    setText(bannerTitle, t(`privacy.${key}.title`));
    setText(bannerLine, t(`privacy.${key}.line`));
    replace(bannerMark, icon(key === 'cloud' ? 'cloud' : 'lock', { size: 18 }));
  }

  function renderOrb() {
    const turn = conversation.state.turn;
    const isPrivate = privateMode();
    const state = orbStateFor(turn, { listening: voice.state.listening, speaking: voice.state.speaking, privateMode: isPrivate, errorFlash });
    const agents = satellitesFor(turn);
    orb.setState(state, agents.length);
    wave.setActive(voice.state.listening || voice.state.speaking);
    setText(orbStatus, orbValue(t, { state, agents, canListen: voice.canListen, waiting: turn.phase === 'suspended' }));
    setText(orbNote, state === 'private' ? t('orb.private') : '');
    root.dataset.orb = state;
  }

  function renderStage(view) {
    const listening = voice.state.listening;
    setText(zoroText, view.zoro);
    zoroText.lang = view.language === 'hi' ? 'hi' : view.language === 'hinglish' ? 'hi-Latn' : 'en';
    if (listening) {
      ownerText.dataset.interim = 'true';
      ownerText.className = 'owner-voice';
      setText(ownerText, voice.state.interim);
    } else if (view.owner) {
      ownerText.dataset.interim = 'false';
      ownerText.className = 'owner-voice';
      setText(ownerText, view.owner);
    } else {
      ownerText.dataset.interim = 'false';
      ownerText.className = 'exchange-hint';
      setText(ownerText, t('home.empty'));
    }
    speakButton.hidden = !(app.speaker.supported && view.zoro && !isActive(conversation.state.turn) && !voice.state.speaking && !listening);
    speakButton.dataset.language = view.language ?? '';
    reconcile(
      cards,
      view.cards.map((card, index) => ({ card, key: `${view.key}|${index}|${card.kind}` })),
      (item) => item.key,
      (item) => renderCard(t, item.card),
    );
  }

  function renderNotice() {
    const { fromCache, history, historyError, messages } = conversation.state;
    if (history === 'error' && messages.length === 0) {
      replace(notice, errorView(t, historyError, { retry: () => conversation.refresh(), pair: app.repair, fallbackKey: 'home.history_error' }));
    } else if (fromCache && historyError) {
      replace(notice, stateView('disconnected', `${t('home.cached')} ${t('state.disconnected')}`, { label: t('common.reconnect'), run: () => app.reconnect() }));
    } else if (history === 'loading' && messages.length === 0) {
      replace(notice, stateView('loading', t('common.loading'), null, { plain: true }));
    } else {
      replace(notice);
    }
  }

  function agentChips(turn) {
    const rows = activityRows(turn);
    if (rows.length === 0) return null;
    return h('div.agents-line', { role: 'list', 'aria-label': t('home.working') }, rows.map((row) => h('span', { role: 'listitem' }, badge(`${agentName(row.agent)}: ${t(`agent.status.${row.status}`)}`, STATUS_TONE[row.status] ?? 'neel'))));
  }

  function renderExtras() {
    const turn = conversation.state.turn;
    const nodes = [];
    if (isActive(turn) || turn.phase === 'suspended') nodes.push(agentChips(turn));

    if (turn.phase === 'suspended' && turn.error) {
      // The last answer was refused (the request is still open): say why.
      nodes.push(stateView('error', turn.error.message || t(approvalErrorKey(turn.error)), null));
    }
    if (turn.phase === 'suspended' && turn.approval) {
      nodes.push(approvalCard(t, turn.approval, () => reviewLive(turn.approval)));
      if (!canSignApproval(turn.approval)) nodes.push(h('p.callout.callout--moon', { role: 'note' }, icon('lock', { size: 18 }), h('span', { text: t('approval.biometric.body') })));
    }
    if (turn.phase === 'suspended' && turn.deviceAction) {
      const action = turn.deviceAction;
      const plan = planDeviceAction(action);
      if (plan.kind === 'link') {
        nodes.push(
          linkBlock(t, plan, {
            text: action.tool === 'device.whatsapp.compose' ? String(action.args?.text ?? '') : '',
            onOpen: () => {
              if (!openLink(plan.url)) {
                app.toast(t('device.link.blocked'));
                return undefined;
              }
              return conversation.answerDevice(openedResult(action));
            },
            onSkip: () => conversation.answerDevice(refusedResult(action, 'user_cancelled')),
          }),
        );
        armDeviceTimer(action);
      } else {
        nodes.push(h('p.note', { text: t('device.unsupported') }));
      }
    } else {
      disarmDeviceTimer();
    }
    if (turn.phase === 'failed') {
      const view = describeTurnError(turn.error);
      const again = turn.ownerText;
      const retry = view.action === 'retry' || view.action === 'reconnect' ? () => send(again, turn.modality) : undefined;
      nodes.push(
        view.serverMessage
          ? stateView('error', view.serverMessage, retry ? { label: t('common.try_again'), run: retry } : null)
          : errorView(t, turn.error, { retry, pair: app.repair }),
      );
    }
    if (turn.phase === 'cancelled') nodes.push(h('p.note', { role: 'status', text: t('home.stopped') }));
    if (turn.phase === 'disconnected') {
      nodes.push(stateView('disconnected', t('home.interrupted'), { label: t('home.check_reply'), run: () => conversation.refresh() }));
    }
    replace(extras, nodes);
  }

  function exchangeNode(exchange) {
    return h(
      'div.exchange',
      null,
      h('div.exchange-zoro', null, h('span.visually-hidden', { text: `${t('home.zoro_said')}: ` }), h('p.zoro-voice', { text: exchange.zoro?.text ?? '' })),
      h('div.rekha', { 'aria-hidden': 'true' }),
      h('div.exchange-owner', null, h('span.visually-hidden', { text: `${t('home.you_said')}: ` }), h('p.owner-voice', { text: exchange.owner?.text ?? '' })),
      (exchange.zoro?.cards ?? []).map((card) => renderCard(t, card)),
    );
  }

  function renderEarlier(view) {
    const all = [...view.earlier].reverse(); // newest first, under the stage
    if (all.length === 0) {
      replace(earlier);
      return;
    }
    let list = earlier.querySelector('.earlier-list');
    if (!list) {
      list = h('div.earlier-list');
      replace(earlier, section(t('home.earlier'), {}, h('div.earlier', null, list), h('div.btn-row')));
    }
    reconcile(list, all.slice(0, earlierLimit), (exchange) => exchange.key, exchangeNode);
    const more = earlier.querySelector('.btn-row');
    if (all.length > earlierLimit) {
      replace(more, h('button.btn.btn--link', { type: 'button', text: t('common.load_more'), on: { click: () => { earlierLimit += EARLIER_PAGE; render(); } } }));
    } else {
      replace(more);
    }
  }

  function renderWaiting() {
    const liveId = conversation.state.turn.approval?.approval_id ?? null;
    const items = (app.pending.value ?? []).filter((approval) => approval.approval_id !== liveId);
    if (items.length === 0) {
      replace(waiting);
      return;
    }
    replace(waiting, section(t('home.waiting'), {}, items.map((approval) => approvalCard(t, approval, () => app.reviewApproval(approval)))));
  }

  function render() {
    if (!shown) return;
    const view = stageView();
    renderBanner();
    renderOrb();
    renderNotice();
    renderStage(view);
    renderExtras();
    renderWaiting();
    renderEarlier(view);
    composer.render();
  }

  // ---------------------------------------------------------------- actions

  function flashError() {
    errorFlash = true;
    clearTimeout(errorTimer);
    errorTimer = setTimeout(() => {
      errorFlash = false; // the orb shows the error once, then settles; it never stays red
      render();
    }, ERROR_FLASH_MS);
  }

  function send(text, modality = 'text') {
    app.speaker.prime();
    voice.clearProblem();
    earlierLimit = EARLIER_PAGE;
    scroll.scrollTo({ top: 0, behavior: app.reduceMotion() ? 'auto' : 'smooth' });
    return conversation.send(text, { modality });
  }

  async function reviewLive(approval) {
    const choice = await app.openApprovalSheet(approval);
    if (choice === 'later') return;
    if (conversation.state.turn.approval?.approval_id !== approval.approval_id) {
      app.toast(t('approval.error.gone'));
      return;
    }
    if (choice === 'cancel_request') {
      await conversation.cancel();
      app.toast(t('approval.biometric.cancelled'));
      return;
    }
    const approved = choice === 'approve';
    try {
      await conversation.decide(approved);
      app.toast(t(approved ? 'approval.approved' : 'approval.declined'));
    } catch (error) {
      app.toast(t(approvalErrorKey(error)));
    }
    app.pending.refresh();
  }

  function armDeviceTimer(action) {
    if (deviceTimerFor === action.action_id) return;
    disarmDeviceTimer();
    const wait = new Date(action.expires_at).getTime() - Date.now();
    if (!Number.isFinite(wait)) return;
    deviceTimerFor = action.action_id;
    deviceTimer = setTimeout(() => {
      if (conversation.state.turn.deviceAction?.action_id !== action.action_id) return;
      app.toast(t('device.link.expired'));
      conversation.answerDevice(refusedResult(action, 'expired'));
    }, Math.max(0, wait));
  }

  function disarmDeviceTimer() {
    clearTimeout(deviceTimer);
    deviceTimerFor = null;
  }

  // ---------------------------------------------------------------- events

  orbButton.addEventListener('click', () => {
    if (voice.state.listening) voice.finishListening();
    else composer.talk(() => voice.startListening());
  });

  speakButton.addEventListener('click', () => {
    const language = speakButton.dataset.language || null;
    if (!app.speaker.say(zoroText.textContent, language)) app.toast(t('settings.voice.none'));
  });

  onAction(newButton, async () => {
    app.speaker.stop();
    await conversation.startNew();
    app.toast(t('home.new_done'));
    composer.focus();
  });

  const unsubscribe = [
    conversation.subscribe((_state, change) => {
      if (change.type === 'turn_end' && change.outcome === 'failed') flashError();
      if (change.type === 'event' && change.event.type === 'error' && change.event.code !== 'cancelled') flashError();
      if (change.type === 'turn_waiting' && change.reason === 'approval') {
        const approval = conversation.state.turn.approval;
        if (approval && shown && sheetFor !== approval.approval_id) {
          sheetFor = approval.approval_id;
          reviewLive(approval);
        }
      }
      render();
    }),
    app.security.subscribe(render),
    app.pending.subscribe(render),
    prefs.subscribe(render),
    app.onVoice(render),
  ];

  return {
    root,
    title: () => t('home.title'),
    show() {
      shown = true;
      orb.motionChanged();
      render();
      const approval = conversation.state.turn.approval;
      if (conversation.state.turn.phase === 'suspended' && approval && sheetFor !== approval.approval_id) {
        sheetFor = approval.approval_id;
        reviewLive(approval);
      }
    },
    hide() {
      shown = false;
      voice.cancelListening();
    },
    motionChanged() {
      orb.motionChanged();
    },
    focusComposer() {
      composer.focus();
    },
    destroy() {
      for (const off of unsubscribe) off();
      clearTimeout(errorTimer);
      disarmDeviceTimer();
      orb.destroy();
      wave.destroy();
    },
  };
}
