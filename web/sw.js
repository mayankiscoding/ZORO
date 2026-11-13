// ZORO service worker: keeps the app shell so the app opens without a connection.
//
// It caches only the files listed below (HTML, CSS, scripts, icons, manifest). It never caches,
// stores or even handles an API request: anything outside the shell list goes straight to the
// network untouched, so answers, tokens and personal data never enter a browser cache.
//
// Updates are versioned. A new worker installs next to the old one and waits; the page shows
// "A new version is ready" and the owner chooses when to reload. `node tools/stamp-shell.mjs`
// rewrites the two marked lines below whenever a shell file changes (a test checks it).

/* shell:begin */
const SHELL_VERSION = '8e1d37c6898b70c8';
const SHELL_FILES = [
  'css/app.css',
  'css/tokens.css',
  'icons/apple-touch-icon.png',
  'icons/icon-192.png',
  'icons/icon-512.png',
  'icons/icon-maskable-192.png',
  'icons/icon-maskable-512.png',
  'icons/icon-maskable.svg',
  'icons/icon.svg',
  'index.html',
  'js/app.js',
  'js/core/api.js',
  'js/core/bytes.js',
  'js/core/channel.js',
  'js/core/conversation.js',
  'js/core/der.js',
  'js/core/device-actions.js',
  'js/core/errors.js',
  'js/core/format.js',
  'js/core/identity.js',
  'js/core/messages.js',
  'js/core/pairing.js',
  'js/core/prefs.js',
  'js/core/resource.js',
  'js/core/sealed-cache.js',
  'js/core/shell-worker.js',
  'js/core/signing.js',
  'js/core/sse.js',
  'js/core/store.js',
  'js/core/turn-reducer.js',
  'js/i18n/en.js',
  'js/i18n/hi.js',
  'js/i18n/index.js',
  'js/screens/activity.js',
  'js/screens/home-composer.js',
  'js/screens/home.js',
  'js/screens/pairing.js',
  'js/screens/spaces.js',
  'js/screens/you.js',
  'js/ui/approval.js',
  'js/ui/cards.js',
  'js/ui/components.js',
  'js/ui/dom.js',
  'js/ui/icons.js',
  'js/ui/link-sheet.js',
  'js/ui/orb-params.js',
  'js/ui/orb.js',
  'js/ui/rekha.js',
  'js/voice/levels.js',
  'js/voice/recognizer.js',
  'js/voice/sentences.js',
  'js/voice/speaker.js',
  'js/voice/voice-session.js',
  'manifest.webmanifest',
];
/* shell:end */

const CACHE_PREFIX = 'zoro-shell-';
const CACHE_NAME = `${CACHE_PREFIX}${SHELL_VERSION}`;
const SCOPE = new URL('./', self.location.href);
const SHELL_URLS = new Set(SHELL_FILES.map((file) => new URL(file, SCOPE).href));
const INDEX_URL = new URL('index.html', SCOPE).href;

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      // `reload` bypasses the HTTP cache, so a new version never precaches stale files.
      cache.addAll(SHELL_FILES.map((file) => new Request(new URL(file, SCOPE).href, { cache: 'reload', credentials: 'omit' }))),
    ),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) => Promise.all(names.filter((name) => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME).map((name) => caches.delete(name))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'skip-waiting') self.skipWaiting();
});

/** The cached shell file for a request, or null when the request is not a shell file. */
function shellKey(request) {
  if (request.method !== 'GET') return null;
  const url = new URL(request.url);
  if (url.origin !== SCOPE.origin || !url.pathname.startsWith(SCOPE.pathname)) return null;
  url.hash = '';
  url.search = '';
  if (request.mode === 'navigate' && (url.href === SCOPE.href || url.href === INDEX_URL)) return INDEX_URL;
  return SHELL_URLS.has(url.href) ? url.href : null;
}

self.addEventListener('fetch', (event) => {
  const key = shellKey(event.request);
  if (!key) return; // not ours: the browser handles it as if there were no service worker
  event.respondWith(
    caches.open(CACHE_NAME).then(async (cache) => {
      const cached = await cache.match(key);
      if (cached) return cached;
      // Missing from the cache (it was evicted): fetch it, and keep it only if it is a shell file.
      const response = await fetch(event.request);
      if (response.ok && response.type === 'basic') cache.put(key, response.clone());
      return response;
    }),
  );
});
