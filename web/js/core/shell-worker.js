// Registers the service worker that keeps the app shell (see sw.js) and reports updates.
//
// A new version installs next to the running one and waits. The page reloads only when the
// owner asks for it: the first install also changes the controller, and must never throw away
// what is on screen.

/** @param {{onUpdateReady: (activate: () => void) => void,
 *   container?: ServiceWorkerContainer, reload?: () => void}} options
 * @returns {Promise<{checkForUpdate: () => Promise<'updated' | 'current' | 'no_worker'>}>} */
export async function registerShellWorker({
  onUpdateReady,
  container = globalThis.navigator?.serviceWorker,
  reload = () => globalThis.location.reload(),
}) {
  const none = { checkForUpdate: async () => 'no_worker' };
  if (!container) return none;
  let registration;
  let reloadAsked = false;
  try {
    registration = await container.register('./sw.js', { scope: './' });
  } catch {
    return none; // the app works without it; it just needs the network to open
  }
  const offer = (worker) =>
    onUpdateReady(() => {
      reloadAsked = true;
      worker.postMessage({ type: 'skip-waiting' });
    });
  const watch = (worker) => {
    worker?.addEventListener('statechange', () => {
      if (worker.state === 'installed' && container.controller) offer(worker);
    });
  };
  if (registration.waiting && container.controller) offer(registration.waiting);
  watch(registration.installing);
  registration.addEventListener('updatefound', () => watch(registration.installing));
  container.addEventListener('controllerchange', () => {
    if (!reloadAsked) return;
    reloadAsked = false;
    reload();
  });
  return {
    async checkForUpdate() {
      try {
        await registration.update();
      } catch {
        return 'current';
      }
      return registration.installing || registration.waiting ? 'updated' : 'current';
    },
  };
}
