// Conversation cache, sealed at rest.
//
// The last conversation is kept on the device so Home is not empty while the server is asleep.
// It holds the owner's words, so every record is encrypted with AES-256-GCM under a key that is
// generated non-extractable and lives only as a CryptoKey in IndexedDB. Each record is bound to
// its name through the additional data, so a record cannot be moved under another name.
// Forgetting the pairing deletes the key, which makes whatever is left unreadable.

import { bytesToBase64, base64ToBytes, fromUtf8, utf8 } from './bytes.js';

const KEY_NAME = 'cache-key';
const AAD_PREFIX = 'zoro-web-cache-v1|';
const IV_BYTES = 12;

export class SealedCache {
  /** @param {{keyStore: any, cacheStore: any, crypto?: Crypto}} options
   * `keyStore` holds the CryptoKey, `cacheStore` the sealed records. */
  constructor({ keyStore, cacheStore, crypto = globalThis.crypto }) {
    this._keys = keyStore;
    this._records = cacheStore;
    this._crypto = crypto;
    this._key = null;
  }

  async _cipherKey(create) {
    if (this._key) return this._key;
    let key = await this._keys.get(KEY_NAME);
    if (!key && create) {
      key = await this._crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, [
        'encrypt',
        'decrypt',
      ]);
      await this._keys.set(KEY_NAME, key);
    }
    this._key = key || null;
    return this._key;
  }

  /** @param {string} name @param {unknown} value any JSON value */
  async put(name, value) {
    const key = await this._cipherKey(true);
    const iv = this._crypto.getRandomValues(new Uint8Array(IV_BYTES));
    const sealed = await this._crypto.subtle.encrypt(
      { name: 'AES-GCM', iv, additionalData: utf8(AAD_PREFIX + name) },
      key,
      utf8(JSON.stringify(value)),
    );
    await this._records.set(name, { v: 1, iv: bytesToBase64(iv), data: bytesToBase64(sealed) });
  }

  /** @param {string} name @returns {Promise<any | null>} null when absent or unreadable */
  async get(name) {
    const record = await this._records.get(name);
    if (!record || record.v !== 1) return null;
    const key = await this._cipherKey(false);
    if (!key) return null;
    try {
      const plain = await this._crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: base64ToBytes(record.iv), additionalData: utf8(AAD_PREFIX + name) },
        key,
        base64ToBytes(record.data),
      );
      return JSON.parse(fromUtf8(plain));
    } catch {
      await this._records.delete(name); // tampered, moved or sealed under a lost key
      return null;
    }
  }

  async remove(name) {
    await this._records.delete(name);
  }

  /** Drop every record and the key itself. */
  async destroy() {
    await this._records.clear();
    await this._keys.delete(KEY_NAME);
    this._key = null;
  }
}
