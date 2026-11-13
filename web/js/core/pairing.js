// Pairing: one-time code -> keys made on this device -> the server registers the public keys.

import { ApiError } from './api.js';
import { PLATFORM_PREFERENCE, WEB_CAPABILITIES } from './identity.js';

export const APP_VERSION = 'web-1.0.0';
const CODE_ALPHABET = /[^A-Z0-9]/g;
export const CODE_LENGTH = 8;

/** Upper-case letters and digits only, as the server normalises the code.
 * @param {string} input */
export function normaliseCode(input) {
  return String(input || '').toUpperCase().replace(CODE_ALPHABET, '').slice(0, CODE_LENGTH);
}

/** `K7QM-2XWD` as the server prints it. @param {string} input */
export function displayCode(input) {
  const code = normaliseCode(input);
  return code.length > 4 ? `${code.slice(0, 4)}-${code.slice(4)}` : code;
}

function platformRejected(error) {
  if (!(error instanceof ApiError) || error.status !== 422) return false;
  const problems = error.detail?.errors;
  return Array.isArray(problems) && problems.some((item) => String(item?.field || '').endsWith('platform'));
}

/** Pair this browser. Registers as platform `web` when the server knows it, otherwise as `ios`
 * (a request the server rejects for its platform never reaches the pairing code, so the code is
 * still good for the second try).
 * @param {{client: any, identity: any, code: string, deviceName: string}} options */
export async function pairDevice({ client, identity, code, deviceName }) {
  const pairingCode = normaliseCode(code);
  if (pairingCode.length !== CODE_LENGTH) {
    throw new ApiError({
      status: 400,
      code: 'pairing_code_incomplete',
      message: 'The pairing code has 8 letters and digits.',
    });
  }
  const keys = await identity.createKeys();
  let lastError = null;
  for (const platform of PLATFORM_PREFERENCE) {
    try {
      const paired = await client.pair({
        pairing_code: pairingCode,
        device_name: deviceName,
        platform,
        auth_public_key_b64: keys.authPublicKeyB64,
        approval_public_key_b64: keys.approvalPublicKeyB64,
        capabilities: [...WEB_CAPABILITIES],
        app_version: APP_VERSION,
      });
      return identity.commitPairing({
        deviceId: paired.device_id,
        serverName: paired.server_name,
        platform,
        deviceName,
        keys,
      });
    } catch (error) {
      if (!platformRejected(error)) throw error;
      lastError = error;
    }
  }
  throw lastError;
}

/** A short name for this browser, shown in the device list of the native apps.
 * @param {{userAgent?: string, platform?: string, maxTouchPoints?: number}} [nav] */
export function defaultDeviceName(nav = globalThis.navigator || {}) {
  const ua = nav.userAgent || '';
  let device = '';
  if (/iPhone/.test(ua)) device = 'iPhone';
  else if (/iPad/.test(ua) || (/Macintosh/.test(ua) && (nav.maxTouchPoints || 0) > 1)) device = 'iPad';
  else if (/Macintosh/.test(ua)) device = 'Mac';
  else if (/Android/.test(ua)) device = 'Android';
  else if (/Windows/.test(ua)) device = 'Windows PC';
  return device ? `ZORO web app (${device})` : 'ZORO web app';
}
