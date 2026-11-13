// ZORO for Safari: composition root. Wires identity, the API client, the conversation, voice and
// the screens; owns navigation, the device channel and the service worker. No framework, no
// build step: this file is loaded as an ES module by index.html.

import { ApiError, ZoroClient } from './core/api.js';
import { DeviceChannel } from './core/channel.js';
import { Conversation } from './core/conversation.js';
import { approvalErrorKey, describeError } from './core/errors.js';
import { DeviceIdentity } from './core/identity.js';
import { APP_VERSION } from './core/pairing.js';
import { Prefs, shouldReduceMotion } from './core/prefs.js';
import { Resource } from './core/resource.js';
import { SealedCache } from './core/sealed-cache.js';
import { registerShellWorker } from './core/shell-worker.js';
import { openStores } from './core/store.js';
import { createI18n, preferredLanguage } from './i18n/index.js';
import { createActivity } from './screens/activity.js';
import { createHome } from './screens/home.js';
import { codeFromHash, createPairing } from './screens/pairing.js';
import { createSpaces } from './screens/spaces.js';
import { createYou } from './screens/you.js';
import { openApprovalSheet } from './ui/approval.js';
import { createToaster } from './ui/components.js';
import { offerLinkSheet } from './ui/link-sheet.js';
import { h, replace } from './ui/dom.js';
import { icon } from './ui/icons.js';
import { LevelMeter, MicLevels, sharesMicrophone } from './voice/levels.js';
import { Recognizer } from './voice/recognizer.js';
import { Speaker } from './voice/speaker.js';
import { VoiceSession } from './voice/voice-session.js';

const TABS = [
  { route: '', key: 'tab.zoro', glyph: 'orb' },
  { route: 'spaces', key: 'tab.spaces', glyph: 'spaces' },
  { route: 'activity', key: 'tab.activity', glyph: 'activity' },
  { route: 'you', key: 'tab.you', glyph: 'you' },
];

function parseRoute(hash) {
  const path = String(hash || '').replace(/^#\/?/, '').split(/[?&]/)[0];
  const [top = '', sub = ''] = path.split('/');
  return TABS.some((tab) => tab.route === top) ? { top, sub } : { top: '', sub: '' };
}

async function boot() {
  const shell = document.getElementById('app');
  const main = document.getElementById('main');
  const tabbar = document.getElementById('tabbar');
  const toast = createToaster(document.getElementById('toasts'));
  document.getElementById('boot-note')?.remove();

  // ---------------------------------------------------------------- preferences and language

  const prefs = new Prefs();
  let hadPrefs = false;
  try {
    hadPrefs = globalThis.localStorage?.getItem('zoro.prefs.v1') != null;
  } catch {
    hadPrefs = false;
  }
  if (!hadPrefs) {
    const lang = preferredLanguage();
    prefs.set({ lang, listenLang: lang === 'hi' ? 'hi-IN' : 'en-IN' });
  }
  const t = createI18n(prefs.get('lang'));
  document.documentElement.lang = t.lang;

  const motionQuery = globalThis.matchMedia?.('(prefers-reduced-motion: reduce)') ?? null;
  const reduceMotion = () => shouldReduceMotion(prefs.get('reduceMotion'), Boolean(motionQuery?.matches));
  const applyMotion = () => {
    const pref = prefs.get('reduceMotion');
    if (pref === 'system') delete document.documentElement.dataset.motion;
    else document.documentElement.dataset.motion = pref === 'on' ? 'reduce' : 'full';
  };
  applyMotion();

  // ---------------------------------------------------------------- viewport and keyboard

  const viewport = globalThis.visualViewport;
  const fitViewport = () => {
    if (!viewport) return;
    document.documentElement.style.setProperty('--vvh', `${viewport.height}px`);
    document.documentElement.style.setProperty('--vvt', `${viewport.offsetTop}px`);
    shell.dataset.keyboard = globalThis.innerHeight - viewport.height > 140 ? 'open' : 'closed';
  };
  viewport?.addEventListener('resize', fitViewport);
  viewport?.addEventListener('scroll', fitViewport);
  fitViewport();

  // ---------------------------------------------------------------- identity, client, conversation

  const secure = Boolean(globalThis.isSecureContext && globalThis.crypto?.subtle);
  const stores = await openStores();
  const identity = secure ? new DeviceIdentity({ store: stores.identity }) : { load: async () => null, isPaired: async () => false, describe: async () => null, forget: async () => {} };
  const cache = secure ? new SealedCache({ keyStore: stores.identity, cacheStore: stores.cache }) : null;
  const client = new ZoroClient({ baseUrl: globalThis.location.origin, identity });
  const conversation = new Conversation({
    client,
    identity,
    cache,
    context: () => ({
      locale: t.lang === 'hi' ? 'hi-IN' : 'en-IN',
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Kolkata',
      languageHint: prefs.get('replyLanguage') === 'auto' ? null : prefs.get('replyLanguage'),
      responseLength: prefs.get('responseLength'),
      forcePrivate: prefs.get('alwaysPrivate'),
    }),
  });

  // ---------------------------------------------------------------- voice

  const ownerLevel = new LevelMeter();
  const zoroLevel = new LevelMeter();
  const voiceListeners = new Set();
  let voice = null;
  const speaker = new Speaker({ prefs, onChange: (speaking) => voice?.speakingChanged(speaking), onPulse: () => voice?.spokenPulse() });
  voice = new VoiceSession({
    recognizer: new Recognizer(),
    speaker,
    conversation,
    prefs,
    ownerLevel,
    zoroLevel,
    mic: new MicLevels(),
    useMic: !sharesMicrophone(),
    onChange: () => {
      for (const listener of [...voiceListeners]) listener();
    },
  });

  // ---------------------------------------------------------------- data shown by the screens

  const app = {
    t,
    prefs,
    client,
    identity,
    conversation,
    voice,
    speaker,
    ownerLevel,
    zoroLevel,
    toast,
    secure,
    storagePersistent: stores.persistent,
    version: APP_VERSION,
    reduceMotion,
    prefilledCode: codeFromHash(globalThis.location.hash),
    deviceId: null,
    pairing: null,
    financePeriod: 'this_month',
    onVoice(listener) {
      voiceListeners.add(listener);
      return () => voiceListeners.delete(listener);
    },
    security: new Resource(() => client.securityState()),
    pending: new Resource(async () => (await client.pendingApprovals()).items ?? []),
    conversations: new Resource(() => client.conversations({ limit: 30 })),
    basket: new Resource(() => client.basket()),
    finance: new Resource(() => client.financeSummary(app.financePeriod)),
    memory: new Resource(() => client.memories({ limit: 50 })),
    audit: new Resource(() => client.json('GET', '/v1/security/audit', { query: { limit: 30 } })),
    health: new Resource(() => client.health()),
    navigate(route) {
      globalThis.location.hash = `#/${route}`;
    },
    toastError(error) {
      toast(t(describeError(error).key));
    },
    openApprovalSheet: (approval) => openApprovalSheet(t, approval),
  };

  app.loadMoreConversations = async () => {
    const current = app.conversations.value;
    if (!current?.next_cursor) return;
    try {
      const page = await client.conversations({ cursor: current.next_cursor, limit: 30 });
      app.conversations.set({ items: [...current.items, ...page.items], next_cursor: page.next_cursor });
    } catch (error) {
      app.toastError(error);
    }
  };

  app.loadMoreMemory = async () => {
    const current = app.memory.value;
    if (!current?.next_cursor) return;
    try {
      const page = await client.memories({ cursor: current.next_cursor, limit: 50 });
      app.memory.set({ items: [...current.items, ...page.items], next_cursor: page.next_cursor });
    } catch (error) {
      app.toastError(error);
    }
  };

  /** Answer an approval that is not the live turn's (from the pending list or the channel). */
  app.reviewApproval = async (approval) => {
    const choice = await openApprovalSheet(t, approval);
    if (choice === 'later') return;
    try {
      if (choice === 'cancel_request') {
        if (approval.turn_id) await client.cancelTurn(approval.turn_id);
        toast(t('approval.biometric.cancelled'));
      } else {
        await conversation.decidePending(approval, choice === 'approve');
        toast(t(choice === 'approve' ? 'approval.approved' : 'approval.declined'));
      }
    } catch (error) {
      toast(t(approvalErrorKey(error)));
    }
    app.pending.refresh();
  };

  // ---------------------------------------------------------------- device channel

  const channel = new DeviceChannel({
    client,
    onApproval: (approval) => {
      const items = app.pending.value ?? [];
      if (!items.some((item) => item.approval_id === approval.approval_id)) app.pending.set([...items, approval]);
    },
    onDeviceAction: (action) => {
      // The live turn's own action arrives on its event stream; only others are offered here.
      if (conversation.state.turn.deviceAction?.action_id === action.action_id) return;
      offerLinkSheet(t, action, { send: (result) => channel.sendResult(result), toast, onError: app.toastError });
    },
    onStatus: () => {
      if (channel.status === 'online') app.security.refresh();
    },
  });
  app.channel = channel;

  // ---------------------------------------------------------------- screens and navigation

  let screens = null;
  let pairingScreen = null;
  let current = null;
  let paired = false;

  function buildTabs(route) {
    replace(
      tabbar,
      TABS.map((tab) => h('a.tab', { href: `#/${tab.route}`, 'aria-current': tab.route === route.top ? 'page' : null }, icon(tab.glyph, { size: 24 }), h('span', { text: t(tab.key) }))),
    );
    tabbar.setAttribute('aria-label', t('nav.sections'));
  }

  function buildScreens() {
    for (const screen of Object.values(screens ?? {})) {
      screen.hide?.();
      screen.destroy?.();
      screen.root.remove();
    }
    screens = { '': createHome(app), spaces: createSpaces(app), activity: createActivity(app), you: createYou(app) };
    for (const screen of Object.values(screens)) {
      screen.root.hidden = true;
      main.append(screen.root);
    }
    current = null;
    document.querySelector('.skip').textContent = t('app.skip');
  }

  function showRoute({ focus = true } = {}) {
    if (!paired) return;
    const route = parseRoute(globalThis.location.hash);
    const next = screens[route.top];
    if (current && current !== next) {
      current.hide?.();
      current.root.hidden = true;
    }
    next.root.hidden = false;
    next.show?.(route.sub);
    const changed = current !== next;
    current = next;
    buildTabs(route);
    document.title = route.top === '' ? t('app.name') : `${next.title()} – ${t('app.name')}`;
    if (changed && focus) main.focus({ preventScroll: true });
  }

  function showPairing(step = 'welcome') {
    paired = false;
    channel.stop();
    for (const screen of Object.values(screens ?? {})) {
      screen.hide?.();
      screen.root.hidden = true;
    }
    current = null;
    shell.dataset.chrome = 'none';
    pairingScreen?.root.remove();
    pairingScreen = createPairing(app, { onPaired: enter });
    main.append(pairingScreen.root);
    pairingScreen.show(step);
    document.title = t('app.name');
  }

  async function enter() {
    const facts = await identity.describe();
    if (!facts) {
      showPairing();
      return;
    }
    if (!prefs.get('introduced')) {
      showPairing('intro');
      return;
    }
    pairingScreen?.hide();
    pairingScreen?.root.remove();
    pairingScreen = null;
    app.deviceId = facts.deviceId;
    app.pairing = facts;
    app.prefilledCode = '';
    paired = true;
    delete shell.dataset.chrome;
    if (!screens) buildScreens();
    if (/[#&]pair=/.test(globalThis.location.hash)) history.replaceState(null, '', '#/');
    showRoute({ focus: false });
    await conversation.restore();
    connect();
  }

  /** Load what the screens need and open the channel. Also the "Reconnect" action. */
  async function connect() {
    if (!paired) return;
    const ok = await conversation.refresh();
    app.security.refresh();
    app.pending.refresh();
    if (ok && !document.hidden) channel.start();
    const failure = conversation.state.historyError;
    if (failure instanceof ApiError && failure.code === 'device_revoked') toast(t('state.revoked'), { action: { label: t('state.pair_again'), run: app.repair }, ms: 0 });
  }
  app.reconnect = connect;

  /** The server no longer accepts this browser: pair again. The old key stays until a new
   * pairing replaces it. */
  app.repair = () => showPairing('connect');

  app.forgetPairing = async () => {
    channel.stop();
    speaker.stop();
    voice.cancelListening();
    await conversation.forgetLocal();
    await cache?.destroy();
    await identity.forget();
    client.signOut();
    for (const resource of [app.security, app.pending, app.conversations, app.basket, app.finance, app.memory, app.audit, app.health]) resource.reset();
    prefs.reset();
    globalThis.location.hash = '#/';
    showPairing();
  };

  globalThis.addEventListener('hashchange', () => showRoute());

  prefs.subscribe((_all, changed) => {
    if (changed.includes('reduceMotion')) {
      applyMotion();
      screens?.['']?.motionChanged?.();
    }
    if (changed.includes('lang') && prefs.get('lang') !== t.lang) {
      t.setLang(prefs.get('lang'));
      document.documentElement.lang = t.lang;
      if (paired) {
        buildScreens();
        showRoute({ focus: false });
      }
    }
  });
  motionQuery?.addEventListener?.('change', () => screens?.['']?.motionChanged?.());

  // The app is only "there" while it is on screen: no background listening, no background channel.
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      voice.cancelListening();
      channel.stop();
      return;
    }
    if (!paired) return;
    channel.start();
    app.pending.refresh();
    const phase = conversation.state.turn.phase;
    if (phase === 'disconnected' || phase === 'suspended' || phase === 'idle' || phase === 'completed') conversation.refresh();
  });
  globalThis.addEventListener('online', () => connect());
  globalThis.addEventListener('pagehide', () => speaker.stop());

  // ---------------------------------------------------------------- service worker (app shell only)

  const worker = secure
    ? await registerShellWorker({ onUpdateReady: (activate) => toast(t('update.ready'), { ms: 0, action: { label: t('update.reload'), run: activate } }) })
    : { checkForUpdate: async () => 'no_worker' };
  app.checkForUpdate = worker.checkForUpdate;

  document.querySelector('.skip').addEventListener('click', (event) => {
    event.preventDefault(); // the address fragment is the router's; just move focus
    main.focus();
  });

  await enter();
  document.documentElement.dataset.ready = 'true';
}

boot().catch((error) => {
  const note = document.getElementById('boot-error');
  if (note) {
    note.hidden = false;
    note.textContent = `ZORO could not start in this browser (${error?.name ?? 'error'}). Update the browser, or open ZORO in Safari.`;
  }
});
