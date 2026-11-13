// The app shell as shipped: Content-Security-Policy, manifest, service worker, icons, static
// safety rules of the source, formatting, the orb's numbers and the colour tokens' contrast.

import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { inflateSync } from 'node:zlib';

import { agentName, dayBucket, formatCountdown, formatDate, formatMoney, formatPaise, formatTime, groupIndian, isStale, joinNames, toolLabel, toPaiseParts } from '../js/core/format.js';
import { createI18n } from '../js/i18n/index.js';
import { bodyRadius, bodyStops, needsAnimation, ORB_STATES, orbParameters, orbValue, PALETTES, satelliteAngles, shakeOffset } from '../js/ui/orb-params.js';
import { rekhaBars } from '../js/ui/rekha.js';
import { build, OUTPUTS } from '../tools/make-icons.mjs';
import { resolveAsset, SECURITY_HEADERS } from '../tools/serve.mjs';
import { shellFiles, stamped } from '../tools/stamp-shell.mjs';

const ROOT = fileURLToPath(new URL('../', import.meta.url));
const read = (path) => readFileSync(join(ROOT, path), 'utf8');
const html = read('index.html');
const sw = read('sw.js');

function sources(dir) {
  return readdirSync(join(ROOT, dir)).flatMap((name) => {
    const path = `${dir}/${name}`;
    if (statSync(join(ROOT, path)).isDirectory()) return sources(path);
    return name.endsWith('.js') ? [path] : [];
  });
}

// ---------------------------------------------------------------- Content-Security-Policy and HTML

function csp() {
  const match = /http-equiv="Content-Security-Policy"\s+content="([^"]+)"/.exec(html);
  assert.ok(match, 'index.html carries a Content-Security-Policy');
  return Object.fromEntries(match[1].split(';').map((part) => part.trim().split(/\s+/)).map(([name, ...values]) => [name, values]));
}

test('the Content-Security-Policy allows this origin only: no inline or evaluated code, no third parties', () => {
  const policy = csp();
  assert.deepEqual(policy['default-src'], ["'none'"]);
  assert.deepEqual(policy['script-src'], ["'self'"]);
  assert.deepEqual(policy['style-src'], ["'self'"]);
  assert.deepEqual(policy['connect-src'], ["'self'"]);
  assert.deepEqual(policy['img-src'], ["'self'", 'data:']);
  for (const name of ['object-src', 'frame-src', 'base-uri', 'form-action', 'media-src']) assert.deepEqual(policy[name], ["'none'"], name);
  const everything = Object.values(policy).flat().join(' ');
  assert.ok(!/unsafe-inline|unsafe-eval|\*|https?:|wss?:/.test(everything), everything);
  // The dev server (and the backend, when it serves web/) sends the same policy plus frame-ancestors.
  assert.ok(SECURITY_HEADERS['Content-Security-Policy'].includes("frame-ancestors 'none'"));
  for (const [name, values] of Object.entries(policy)) assert.ok(SECURITY_HEADERS['Content-Security-Policy'].includes(`${name} ${values.join(' ')}`), name);
});

test('index.html has no inline script, style or event handler, and only relative same-origin references', () => {
  assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), 'no inline <script>');
  assert.ok(!/<style[\s>]/i.test(html), 'no <style> block');
  assert.ok(!/\sstyle="/i.test(html), 'no style attribute');
  assert.ok(!/\son[a-z]+="/i.test(html), 'no inline event handler');
  const refs = [...html.matchAll(/\b(?:src|href)="([^"]+)"/g)].map((match) => match[1]);
  assert.ok(refs.length >= 7);
  for (const ref of refs) {
    if (ref.startsWith('#')) continue;
    assert.ok(ref.startsWith('./'), `${ref} is relative, so the app works under /app/`);
    assert.ok(existsSync(join(ROOT, ref.slice(2))), `${ref} exists`);
  }
});

test('the Apple web-app tags, viewport and theme colours are present', () => {
  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"/);
  assert.ok(!/user-scalable=no|maximum-scale/.test(html), 'zoom is not disabled');
  assert.match(html, /<meta name="apple-mobile-web-app-capable" content="yes"/);
  assert.match(html, /<meta name="apple-mobile-web-app-title" content="ZORO"/);
  assert.match(html, /<meta name="apple-mobile-web-app-status-bar-style" content="default"/);
  assert.match(html, /<link rel="apple-touch-icon" href="\.\/icons\/apple-touch-icon\.png"/);
  assert.match(html, /<meta name="theme-color" content="#f2f2f7" media="\(prefers-color-scheme: light\)"/);
  assert.match(html, /<meta name="theme-color" content="#1c1c1e" media="\(prefers-color-scheme: dark\)"/);
  assert.match(html, /<meta name="referrer" content="no-referrer"/);
  assert.match(html, /<html lang="en">/);
  assert.match(html, /<main id="main"[^>]*tabindex="-1"/);
  assert.match(html, /<a class="skip" href="#main">/);
});

// ---------------------------------------------------------------- manifest and icons

test('the manifest installs ZORO standalone with maskable icons, under a relative scope', () => {
  const manifest = JSON.parse(read('manifest.webmanifest'));
  assert.equal(manifest.name, 'ZORO');
  assert.equal(manifest.short_name, 'ZORO');
  assert.equal(manifest.display, 'standalone');
  assert.equal(manifest.start_url, './');
  assert.equal(manifest.scope, './');
  assert.match(manifest.theme_color, /^#[0-9a-f]{6}$/);
  assert.match(manifest.background_color, /^#[0-9a-f]{6}$/);
  const purposes = manifest.icons.map((item) => `${item.purpose}:${item.sizes}`);
  for (const wanted of ['any:192x192', 'any:512x512', 'maskable:192x192', 'maskable:512x512']) assert.ok(purposes.includes(wanted), wanted);
  for (const item of manifest.icons) assert.ok(existsSync(join(ROOT, item.src)), item.src);
});

function pngInfo(buffer) {
  assert.deepEqual([...buffer.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const width = buffer.readUInt32BE(16);
  const height = buffer.readUInt32BE(20);
  let offset = 8;
  const data = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('latin1', offset + 4, offset + 8);
    if (type === 'IDAT') data.push(buffer.subarray(offset + 8, offset + 8 + length));
    offset += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(data));
  const pixel = (x, y) => [...raw.subarray(y * (width * 4 + 1) + 1 + x * 4, y * (width * 4 + 1) + 5 + x * 4)];
  return { width, height, bitDepth: buffer[24], colorType: buffer[25], pixel };
}

test('the icons on disk are exactly what the drawing tool produces, at the stated sizes', () => {
  for (const output of OUTPUTS) {
    const onDisk = readFileSync(join(ROOT, 'icons', output.file));
    assert.ok(onDisk.equals(build(output)), `${output.file} is stale: run node tools/make-icons.mjs`);
    if (output.kind !== 'png') {
      assert.ok(!/<script|<image|href=/.test(onDisk.toString('utf8')), 'the SVG has no script and embeds nothing');
      continue;
    }
    const info = pngInfo(onDisk);
    assert.deepEqual([info.width, info.height, info.bitDepth, info.colorType], [output.size, output.size, 8, 6]);
    const centre = info.pixel(output.size >> 1, output.size >> 1);
    assert.equal(centre[3], 255);
    const corner = info.pixel(0, 0);
    // Maskable and Apple icons are full bleed (iOS and Android cut their own shape); the plain one is rounded.
    assert.equal(corner[3], output.rounded ? 0 : 255, `${output.file} corner`);
    // The orb stays inside the maskable safe zone: at 40 % from the centre it is ground, not orb.
    const edge = info.pixel(Math.round(output.size * 0.9), output.size >> 1);
    assert.ok(edge[0] < 60 && edge[1] < 60 && edge[2] < 110, `${output.file} safe zone`);
  }
});

// ---------------------------------------------------------------- service worker

test('the service worker file list and version are current, and list only the app shell', () => {
  assert.equal(stamped().current, true, 'sw.js is out of date: run node tools/stamp-shell.mjs');
  const files = shellFiles();
  assert.ok(files.includes('index.html') && files.includes('js/app.js') && files.includes('icons/apple-touch-icon.png'));
  assert.ok(!files.some((file) => /^(tests|tools)\//.test(file) || /(README|package\.json|sw\.js)$/.test(file)));
  for (const file of files) assert.ok(sw.includes(`'${file}'`), `${file} is precached`);
  assert.match(sw, /const SHELL_VERSION = '[0-9a-f]{16}';/);
});

test('the service worker never touches an API request and keeps nothing but shell files', () => {
  assert.ok(!/\/v1|healthz|\/mcp/.test(sw.replace(/\/\/.*$/gm, '')), 'no API path appears in the worker code');
  assert.match(sw, /if \(!key\) return;/); // anything that is not a shell file is left to the browser
  assert.match(sw, /request\.method !== 'GET'/);
  assert.match(sw, /url\.origin !== SCOPE\.origin/);
  assert.equal((sw.match(/cache\.put\(/g) || []).length, 1); // only inside the shell branch
  assert.match(sw, /caches\.delete\(name\)/); // old versions are removed on activate
  assert.match(sw, /event\.data\.type === 'skip-waiting'/); // the owner decides when to switch
  assert.ok(!/skipWaiting\(\)[\s\S]*addEventListener\('install'/.test(sw) && !/install[\s\S]{0,400}skipWaiting/.test(sw), 'install does not skip waiting by itself');
  assert.ok(!/importScripts|fetch\(['"`]http/.test(sw));
});

// ---------------------------------------------------------------- source rules

test('source rules: no HTML injection, no evaluated code, no storage of anything but preferences', () => {
  const files = [...sources('js'), 'sw.js'];
  assert.ok(files.length >= 35);
  for (const file of files) {
    const code = read(file).replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
    assert.ok(!/\.innerHTML|\.outerHTML|insertAdjacentHTML|document\.write|DOMParser|createContextualFragment/.test(code), `${file}: markup injection`);
    assert.ok(!/\beval\(|new Function\(|setTimeout\(\s*['"`]|setInterval\(\s*['"`]/.test(code), `${file}: evaluated code`);
    assert.ok(!/sessionStorage|document\.cookie/.test(code), `${file}: session storage or cookies`);
    if (file !== 'js/core/prefs.js' && file !== 'js/app.js') assert.ok(!/localStorage/.test(code), `${file}: localStorage outside preferences`);
    assert.ok(!/https?:\/\/(?!wa\.me\/)[a-z0-9.-]+\.[a-z]{2,}/i.test(code.replace(/http:\/\/www\.w3\.org\/2000\/svg/g, '')), `${file}: a hard-coded external address`);
    assert.ok(!/console\.(log|debug|info)\(/.test(code), `${file}: console output`);
  }
  const app = read('js/app.js');
  assert.equal((app.match(/localStorage/g) || []).length, 1); // only checks whether preferences exist yet
  assert.match(read('js/core/api.js'), /credentials: 'omit'/);
  assert.match(read('js/core/api.js'), /cache: 'no-store'/);
  assert.match(read('js/core/identity.js'), /generateKey\(ECDSA_PARAMS, false,/);
  assert.match(read('js/core/sealed-cache.js'), /\{ name: 'AES-GCM', length: 256 \}, false,/);
  // The two string catalogues are data, not logic; everything else stays near 400 lines.
  for (const file of sources('js').filter((name) => !/i18n\/(en|hi)\.js$/.test(name))) assert.ok(read(file).split('\n').length <= 425, `${file} is under about 400 lines`);
});

test('the dev server serves only the app, and never a path outside it', () => {
  assert.ok(resolveAsset('/app/').endsWith('index.html'));
  assert.ok(resolveAsset('/app/js/app.js'));
  assert.ok(resolveAsset('/app/icons/icon.svg'));
  assert.ok(resolveAsset('/app/sw.js'));
  for (const path of ['/app/../backend/app/main.py', '/app/%2e%2e/CLAUDE.md', '/app/js/../../.env', '/app/tests/e2e.mjs', '/app/tools/serve.mjs', '/app/package.json', '/app/README.md', '/app/.env', '/app/js/%00', '/app/js\\..\\x', '/v1/turns', '/app/css/missing.css', '/app/js']) {
    assert.equal(resolveAsset(path), null, path);
  }
});

// ---------------------------------------------------------------- formatting

test('money: Indian grouping, exact paise, a real minus, never a float and never an invented zero', () => {
  assert.equal(formatMoney('123456.5'), '₹1,23,456.50');
  assert.equal(formatMoney('1234567890.00'), '₹1,23,45,67,890.00');
  assert.equal(formatMoney('999'), '₹999.00');
  assert.equal(formatMoney('0'), '₹0.00');
  assert.equal(formatMoney('-1500.5'), '−₹1,500.50');
  assert.equal(formatMoney('-0.00'), '₹0.00');
  assert.equal(formatMoney('0.005'), '₹0.01'); // half away from zero
  assert.equal(formatMoney('2.675'), '₹2.68'); // a float would give 2.67
  assert.equal(formatMoney('1.004'), '₹1.00');
  assert.equal(formatMoney('99999.995'), '₹1,00,000.00');
  assert.equal(formatMoney('12345678901234567890.12'), '₹1,23,45,67,89,01,23,45,67,890.12');
  for (const bad of [null, undefined, '', 'abc', '1,234', '1e5', 12.5, Number.NaN, {}, '₹5']) assert.equal(formatMoney(bad), null, String(bad));
  assert.equal(formatMoney('12.50', { currency: 'USD' }), 'USD 12.50');
  assert.equal(formatPaise(123456), '₹1,234.56');
  assert.equal(formatPaise(5), '₹0.05');
  assert.equal(formatPaise(-250), '−₹2.50');
  assert.equal(formatPaise(12.5), null);
  assert.deepEqual(toPaiseParts('7'), { negative: false, whole: '7', paise: '00' });
  assert.equal(groupIndian('100000'), '1,00,000');
});

test('times and dates: 12-hour with the period of day in Hindi, Western digits, short months', () => {
  const at = (h, m = 12) => new Date(2026, 10, 12, h, m);
  assert.equal(formatTime(at(16), 'en'), '4:12 pm');
  assert.equal(formatTime(at(16), 'hi'), 'शाम 4:12');
  assert.equal(formatTime(at(0, 5), 'en'), '12:05 am');
  assert.equal(formatTime(at(6), 'hi'), 'सुबह 6:12');
  assert.equal(formatTime(at(13), 'hi'), 'दोपहर 1:12');
  assert.equal(formatTime(at(22), 'hi'), 'रात 10:12');
  assert.equal(formatTime('nonsense'), '');
  const now = new Date(2026, 10, 13, 9, 0);
  assert.equal(formatDate(at(9), 'en', now), '12 Nov');
  assert.equal(formatDate(at(9), 'hi', now), '12 नवंबर');
  assert.equal(formatDate(new Date(2025, 0, 3), 'en', now), '3 Jan 2025');
  assert.equal(dayBucket(new Date(2026, 10, 13, 0, 1), now), 'today');
  assert.equal(dayBucket(at(23, 59), now), 'yesterday');
  assert.equal(dayBucket(new Date(2026, 10, 1), now), 'earlier');
  assert.equal(formatCountdown(105), '1:45');
  assert.equal(formatCountdown(-3), '0:00');
  assert.equal(isStale(new Date(now.getTime() - 29 * 60000), now), false);
  assert.equal(isStale(new Date(now.getTime() - 31 * 60000), now), true);
  assert.equal(isStale('nonsense', now), true);
});

test('agents keep their Latin names in both languages; lists join with and / और', () => {
  assert.equal(agentName('shopping'), 'Shopping');
  assert.equal(agentName('communication'), 'Communications');
  assert.equal(agentName('some_new_agent'), 'Some new agent');
  assert.equal(joinNames(['Shopping', 'Finance'], 'en'), 'Shopping and Finance');
  assert.equal(joinNames(['Shopping', 'Finance', 'Music'], 'hi'), 'Shopping, Finance और Music');
  assert.equal(joinNames([], 'en'), '');
  assert.equal(toolLabel('finance.spending_summary'), 'Spending summary');
});

// ---------------------------------------------------------------- orb and rekha

test('the eight orb states follow the design table', () => {
  assert.deepEqual([...ORB_STATES], ['idle', 'listening', 'processing', 'delegating', 'tool', 'speaking', 'error', 'private']);
  const p = Object.fromEntries(ORB_STATES.map((state) => [state, orbParameters(state)]));
  assert.deepEqual([p.idle.scale, p.idle.breath, p.idle.breathPeriod, p.idle.deform], [0.78, 0.025, 4.2, 0.035]);
  assert.deepEqual([p.listening.scale, p.listening.levelGain, p.listening.ripples], [0.9, 0.14, true]);
  assert.deepEqual([p.processing.iridescence, p.processing.arc], [1, 'turning']);
  assert.equal(p.delegating.satellites, 'orbiting');
  assert.ok(p.delegating.scale < p.idle.scale);
  assert.deepEqual([p.tool.satellites, p.tool.arc], ['docked', 'sweep']);
  assert.deepEqual([p.speaking.warmth, p.speaking.levelGain], [0.7, 0.1]);
  assert.deepEqual([p.error.alarm, p.error.shake], [0.75, true]);
  assert.deepEqual([p.private.moon, p.private.iridescence, p.private.ring], [1, 0, 'sealed']);
  assert.deepEqual(orbParameters('nonsense'), p.idle);
});

test('Reduce Motion: no deformation, breath, drift or shake; the state stays readable; only sound animates', () => {
  for (const state of ORB_STATES) {
    const still = orbParameters(state, true);
    const moving = orbParameters(state, false);
    assert.deepEqual([still.breath, still.deform, still.drift, still.levelGain, still.shake], [0, 0, 0, 0, false], state);
    assert.deepEqual([still.ring, still.arc, still.satellites, still.moon, still.alarm, still.warmth], [moving.ring, moving.arc, moving.satellites, moving.moon, moving.alarm, moving.warmth], state);
    assert.ok(still.haloGain > 0);
    assert.equal(needsAnimation(state, false), true);
    assert.equal(needsAnimation(state, true), state === 'listening' || state === 'speaking', state);
    for (let i = 0; i < 12; i += 1) assert.equal(bodyRadius(100, i, i * 3.1, still, 1), 100); // a perfect, still circle
  }
});

test('the peacock eye: neel at the rim, a mor band, one genda thread; private has no iridescence; error is lac', () => {
  for (const scheme of ['light', 'dark']) {
    const palette = PALETTES[scheme];
    const idle = bodyStops(orbParameters('processing'), scheme);
    assert.deepEqual(idle.map((stop) => stop.at), [...idle.map((stop) => stop.at)].sort((a, b) => a - b));
    assert.deepEqual([idle[0].at, idle.at(-1).at], [0, 1]);
    assert.deepEqual(idle.at(-1).color, palette.neel);
    const thread = idle.find((stop) => stop.at === 0.71).color;
    assert.ok(thread[0] > idle.find((stop) => stop.at === 0.6).color[0] + 60, 'the thread is warmer than the band');
    const saturation = (c) => Math.max(...c) - Math.min(...c);
    const moon = bodyStops(orbParameters('private'), scheme);
    assert.ok(moon.every((stop) => saturation(stop.color) < 45), 'moonstone is grey throughout');
    const alarm = bodyStops(orbParameters('error'), scheme);
    assert.ok(alarm.every((stop) => stop.color[0] > stop.color[1] && stop.color[0] > stop.color[2]), 'error is red throughout');
    const warm = bodyStops(orbParameters('speaking'), scheme)[0].color;
    assert.ok(warm[0] > warm[2], 'marigold at the eye while speaking');
  }
});

test('geometry: the body stays within a quarter of its radius, satellites cap at six, the shake ends', () => {
  const params = orbParameters('listening');
  for (let i = 0; i < 400; i += 1) {
    const r = bodyRadius(100, i * 0.37, i * 0.11, params, (i % 11) / 10);
    assert.ok(r >= 75 && r <= 125);
  }
  assert.equal(satelliteAngles(9, 'orbiting').length, 6);
  assert.equal(satelliteAngles(0, 'docked').length, 0);
  assert.equal(satelliteAngles(1, 'docked')[0], -Math.PI / 2); // docks at 12 o'clock
  assert.notEqual(satelliteAngles(2, 'orbiting', 0)[0], satelliteAngles(2, 'orbiting', 1)[0]);
  assert.equal(satelliteAngles(2, 'docked', 0)[0], satelliteAngles(2, 'docked', 5)[0]);
  assert.notEqual(shakeOffset(0.05, 10), 0);
  assert.equal(shakeOffset(0.45, 10), 0);
  assert.equal(shakeOffset(3, 10), 0);
  assert.ok(Math.abs(shakeOffset(0.4, 10)) < Math.abs(shakeOffset(0.04, 10)));
});

test('the orb status names the working agents, in both languages', () => {
  const en = createI18n('en');
  const hi = createI18n('hi');
  assert.equal(orbValue(en, { state: 'idle' }), 'Ready. Tap to talk.');
  assert.equal(orbValue(en, { state: 'idle', canListen: false }), 'Ready. Type below to ask.');
  assert.equal(orbValue(en, { state: 'delegating', agents: ['shopping', 'finance'] }), 'Working with Shopping and Finance');
  assert.equal(orbValue(hi, { state: 'delegating', agents: ['shopping', 'finance'] }), 'Shopping और Finance के साथ काम जारी है');
  assert.equal(orbValue(en, { state: 'tool', agents: ['shopping'] }), 'Carrying out a step with Shopping');
  assert.equal(orbValue(en, { state: 'tool', agents: ['communication'], waiting: true }), 'Waiting for you');
  assert.equal(orbValue(en, { state: 'processing' }), 'Thinking');
  assert.equal(orbValue(hi, { state: 'speaking' }), 'जवाब सुनाया जा रहा है');
  assert.equal(orbValue(en, { state: 'error' }), 'Something went wrong');
  assert.equal(orbValue(en, { state: 'private' }), 'Private mode. Tap to talk.');
});

test('the rekha: ZORO rises on the left, the owner hangs on the right, silence draws nothing', () => {
  assert.deepEqual(rekhaBars({ width: 300, height: 56, zoro: [0, 0, 0], owner: [0, 0] }), []);
  const bars = rekhaBars({ width: 300, height: 56, zoro: [0, 0.5, 1], owner: [1, 0, 0.25] });
  assert.equal(bars.length, 4);
  for (const bar of bars) {
    if (bar.voice === 'zoro') {
      assert.ok(bar.x + bar.w <= 150 && bar.y + bar.h === 28, 'stands on the line, left half');
    } else {
      assert.ok(bar.x >= 150 && bar.y === 28, 'hangs from the line, right half');
    }
    assert.ok(bar.h <= 27 && bar.h >= 2);
  }
});

// ---------------------------------------------------------------- colour tokens

function tokens(block) {
  return Object.fromEntries([...block.matchAll(/--([a-z0-9-]+):\s*(#[0-9a-f]{6})\b/g)].map((match) => [match[1], match[2]]));
}

function luminance(hex) {
  const channel = (i) => {
    const v = Number.parseInt(hex.slice(1 + i * 2, 3 + i * 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2);
}

function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

test('colour tokens: the spec hues, and 4.5:1 for every text colour on every surface, light and dark', () => {
  const css = read('css/tokens.css');
  const light = tokens(css.slice(0, css.indexOf('@media (prefers-color-scheme: dark)')));
  const dark = { ...light, ...tokens(css.slice(css.indexOf('@media (prefers-color-scheme: dark)'), css.indexOf('@media (prefers-contrast: more)'))) };
  assert.deepEqual([light.neel, light.mor, light.genda, light.lac, light.moonstone], ['#2a2f8f', '#0b7f86', '#d98a00', '#b5302a', '#6e7a8a']);
  assert.deepEqual([dark.neel, dark.mor, dark.genda, dark.lac, dark.moonstone], ['#5b62e0', '#19b5b0', '#ffb321', '#ff6b5e', '#a9b4c2']);
  for (const [name, set] of [['light', light], ['dark', dark]]) {
    for (const text of ['label', 'label-2', 'label-3', 'neel-text', 'mor-text', 'genda-text', 'lac-text', 'moonstone-text']) {
      for (const surface of ['bg', 'raised', 'inset']) {
        const ratio = contrast(set[text], set[surface]);
        assert.ok(ratio >= 4.5, `${name}: --${text} on --${surface} is ${ratio.toFixed(2)}:1`);
      }
    }
    for (const hue of ['neel', 'mor', 'genda', 'lac']) {
      const ratio = contrast(set[`on-${hue}`], set[hue]);
      assert.ok(ratio >= 4.5, `${name}: label on ${hue} is ${ratio.toFixed(2)}:1`);
    }
  }
  const app = read('css/app.css');
  assert.ok(!/box-shadow|text-shadow/.test(app), 'no shadows');
  assert.ok(!/text-transform:\s*uppercase(?![\s\S]{0,0})/.test(app.replace(/\.input--code \{[\s\S]*?\}/, '')), 'no all-caps labels (the pairing code field shows a code, not a label)');
  assert.match(app, /prefers-reduced-motion: reduce/);
  assert.match(app, /env\(safe-area-inset-bottom\)/);
  assert.match(app, /100dvh/);
});
