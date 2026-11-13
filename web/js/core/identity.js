// This device's identity: an ECDSA P-256 auth key made with WebCrypto.
//
// - The private key is generated non-extractable and kept in IndexedDB as a CryptoKey, so page
//   script (including an injected script) can ask the browser to sign with it but can never
//   read it or copy it elsewhere.
// - Public keys travel as base64 of the 65-byte X9.63 uncompressed point (WebCrypto "raw").
// - Signatures are converted from WebCrypto's raw r || s to DER, base64.
//
// What a browser cannot give: a hardware-backed key whose use requires Face ID or Touch ID.
// The contract still asks for a second ("approval") public key at pairing, so one is generated,
// its public half is registered, and its private half is thrown away before pairing finishes.
// This device can therefore never produce a `biometric` approval or a security-settings proof,
// whatever script runs in the page. It signs `confirm` approvals only, with the auth key.

import { bytesToBase64, utf8 } from './bytes.js';
import { rawSignatureToDer } from './der.js';
import { approvalMessage, authMessage, isoSeconds, signingTime } from './signing.js';

const RECORD_KEY = 'device';
const ECDSA_PARAMS = Object.freeze({ name: 'ECDSA', namedCurve: 'P-256' });
const SIGN_PARAMS = Object.freeze({ name: 'ECDSA', hash: 'SHA-256' });

/** Device tools this web app can honestly carry out: both only hand the owner a link to tap. */
export const WEB_CAPABILITIES = Object.freeze(['device.open_url', 'device.whatsapp.compose']);

/** Platforms to register as, in order. `web` is the honest answer; the backend contract today
 * only knows `ios` and `macos`, so pairing falls back until `web` exists there. */
export const PLATFORM_PREFERENCE = Object.freeze(['web', 'ios']);

export class IdentityError extends Error {
  /** @param {string} code @param {string} message */
  constructor(code, message) {
    super(message);
    this.name = 'IdentityError';
    this.code = code;
  }
}

/** @typedef {{deviceId: string, serverName: string, platform: string, deviceName: string,
 *   pairedAt: string, authPublicKeyB64: string, approvalPublicKeyB64: string,
 *   authPrivateKey: CryptoKey}} DeviceRecord */

export class DeviceIdentity {
  /** @param {{store: {get: Function, set: Function, delete: Function}, subtle?: SubtleCrypto,
   *   now?: () => Date}} options */
  constructor({ store, subtle = globalThis.crypto?.subtle, now = () => new Date() }) {
    if (!subtle) {
      throw new IdentityError(
        'webcrypto_unavailable',
        'This browser has no WebCrypto here. Open ZORO over HTTPS.',
      );
    }
    this._store = store;
    this._subtle = subtle;
    this._now = now;
    /** @type {DeviceRecord | null | undefined} */
    this._record = undefined;
  }

  /** @returns {Promise<DeviceRecord | null>} */
  async load() {
    if (this._record === undefined) {
      const record = await this._store.get(RECORD_KEY);
      this._record = record && record.deviceId && record.authPrivateKey ? record : null;
    }
    return this._record;
  }

  async isPaired() {
    return (await this.load()) !== null;
  }

  /** Public facts about the pairing (never the key). */
  async describe() {
    const record = await this.load();
    if (!record) return null;
    const { authPrivateKey: _private, ...facts } = record;
    return facts;
  }

  /** Make the keys for a new pairing. Nothing is stored until `commitPairing`.
   * @returns {Promise<{authPrivateKey: CryptoKey, authPublicKeyB64: string, approvalPublicKeyB64: string}>} */
  async createKeys() {
    const auth = await this._subtle.generateKey(ECDSA_PARAMS, false, ['sign', 'verify']);
    const approval = await this._subtle.generateKey(ECDSA_PARAMS, false, ['sign', 'verify']);
    const authPublicKeyB64 = bytesToBase64(await this._subtle.exportKey('raw', auth.publicKey));
    const approvalPublicKeyB64 = bytesToBase64(await this._subtle.exportKey('raw', approval.publicKey));
    // `approval.privateKey` goes out of scope here and is never stored: see the header comment.
    return { authPrivateKey: auth.privateKey, authPublicKeyB64, approvalPublicKeyB64 };
  }

  /** Store the pairing the server accepted.
   * @param {{deviceId: string, serverName: string, platform: string, deviceName: string,
   *   keys: {authPrivateKey: CryptoKey, authPublicKeyB64: string, approvalPublicKeyB64: string}}} pairing */
  async commitPairing({ deviceId, serverName, platform, deviceName, keys }) {
    if (keys.authPrivateKey.extractable) {
      throw new IdentityError('key_extractable', 'Refusing to store an extractable private key.');
    }
    /** @type {DeviceRecord} */
    const record = {
      deviceId,
      serverName,
      platform,
      deviceName,
      pairedAt: this._now().toISOString(),
      authPublicKeyB64: keys.authPublicKeyB64,
      approvalPublicKeyB64: keys.approvalPublicKeyB64,
      authPrivateKey: keys.authPrivateKey,
    };
    await this._store.set(RECORD_KEY, record);
    this._record = record;
    return record;
  }

  /** Forget the pairing on this device. The server keeps the device listed until it is revoked
   * from an app that holds a user-presence key; without the private key it can do nothing. */
  async forget() {
    await this._store.delete(RECORD_KEY);
    this._record = null;
  }

  async _require() {
    const record = await this.load();
    if (!record) throw new IdentityError('not_paired', 'This browser is not paired with a ZORO server.');
    return record;
  }

  /** DER signature, base64, over SHA-256 of the UTF-8 `message`, made with the auth key.
   * @param {string} message @param {CryptoKey} [privateKey] */
  async sign(message, privateKey) {
    const key = privateKey ?? (await this._require()).authPrivateKey;
    const raw = await this._subtle.sign(SIGN_PARAMS, key, utf8(message));
    return bytesToBase64(rawSignatureToDer(new Uint8Array(raw)));
  }

  /** Body of `POST /v1/auth/token` for a challenge nonce.
   * @param {string} nonce */
  async signChallenge(nonce) {
    const record = await this._require();
    return {
      device_id: record.deviceId,
      nonce,
      signature_b64: await this.sign(authMessage(record.deviceId, nonce)),
    };
  }

  /** A signed `ApprovalDecision` for a `confirm`-level request. Anything else is refused here,
   * before any signature exists: the owner is told to use the iPhone or Mac app.
   * @param {{approval_id: string, action_digest: string, level: string, expires_at?: string}} approval
   * @param {boolean} approved */
  async signApproval(approval, approved) {
    if (approval.level !== 'confirm') {
      throw new IdentityError(
        'needs_user_presence_key',
        'This approval needs Face ID or Touch ID. Answer it in the ZORO app on your iPhone or Mac.',
      );
    }
    const record = await this._require();
    const signedAt = signingTime(this._now());
    if (approval.expires_at && new Date(approval.expires_at).getTime() <= signedAt.getTime()) {
      throw new IdentityError('approval_expired', 'This approval request expired. Ask again to get a new one.');
    }
    const message = approvalMessage(approval.approval_id, approval.action_digest, approved, signedAt);
    return {
      approval_id: approval.approval_id,
      approved,
      action_digest: approval.action_digest,
      device_id: record.deviceId,
      signed_at: isoSeconds(signedAt),
      signature_b64: await this.sign(message),
    };
  }
}

/** True when this device may answer the approval itself (level `confirm`).
 * @param {{level?: string} | null | undefined} approval */
export function canSignApproval(approval) {
  return Boolean(approval) && approval.level === 'confirm';
}
