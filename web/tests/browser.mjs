// Browser test: the real web app in headless Chrome against the real backend.
//
//   node web/tests/browser.mjs [--shots <dir>]
//
// It starts the backend (temporary SQLite database), serves web/ at /app/ on the same origin
// (web/tools/serve.mjs), opens the app in the Chrome already installed on this machine, and
// drives it like an owner would: pair with a code from the backend CLI, ask something, approve
// a request, open a link. It then checks what a unit test cannot: the Content-Security-Policy
// is not violated, the key in IndexedDB is non-extractable, nothing sensitive is in
// localStorage, the service worker cached only the shell, the layout does not overflow from
// 320 to 430 points or on a desktop, and how much the transcript shifts while a reply arrives.
//
// Chrome is not Safari: this proves the app's logic and layout in a real browser engine, not
// its behaviour on an iPhone. It is skipped (exit 0, saying so) when no Chrome is installed.

import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createWebServer } from '../tools/serve.mjs';
import { backendAvailable, startBackend } from './helpers/backend.mjs';
import { findChrome, launchChrome } from './helpers/cdp.mjs';

const shotsArg = process.argv.indexOf('--shots');
const SHOTS = shotsArg > 0 ? process.argv[shotsArg + 1] : join(tmpdir(), 'zoro-web-shots');
const results = [];

async function step(name, run) {
  const started = Date.now();
  try {
    const note = await run();
    results.push({ name, ok: true, note: note ?? '' });
    console.log(`ok    ${name} (${Date.now() - started} ms)${note ? `  ${note}` : ''}`);
  } catch (error) {
    results.push({ name, ok: false, note: error.message });
    console.log(`FAIL  ${name}: ${error.message}`);
    throw error;
  }
}

/** Type into the composer and press Return. If Chrome does not acknowledge the key event and
 * the text is still in the box, the form is submitted directly so the run can go on. */
async function ask(page, text) {
  await page.type('.composer textarea', text);
  const pressed = await page.key('Enter');
  if (!pressed) {
    await new Promise((done) => setTimeout(done, 300));
    const stillThere = await page.eval("document.querySelector('.composer textarea').value.length > 0");
    if (stillThere) await page.eval("document.querySelector('.composer').requestSubmit()");
    console.log(`note  Chrome did not acknowledge the Return key; ${stillThere ? 'the form was submitted directly' : 'the message had been sent'}`);
  }
}

const overflow = `(() => {
  const width = document.documentElement.clientWidth;
  const wide = [];
  for (const el of document.querySelectorAll('body *')) {
    if (el.closest('.table-wrap') || el.closest('[hidden]')) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (r.right > width + 0.5 || r.left < -0.5) wide.push(el.tagName.toLowerCase() + '.' + String(el.className).split(' ')[0] + ' ' + Math.round(r.left) + '..' + Math.round(r.right));
  }
  return { width, scrollWidth: document.documentElement.scrollWidth, wide: wide.slice(0, 6) };
})()`;

async function main() {
  if (!findChrome()) {
    console.log('SKIPPED: no Chrome, Chromium or Edge is installed on this machine.');
    return 0;
  }
  if (!backendAvailable()) {
    console.log('SKIPPED: the backend virtualenv is not present.');
    return 0;
  }
  await mkdir(SHOTS, { recursive: true });
  const shot = (page, name) => page.screenshot(join(SHOTS, `${name}.png`));
  let failed = false;
  let backend = null;
  let web = null;
  let chrome = null;
  let pageRef = null;
  try {
    backend = await startBackend();
    console.log(`backend: ${backend.baseUrl}`);
    web = await createWebServer({ backend: backend.baseUrl, port: 0 });
    console.log(`web app: ${web.url}`);
    chrome = await launchChrome();
    const page = await chrome.newPage();
    pageRef = page;
    console.log('browser: headless Chrome started');
    await page.viewport({ width: 390, height: 844, scale: 3 });
    await page.media({ 'prefers-color-scheme': 'light' }); // the machine's own setting must not decide
    // Links are not really opened in the test: record what the app hands to the browser.
    await page.cmd('Page.addScriptToEvaluateOnNewDocument', { source: 'window.__opened = []; window.open = (url, target, features) => { window.__opened.push({ url, target, features }); return null; };' });

    await step('the shell boots without a Content-Security-Policy violation', async () => {
      await page.goto(web.url);
      await page.until("document.documentElement.dataset.ready === 'true'", { what: 'app ready' });
      await page.until("document.querySelector('.welcome h1')?.textContent === 'ZORO'");
      assert.deepEqual(page.problems, []);
      assert.equal(await page.eval('window.isSecureContext'), true);
      await shot(page, '01-welcome-light');
    });

    await step('pairing: a wrong code is explained, the right one connects', async () => {
      await page.tap('button', 'Get started');
      await page.until("!!document.querySelector('#pair-code')");
      await shot(page, '02-connect');
      await page.type('#pair-code', 'ZZZZ9999');
      await page.tap('button[type=submit]');
      await page.until("document.querySelector('.field-error:not([hidden])')?.textContent.length > 0");
      const wrong = await page.eval("document.querySelector('.field-error').textContent");
      assert.match(wrong, /didn't match or has expired/);
      await shot(page, '03-connect-error');
      await page.eval("document.querySelector('#pair-code').value = ''");
      await page.type('#pair-code', (await backend.pairingCode()).toLowerCase());
      assert.match(await page.eval("document.querySelector('#pair-code').value"), /^[A-Z0-9]{4}-[A-Z0-9]{4}$/);
      await page.tap('button[type=submit]');
      await page.until("document.querySelector('h1')?.textContent === 'Language and voice'", { what: 'first-run step' });
      await shot(page, '04-intro');
      await page.tap('button', 'Start using ZORO');
      await page.until("!!document.querySelector('.orb-btn') && !document.querySelector('.home').hidden");
      await page.until("document.querySelector('.banner-title')?.textContent === 'Private mode'", { what: 'privacy banner from the server' });
      // The pairing failure above answered 400, which Chrome logs as a console error; nothing else may.
      const unexpected = page.problems.filter((text) => !/\/v1\/auth\/pair/.test(text) && !/status of 4(00|22)/.test(text));
      assert.deepEqual(unexpected, []);
      await shot(page, '05-home-private-light');
      return `orb state: ${await page.eval("document.querySelector('.home').dataset.orb")}`;
    });

    await step('identity at rest: non-extractable key in IndexedDB, nothing sensitive in localStorage', async () => {
      const facts = await page.eval(`new Promise((done, fail) => {
        const open = indexedDB.open('zoro-web');
        open.onerror = () => fail(open.error);
        open.onsuccess = () => {
          const db = open.result;
          const tx = db.transaction(['identity', 'cache'], 'readonly');
          const record = tx.objectStore('identity').get('device');
          const keys = tx.objectStore('identity').getAllKeys();
          const cacheKeys = tx.objectStore('cache').getAllKeys();
          tx.oncomplete = async () => {
            const key = record.result.authPrivateKey;
            let exported = 'refused';
            try { await crypto.subtle.exportKey('jwk', key); exported = 'EXPORTED'; } catch { exported = 'refused'; }
            done({
              isCryptoKey: key instanceof CryptoKey, extractable: key.extractable, type: key.type, exported,
              recordKeys: Object.keys(record.result).sort(), identityKeys: keys.result, cacheKeys: cacheKeys.result,
              platform: record.result.platform,
              local: Object.fromEntries(Object.keys(localStorage).map((k) => [k, localStorage.getItem(k)])),
              session: Object.keys(sessionStorage), cookies: document.cookie,
            });
          };
        };
      })`);
      assert.equal(facts.isCryptoKey, true);
      assert.equal(facts.extractable, false);
      assert.equal(facts.type, 'private');
      assert.equal(facts.exported, 'refused');
      assert.ok(!facts.recordKeys.includes('approvalPrivateKey'));
      assert.deepEqual(Object.keys(facts.local), ['zoro.prefs.v1']);
      assert.ok(!/token|dev_|nonce|signature|conv_/.test(JSON.stringify(facts.local)));
      assert.deepEqual(facts.session, []);
      assert.equal(facts.cookies, '');
      return `registered as "${facts.platform}"`;
    });

    await step('a typed turn streams to completion on the rekha', async () => {
      await page.eval(`(() => { window.__cls = 0; new PerformanceObserver((list) => { for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.__cls += entry.value; }).observe({ type: 'layout-shift', buffered: false }); })()`);
      await ask(page, 'remember that my favourite tea is masala chai');
      await page.until("document.querySelector('.exchange--live .zoro-voice').textContent.length > 0", { what: 'reply text' });
      const reply = await page.eval("document.querySelector('.exchange--live .zoro-voice').textContent");
      const owner = await page.eval("document.querySelector('.exchange--live .owner-voice').textContent");
      assert.equal(owner, 'remember that my favourite tea is masala chai');
      assert.match(reply, /Saved/);
      await page.until("document.querySelector('.turn-cards [data-card-kind=memory]') !== null", { what: 'memory card' });
      await page.until("document.querySelector('.composer-btn').dataset.mode !== 'stop'");
      const fonts = await page.eval("({ zoro: getComputedStyle(document.querySelector('.exchange--live .zoro-voice')).fontFamily, owner: getComputedStyle(document.querySelector('.exchange--live .owner-voice')).fontFamily })");
      assert.match(fonts.zoro, /ui-serif/);
      assert.match(fonts.owner, /^system-ui/); // the owner's words are never set in the serif
      assert.doesNotMatch(fonts.owner, /ui-serif|New York/);
      await shot(page, '06-home-reply-light');
      const cls = await page.eval('window.__cls');
      return `reply "${reply}", layout shift during the turn: ${cls.toFixed(4)}`;
    });

    await step('approval round trip: the sheet shows the exact content, Approve signs, the link is offered', async () => {
      await ask(page, 'send a WhatsApp message to +919876543210 saying on my way');
      await page.until("!!document.querySelector('dialog.sheet[open] .approval')", { what: 'approval sheet' });
      const sheet = await page.eval(`(() => {
        const d = document.querySelector('dialog.sheet[open]');
        return { text: d.textContent, facts: [...d.querySelectorAll('.approval > .facts .fact')].map((f) => [f.querySelector('dt').textContent, f.querySelector('dd').textContent]),
          buttons: [...d.querySelectorAll('button')].map((b) => b.textContent), modal: d.matches(':modal'), labelled: !!document.getElementById(d.getAttribute('aria-labelledby')) };
      })()`);
      assert.ok(sheet.modal && sheet.labelled);
      assert.ok(sheet.facts.some(([label, value]) => label === 'Message' && value === 'On my way'), JSON.stringify(sheet.facts));
      assert.ok(sheet.facts.some(([, value]) => value.includes('919876543210')));
      assert.deepEqual(sheet.buttons, ['Approve', 'Decline', 'Decide later']);
      assert.match(sheet.text, /High risk/);
      assert.match(sheet.text, /Expires in \d:\d\d/);
      await new Promise((done) => setTimeout(done, 700)); // let the sheet settle before the picture
      await shot(page, '07-approval-sheet-light');
      await page.tap('dialog.sheet[open] button', 'Approve');
      await page.until("!!document.querySelector('[data-device-action]')", { what: 'link block' });
      const link = await page.eval("document.querySelector('[data-device-action] .link-box').textContent");
      assert.match(link, /^wa\.mehttps:\/\/wa\.me\/919876543210\?text=On%20my%20way$/);
      assert.deepEqual(await page.eval('window.__opened'), []); // nothing opens without a tap
      await shot(page, '08-link-block-light');
      await page.tap('[data-device-action] button', 'Open WhatsApp');
      await page.until("document.querySelector('.exchange--live .zoro-voice').textContent.includes('WhatsApp')", { what: 'final reply' });
      const opened = await page.eval('window.__opened');
      assert.deepEqual(opened, [{ url: 'https://wa.me/919876543210?text=On%20my%20way', target: '_blank', features: 'noopener,noreferrer' }]);
      await page.until("document.querySelector('.composer-btn').dataset.mode !== 'stop'");
      return `reply "${await page.eval("document.querySelector('.exchange--live .zoro-voice').textContent")}"`;
    });

    await step('service worker: installed, caches only the shell, never an API response', async () => {
      await page.until("navigator.serviceWorker.getRegistration().then((r) => !!(r && r.active))", { what: 'active service worker', timeout: 20_000 });
      const caches = await page.eval(`(async () => {
        const out = {};
        for (const name of await caches.keys()) out[name] = (await (await caches.open(name)).keys()).map((r) => new URL(r.url).pathname);
        return out;
      })()`);
      const names = Object.keys(caches);
      assert.equal(names.length, 1);
      assert.match(names[0], /^zoro-shell-[0-9a-f]{16}$/);
      const paths = caches[names[0]];
      assert.ok(paths.length >= 45, `${paths.length} files cached`);
      assert.ok(paths.every((path) => path.startsWith('/app/')), 'everything cached is under /app/');
      assert.ok(!paths.some((path) => /\/v1\/|healthz|\/mcp\//.test(path)), 'no API path is cached');
      const api = page.requests.filter((request) => new URL(request.url).pathname.startsWith('/v1/'));
      assert.ok(api.length >= 8, 'the page did talk to the API');
      const origins = [...new Set(page.requests.map((request) => new URL(request.url).origin))];
      assert.deepEqual(origins, [new URL(web.url).origin]); // no third-party request of any kind
      return `${paths.length} shell files cached, ${api.length} API requests, none cached`;
    });

    await step('the app opens offline from the service worker and says the server is unreachable', async () => {
      await page.cmd('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
      await page.cmd('Page.reload');
      await page.until("document.documentElement.dataset.ready === 'true' && !!document.querySelector('.orb-btn')", { what: 'offline boot', timeout: 20_000 });
      await page.until("!!document.querySelector('.state--disconnected')", { what: 'disconnected state' });
      const text = await page.eval("document.querySelector('.state--disconnected').textContent");
      assert.match(text, /server|offline/i);
      // The sealed cache still shows the last conversation.
      assert.match(await page.eval("document.querySelector('.exchange--live .zoro-voice').textContent"), /WhatsApp/);
      await shot(page, '09-home-offline-light');
      await page.cmd('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
      await page.tap('.state--disconnected button');
      await page.until("!document.querySelector('.state--disconnected')", { what: 'reconnected' });
      return text.trim();
    });

    await step('every tab renders its states; no horizontal overflow at 320, 375, 390, 430 and 1280', async () => {
      const routes = ['#/', '#/spaces', '#/activity', '#/you', '#/you/memory', '#/you/security', '#/you/settings', '#/you/about'];
      const sizes = [
        { width: 320, height: 568, scale: 2, mobile: true },
        { width: 375, height: 667, scale: 2, mobile: true },
        { width: 390, height: 844, scale: 3, mobile: true },
        { width: 430, height: 932, scale: 3, mobile: true },
        { width: 1280, height: 800, scale: 1, mobile: false },
      ];
      for (const size of sizes) {
        await page.viewport(size);
        for (const route of routes) {
          await page.eval(`location.hash = ${JSON.stringify(route)}`);
          await page.until("!document.querySelector('.spinner')", { what: `${route} loaded`, timeout: 10_000 }).catch(() => {});
          await new Promise((done) => setTimeout(done, 120));
          const fit = await page.eval(overflow);
          assert.ok(fit.scrollWidth <= fit.width, `${route} at ${size.width}: page is ${fit.scrollWidth} wide`);
          assert.deepEqual(fit.wide, [], `${route} at ${size.width}: elements outside the viewport`);
          if (size.width === 390 || size.width === 1280 || size.width === 320) await shot(page, `10-${size.width}-${route.replace(/[#/]+/g, '_') || 'home'}`);
        }
      }
      await page.viewport({ width: 390, height: 844, scale: 3 });
      const titles = [];
      for (const route of routes) {
        await page.eval(`location.hash = ${JSON.stringify(route)}`);
        await new Promise((done) => setTimeout(done, 60));
        titles.push(await page.eval('document.title'));
      }
      assert.equal(new Set(titles).size, routes.length, `each screen has its own title: ${titles.join(' | ')}`);
      assert.deepEqual(page.problems.filter((text) => !/\/v1\/auth\/pair/.test(text) && !/status of 4(00|22)/.test(text) && !/ERR_INTERNET_DISCONNECTED|net::ERR_FAILED/.test(text)), []);
      return `${routes.length} screens x ${sizes.length} sizes`;
    });

    await step('memory: the saved item is listed and can be deleted', async () => {
      await page.eval("location.hash = '#/you/memory'");
      await page.until("[...document.querySelectorAll('.screen:not([hidden]) .rows .zoro-body')].some((el) => el.textContent.includes('masala chai'))", { what: 'memory row' });
      await page.tap('.screen:not([hidden]) .rows button.icon-btn');
      await page.until("!!document.querySelector('dialog.sheet[open][role=alertdialog]')");
      await page.tap('dialog.sheet[open] button', 'Delete');
      await page.until("!!document.querySelector('.screen:not([hidden]) .state--empty')", { what: 'empty memory' });
      assert.equal(await page.eval("document.querySelector('.screen:not([hidden]) .state--empty').textContent"), "ZORO hasn't saved anything about you yet.");
    });

    await step('security is shown, not changed; this device is marked; history lists the conversation', async () => {
      await page.eval("location.hash = '#/you/security'");
      await page.until("!!document.querySelector('.screen:not([hidden]) .callout--moon')");
      const security = await page.eval("(() => { const s = document.querySelector('.screen:not([hidden])'); return { text: s.textContent, switches: s.querySelectorAll('.switch').length, mine: !![...s.querySelectorAll('.badge')].find((b) => b.textContent === 'This device') }; })()");
      assert.match(security.text, /cannot change them/);
      assert.equal(security.switches, 1); // only "ask in private mode from this browser"
      assert.ok(security.mine);
      await page.until("document.querySelectorAll('.screen:not([hidden]) .section').length >= 4 && !document.querySelector('.screen:not([hidden]) .spinner')");
      await page.eval("location.hash = '#/activity'");
      await page.until("document.querySelectorAll('.row--split').length >= 1", { what: 'history rows' });
      const history = await page.eval("[...document.querySelectorAll('.row--split .row-title')].map((el) => el.textContent)");
      assert.ok(history.some((title) => title.includes('masala chai')), JSON.stringify(history));
    });

    await step('dark mode, Hindi and reduced motion', async () => {
      await page.media({ 'prefers-color-scheme': 'dark' });
      await page.eval("location.hash = '#/'");
      await new Promise((done) => setTimeout(done, 300));
      const dark = await page.eval("getComputedStyle(document.body).backgroundColor");
      assert.equal(dark, 'rgb(28, 28, 30)');
      await shot(page, '11-home-dark');
      await ask(page, 'send a WhatsApp message to +919876543210 saying running late');
      await page.until("!!document.querySelector('dialog.sheet[open] .approval')");
      await new Promise((done) => setTimeout(done, 700));
      await shot(page, '12-approval-sheet-dark');
      await page.tap('dialog.sheet[open] button', 'Decline');
      await page.until("!document.querySelector('dialog[open]') && document.querySelector('.exchange--live .zoro-voice').textContent.length > 0 && !document.querySelector('[data-approval]')", { what: 'reply after declining' });
      const declined = await page.eval("document.querySelector('.exchange--live .zoro-voice').textContent");
      assert.ok(declined.length > 0);
      assert.deepEqual(await page.eval('window.__opened'), []); // a declined request opens nothing
      await page.eval("location.hash = '#/you/settings'");
      await page.until("!!document.querySelector('input[name=set-lang][value=hi]')");
      await page.eval("document.querySelector('input[name=set-lang][value=hi]').click()");
      await page.until("document.documentElement.lang === 'hi' && document.title.includes('सेटिंग')", { what: 'Hindi interface' });
      await shot(page, '13-settings-hindi-dark');
      await page.eval("location.hash = '#/'");
      await page.until("document.querySelector('.composer textarea').placeholder === 'ZORO को लिखें'");
      await shot(page, '14-home-hindi-dark');
      await page.media({ 'prefers-color-scheme': 'dark', 'prefers-reduced-motion': 'reduce' });
      await new Promise((done) => setTimeout(done, 200));
      const frames = await page.eval(`new Promise((done) => { let n = 0; const orig = CanvasRenderingContext2D.prototype.clearRect; CanvasRenderingContext2D.prototype.clearRect = function (...a) { if (this.canvas.classList.contains('orb-canvas')) n += 1; return orig.apply(this, a); }; setTimeout(() => { CanvasRenderingContext2D.prototype.clearRect = orig; done(n); }, 1000); })`);
      assert.ok(frames <= 2, `the orb repainted ${frames} times in one second under reduced motion`);
      await page.media({ 'prefers-color-scheme': 'light' });
      return `declined reply: "${declined}"; orb repaints per second under reduced motion: ${frames}`;
    });

    await step('orb frame rate with full motion (headless Chrome on this Mac, not an iPhone)', async () => {
      await page.eval("location.hash = '#/'");
      await new Promise((done) => setTimeout(done, 300));
      const stats = await page.eval(`new Promise((done) => { let n = 0; let cost = 0; const proto = CanvasRenderingContext2D.prototype; const orig = proto.clearRect; let t0 = 0;
        proto.clearRect = function (...a) { if (this.canvas.classList.contains('orb-canvas')) { n += 1; t0 = performance.now(); queueMicrotask(() => { cost += performance.now() - t0; }); } return orig.apply(this, a); };
        setTimeout(() => { proto.clearRect = orig; done({ frames: n, msPerFrame: n ? cost / n : 0 }); }, 2000); })`);
      assert.ok(stats.frames >= 60, `only ${stats.frames} orb frames in 2 s`);
      return `${(stats.frames / 2).toFixed(0)} frames a second, ${stats.msPerFrame.toFixed(2)} ms of script per frame`;
    });

    await step('forgetting the pairing removes the key, the cache and the settings', async () => {
      await page.eval("location.hash = '#/you/settings'");
      await page.until("!!document.querySelector('.btn--danger')");
      await page.tap('.screen:not([hidden]) button.btn--danger');
      await page.until("!!document.querySelector('dialog.sheet[open][role=alertdialog]')");
      await page.tap('dialog.sheet[open] button.btn--danger');
      await page.until("!!document.querySelector('.welcome')", { what: 'back at welcome' });
      const left = await page.eval(`new Promise((done) => { const open = indexedDB.open('zoro-web'); open.onsuccess = () => { const tx = open.result.transaction(['identity', 'cache'], 'readonly'); const a = tx.objectStore('identity').getAllKeys(); const b = tx.objectStore('cache').getAllKeys(); tx.oncomplete = () => done({ identity: a.result, cache: b.result, local: Object.keys(localStorage) }); }; })`);
      assert.deepEqual(left, { identity: [], cache: [], local: [] });
    });
  } catch (error) {
    failed = true;
    if (!results.some((result) => !result.ok)) console.log(`FAIL  setup: ${error.message}`);
  } finally {
    // Everything started here is stopped here, whatever happened above.
    await chrome?.close().catch(() => {});
    if (web) {
      web.server.closeAllConnections?.();
      await new Promise((done) => web.server.close(done));
    }
    await backend?.stop();
  }
  const passed = results.filter((result) => result.ok).length;
  console.log(`\nbrowser test: ${passed} passed, ${results.length - passed} failed. Screenshots: ${SHOTS}`);
  if (pageRef) console.log(`screenshot retries: ${pageRef.screenshotRetries}, screenshots not taken: ${pageRef.screenshotsMissed.length}, key events not acknowledged: ${pageRef.unacknowledged}`);
  return failed ? 1 : 0;
}

process.exit(await main());
