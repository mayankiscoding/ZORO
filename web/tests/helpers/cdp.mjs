// A very small Chrome DevTools Protocol driver for the browser test. No dependencies: it starts
// the Chrome that is already installed (headless, with a throwaway profile) and talks to it over
// Node's built-in WebSocket. Nothing is downloaded or installed.

import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CANDIDATES = [
  process.env.ZORO_CHROME,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
].filter(Boolean);

export function findChrome() {
  return CANDIDATES.find((path) => existsSync(path)) ?? null;
}

class Connection {
  constructor(socket) {
    this._socket = socket;
    this._next = 1;
    this._waiting = new Map();
    this._listeners = new Set();
    socket.addEventListener('message', (message) => {
      const frame = JSON.parse(message.data);
      if (frame.id && this._waiting.has(frame.id)) {
        const { done, fail } = this._waiting.get(frame.id);
        this._waiting.delete(frame.id);
        if (frame.error) fail(new Error(`${frame.error.message} ${frame.error.data ?? ''}`));
        else done(frame.result);
      } else if (frame.method) {
        for (const listener of this._listeners) listener(frame);
      }
    });
  }

  /** Every command has a deadline: a page stuck in script must fail the test, not hang it. */
  send(method, params = {}, sessionId, timeoutMs = 30_000) {
    const id = this._next++;
    return new Promise((done, fail) => {
      const timer = setTimeout(() => {
        this._waiting.delete(id);
        fail(new Error(`Chrome did not answer ${method} within ${timeoutMs} ms`));
      }, timeoutMs);
      this._waiting.set(id, {
        done: (value) => {
          clearTimeout(timer);
          done(value);
        },
        fail: (error) => {
          clearTimeout(timer);
          fail(error);
        },
      });
      this._socket.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }

  on(listener) {
    this._listeners.add(listener);
    return () => this._listeners.delete(listener);
  }
}

/** One browser tab. */
export class Page {
  constructor(connection, sessionId) {
    this._c = connection;
    this._s = sessionId;
    /** Console errors, uncaught exceptions and CSP reports seen so far. */
    this.problems = [];
    /** Every request the page made: {url, method}. */
    this.requests = [];
    this.screenshotRetries = 0;
    this.screenshotsMissed = [];
    this.unacknowledged = 0;
    connection.on((frame) => {
      if (frame.sessionId !== sessionId) return;
      const p = frame.params;
      if (frame.method === 'Runtime.exceptionThrown') this.problems.push(`exception: ${p.exceptionDetails.exception?.description ?? p.exceptionDetails.text}`);
      if (frame.method === 'Runtime.consoleAPICalled' && p.type === 'error') this.problems.push(`console.error: ${p.args.map((arg) => arg.value ?? arg.description).join(' ')}`);
      if (frame.method === 'Log.entryAdded' && (p.entry.level === 'error' || p.entry.source === 'security')) this.problems.push(`${p.entry.source}: ${p.entry.text} ${p.entry.url ?? ''}`);
      if (frame.method === 'Network.requestWillBeSent') this.requests.push({ url: p.request.url, method: p.request.method });
    });
  }

  cmd(method, params) {
    return this._c.send(method, params, this._s);
  }

  async init() {
    await this.cmd('Page.enable');
    await this.cmd('Runtime.enable');
    await this.cmd('Log.enable');
    await this.cmd('Network.enable');
    // The new tab is not the front one until asked; a background tab never paints a screenshot.
    await this.cmd('Page.bringToFront');
  }

  /** @param {{width: number, height: number, scale?: number, mobile?: boolean}} size */
  async viewport({ width, height, scale = 2, mobile = true }) {
    await this.cmd('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: scale, mobile });
    await this.cmd('Emulation.setTouchEmulationEnabled', { enabled: mobile });
  }

  /** @param {Record<string, string>} features e.g. {'prefers-color-scheme': 'dark'} */
  media(features) {
    return this.cmd('Emulation.setEmulatedMedia', { features: Object.entries(features).map(([name, value]) => ({ name, value })) });
  }

  async goto(url) {
    await this.cmd('Page.navigate', { url });
  }

  /** Evaluate an expression in the page and return its JSON value. Promises are awaited. */
  async eval(expression) {
    const result = await this.cmd('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (result.exceptionDetails) throw new Error(`page threw: ${result.exceptionDetails.exception?.description ?? result.exceptionDetails.text}`);
    return result.result.value;
  }

  /** Wait until an expression is truthy. */
  async until(expression, { timeout = 15_000, what = expression } = {}) {
    const deadline = Date.now() + timeout;
    let last = '';
    for (;;) {
      const value = await this.eval(expression).catch((error) => {
        last = error.message;
        return false;
      });
      if (value) return value;
      if (Date.now() > deadline) throw new Error(`timed out waiting for: ${what}${last ? ` (${last})` : ''}`);
      await new Promise((done) => setTimeout(done, 80));
    }
  }

  /** Centre of the first visible element matching a selector (optionally with given text). */
  async locate(selector, text = null) {
    const point = await this.eval(`(() => {
      const wanted = ${JSON.stringify(text)};
      for (const el of document.querySelectorAll(${JSON.stringify(selector)})) {
        if (wanted !== null && !(el.textContent || '').includes(wanted) && el.getAttribute('aria-label') !== wanted) continue;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;
        el.scrollIntoView({ block: 'center' });
        const b = el.getBoundingClientRect();
        return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
      }
      return null;
    })()`);
    if (!point) throw new Error(`no visible element: ${selector}${text ? ` with "${text}"` : ''}`);
    return point;
  }

  /** A real tap (trusted input), so user-activation rules behave as on a phone. */
  async tap(selector, text = null) {
    const { x, y } = await this.locate(selector, text);
    await this.cmd('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
    await this.cmd('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
  }

  async type(selector, value) {
    await this.eval(`document.querySelector(${JSON.stringify(selector)}).focus()`);
    await this.cmd('Input.insertText', { text: value });
  }

  /** Press a key. Headless Chrome occasionally leaves an input event unacknowledged; that is
   * reported (false) instead of hanging, and the caller decides what to do. */
  async key(key, code = key, keyCode = 13) {
    try {
      for (const type of ['keyDown', 'keyUp']) {
        await this._c.send('Input.dispatchKeyEvent', { type, key, code, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode, text: type === 'keyDown' && key === 'Enter' ? '\r' : undefined }, this._s, 5000);
      }
      return true;
    } catch {
      this.unacknowledged += 1;
      return false;
    }
  }

  /** Headless Chrome sometimes leaves the first capture after a load unanswered; a second
   * request goes through. So: bring the tab to the front, capture with a short deadline, retry. */
  async screenshot(file) {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      try {
        await this.cmd('Page.bringToFront');
        const { data } = await this._c.send('Page.captureScreenshot', { format: 'png' }, this._s, 6000);
        await writeFile(file, Buffer.from(data, 'base64'));
        return file;
      } catch {
        this.screenshotRetries += 1;
      }
    }
    this.screenshotsMissed.push(file); // a picture for review, not an assertion: the test goes on
    return null;
  }
}

/** Start headless Chrome with a temporary profile.
 * @returns {Promise<{newPage: () => Promise<Page>, close: () => Promise<void>}>} */
export async function launchChrome() {
  const binary = findChrome();
  if (!binary) throw new Error('no Chrome, Chromium or Edge found');
  const profile = await mkdtemp(join(tmpdir(), 'zoro-web-chrome-'));
  const flags = ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--mute-audio', '--hide-scrollbars', 'about:blank'];
  // A Node built for Intel runs under Rosetta on Apple silicon and would start Chrome the same
  // way (slow, and unsupported by Chrome). Ask for the native slice when the machine has one.
  const native = process.platform === 'darwin' && spawnSync('/usr/bin/arch', ['-arm64', '/usr/bin/true']).status === 0;
  const child = native
    ? spawn('/usr/bin/arch', ['-arm64', binary, ...flags], { stdio: ['ignore', 'ignore', 'pipe'] })
    : spawn(binary, flags, { stdio: ['ignore', 'ignore', 'pipe'] });
  let text = '';
  let exited = null;
  child.stderr.setEncoding('utf8').on('data', (chunk) => {
    text = (text + chunk).slice(-8000);
  });
  child.once('exit', (code) => {
    exited = code;
  });
  const stop = async () => {
    if (exited === null) {
      child.kill('SIGTERM');
      await new Promise((done) => {
        child.once('exit', done);
        setTimeout(() => {
          child.kill('SIGKILL');
          done();
        }, 4000);
      });
    }
    await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  };
  let endpoint = null;
  const deadline = Date.now() + 90_000;
  while (!endpoint) {
    const match = /DevTools listening on (ws:\/\/\S+)/.exec(text);
    if (match) endpoint = match[1];
    else {
      // Chrome also writes the port and browser path to a file in the profile.
      const file = await readFile(join(profile, 'DevToolsActivePort'), 'utf8').catch(() => '');
      const [port, path] = file.trim().split('\n');
      if (port && path) endpoint = `ws://127.0.0.1:${port}${path}`;
    }
    if (endpoint) break;
    if (exited !== null || Date.now() > deadline) {
      await stop();
      throw new Error(`Chrome did not start (${exited === null ? 'timed out' : `exit ${exited}`}):\n${text.slice(-1500)}`);
    }
    await new Promise((done) => setTimeout(done, 150));
  }
  let socket = null;
  for (let attempt = 1; !socket; attempt += 1) {
    const candidate = new WebSocket(endpoint);
    try {
      await new Promise((done, fail) => {
        const timer = setTimeout(() => fail(new Error('Chrome did not accept the DevTools connection in time')), 15_000);
        candidate.addEventListener('open', () => { clearTimeout(timer); done(); }, { once: true });
        candidate.addEventListener('error', () => { clearTimeout(timer); fail(new Error('could not connect to Chrome')); }, { once: true });
      });
      socket = candidate;
    } catch (error) {
      try {
        candidate.close();
      } catch {
        /* never opened */
      }
      if (attempt >= 3) {
        await stop();
        throw error;
      }
    }
  }
  const connection = new Connection(socket);
  return {
    async newPage() {
      const { targetId } = await connection.send('Target.createTarget', { url: 'about:blank' });
      const { sessionId } = await connection.send('Target.attachToTarget', { targetId, flatten: true });
      const page = new Page(connection, sessionId);
      await page.init();
      return page;
    },
    async close() {
      try {
        await connection.send('Browser.close');
      } catch {
        /* already gone */
      }
      socket.close();
      await stop();
    },
  };
}
