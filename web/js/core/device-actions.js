// What this web app does when the server asks the device to act.
//
// A browser tab is not an iPhone: it cannot set alarms, read contacts, search photos, read
// Health or control music. It can do exactly one thing honestly: give the owner a link to tap
// (a web page, or WhatsApp with the text ready). Everything else is answered at once with
// `ok: false, error_code: "unsupported"`, so ZORO says so instead of waiting for a timeout.
// A link is never opened without a tap: the owner sees the exact address first.

import { WEB_CAPABILITIES } from './identity.js';

const MAX_URL_LENGTH = 2048;
const MAX_TEXT_LENGTH = 4000;

/** @typedef {{action_id: string, tool: string, args?: Record<string, any>, expires_at?: string,
 *   turn_id?: string | null, risk?: string}} DeviceAction */

/** A safe https address, or null. Refuses other schemes, missing hosts, embedded credentials and
 * control characters. @param {unknown} value */
export function safeHttpsUrl(value) {
  if (typeof value !== 'string' || value.length < 4 || value.length > MAX_URL_LENGTH) return null;
  if (/[\u0000-\u001f\u007f\s]/.test(value)) return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) return null;
  return url.toString();
}

/** `https://wa.me/<digits>?text=...` — the owner taps send in WhatsApp.
 * @param {{phone?: string | null, text?: string}} args */
export function whatsappLink(args) {
  const text = typeof args?.text === 'string' ? args.text : '';
  if (!text || text.length > MAX_TEXT_LENGTH) return null;
  const digits = String(args.phone ?? '').replace(/\D/g, '');
  if (digits && (digits.length < 6 || digits.length > 15)) return null;
  return `https://wa.me/${digits}?text=${encodeURIComponent(text)}`;
}

/** Decide what to do with a device action.
 * @param {DeviceAction} action @param {Date} [now]
 * @returns {{kind: 'link', url: string, host: string, tool: string}
 *   | {kind: 'refuse', errorCode: 'unsupported' | 'invalid_arguments' | 'expired'}} */
export function planDeviceAction(action, now = new Date()) {
  if (action?.expires_at && new Date(action.expires_at).getTime() <= now.getTime()) {
    return { kind: 'refuse', errorCode: 'expired' };
  }
  if (!WEB_CAPABILITIES.includes(action?.tool)) return { kind: 'refuse', errorCode: 'unsupported' };
  const args = action.args ?? {};
  if (action.tool === 'device.open_url') {
    const url = safeHttpsUrl(args.url);
    // App schemes (shortcuts://, music://) are an iPhone or Mac matter, not a browser's.
    if (!url) return { kind: 'refuse', errorCode: typeof args.url === 'string' && !args.url.startsWith('https:') ? 'unsupported' : 'invalid_arguments' };
    return { kind: 'link', url, host: new URL(url).hostname, tool: action.tool };
  }
  const url = whatsappLink(args);
  if (!url) return { kind: 'refuse', errorCode: 'invalid_arguments' };
  return { kind: 'link', url, host: 'wa.me', tool: action.tool };
}

const REFUSAL_MESSAGES = Object.freeze({
  unsupported: 'The ZORO web app cannot do this. Use the ZORO app on your iPhone or Mac.',
  invalid_arguments: 'The web app was not given a link it can open.',
  expired: 'The request expired before it was answered.',
  user_cancelled: 'The owner chose not to open the link.',
  failed: 'The browser did not open the link.',
});

/** A `DeviceActionResult` saying the link was handed to the browser.
 * @param {DeviceAction} action @param {Date} [now] */
export function openedResult(action, now = new Date()) {
  return { action_id: action.action_id, ok: true, result: { opened: true }, executed_at: now.toISOString() };
}

/** A `DeviceActionResult` for something that was not done.
 * @param {DeviceAction} action
 * @param {'unsupported' | 'invalid_arguments' | 'expired' | 'user_cancelled' | 'failed'} errorCode
 * @param {Date} [now] */
export function refusedResult(action, errorCode, now = new Date()) {
  const result = {
    action_id: action.action_id,
    ok: false,
    error_code: errorCode,
    error_message: REFUSAL_MESSAGES[errorCode] ?? REFUSAL_MESSAGES.failed,
    executed_at: now.toISOString(),
  };
  if (errorCode === 'unsupported') result.capability_status = 'unavailable';
  return result;
}

/** Hand a link to the browser from inside a tap handler. Returns false when the browser blocked
 * it. `noopener` keeps the opened page from reaching back into ZORO.
 * @param {string} url @param {{open?: typeof window.open}} [env] */
export function openLink(url, { open = globalThis.open?.bind(globalThis) } = {}) {
  if (!safeHttpsUrl(url) || !open) return false;
  try {
    open(url, '_blank', 'noopener,noreferrer');
    return true; // with `noopener` the return value is null even on success
  } catch {
    return false;
  }
}
