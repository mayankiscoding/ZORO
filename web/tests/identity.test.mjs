// Keys, pairing and the sealed cache: what is stored, what can never be read back, and what the
// web app refuses to sign.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ApiError } from '../js/core/api.js';
import { base64ToBytes } from '../js/core/bytes.js';
import { canSignApproval, DeviceIdentity, IdentityError, WEB_CAPABILITIES } from '../js/core/identity.js';
import { defaultDeviceName, displayCode, normaliseCode, pairDevice } from '../js/core/pairing.js';
import { DEFAULT_PREFS, Prefs, sanitizePrefs, shouldReduceMotion } from '../js/core/prefs.js';
import { SealedCache } from '../js/core/sealed-cache.js';
import { MemoryStore } from '../js/core/store.js';

const { subtle } = globalThis.crypto;

async function paired(now) {
  const store = new MemoryStore();
  const identity = new DeviceIdentity({ store, now });
  const keys = await identity.createKeys();
  await identity.commitPairing({ deviceId: 'dev_1', serverName: 'ZORO', platform: 'web', deviceName: 'Test', keys });
  return { identity, store, keys };
}

test('private keys are non-extractable and are the only secret in the stored record', async () => {
  const { store, keys } = await paired();
  const record = await store.get('device');
  assert.equal(record.authPrivateKey.type, 'private');
  assert.equal(record.authPrivateKey.extractable, false);
  await assert.rejects(subtle.exportKey('pkcs8', record.authPrivateKey));
  await assert.rejects(subtle.exportKey('jwk', record.authPrivateKey));
  // No approval private key is kept anywhere: this device cannot make a user-presence signature.
  const cryptoKeys = Object.values(record).filter((value) => value instanceof CryptoKey);
  assert.equal(cryptoKeys.length, 1);
  assert.equal(record.approvalPublicKeyB64, keys.approvalPublicKeyB64);
  assert.equal('approvalPrivateKey' in record, false);
  // The record holds no token and no pairing code.
  assert.deepEqual(Object.keys(record).sort(), ['approvalPublicKeyB64', 'authPrivateKey', 'authPublicKeyB64', 'deviceId', 'deviceName', 'pairedAt', 'platform', 'serverName']);
});

test('an extractable key is refused at commit', async () => {
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const weak = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  await assert.rejects(
    identity.commitPairing({ deviceId: 'd', serverName: 's', platform: 'web', deviceName: 'n', keys: { authPrivateKey: weak.privateKey, authPublicKeyB64: 'x', approvalPublicKeyB64: 'y' } }),
    (error) => error instanceof IdentityError && error.code === 'key_extractable',
  );
});

test('describe() gives the pairing facts without the key; forget() removes everything', async () => {
  const { identity, store } = await paired();
  const facts = await identity.describe();
  assert.equal(facts.deviceId, 'dev_1');
  assert.equal('authPrivateKey' in facts, false);
  await identity.forget();
  assert.equal(await identity.isPaired(), false);
  assert.equal(await store.get('device'), undefined);
  await assert.rejects(identity.signChallenge('n'), (error) => error.code === 'not_paired');
});

test('only confirm-level approvals are signed; biometric is refused before any signature exists', async () => {
  const { identity } = await paired(() => new Date('2026-11-13T06:30:00Z'));
  const base = { approval_id: 'apr_1', action_digest: 'e'.repeat(64), expires_at: '2026-11-13T06:35:00Z' };
  let signCalls = 0;
  const original = identity.sign.bind(identity);
  identity.sign = (...args) => {
    signCalls += 1;
    return original(...args);
  };
  for (const level of ['biometric', 'none', undefined, 'CONFIRM']) {
    await assert.rejects(identity.signApproval({ ...base, level }, true), (error) => error instanceof IdentityError && error.code === 'needs_user_presence_key');
    // Declining a biometric request needs the same key, so that is refused too.
    await assert.rejects(identity.signApproval({ ...base, level }, false), (error) => error.code === 'needs_user_presence_key');
  }
  assert.equal(signCalls, 0);
  assert.equal(canSignApproval({ level: 'confirm' }), true);
  assert.equal(canSignApproval({ level: 'biometric' }), false);
  assert.equal(canSignApproval(null), false);

  const decision = await identity.signApproval({ ...base, level: 'confirm' }, true);
  assert.deepEqual(Object.keys(decision).sort(), ['action_digest', 'approval_id', 'approved', 'device_id', 'signature_b64', 'signed_at']);
  assert.equal(decision.device_id, 'dev_1');
  assert.equal(decision.signed_at, '2026-11-13T06:30:00Z');
  assert.equal(signCalls, 1);
});

test('an expired approval is not signed', async () => {
  const { identity } = await paired(() => new Date('2026-11-13T06:40:00Z'));
  await assert.rejects(
    identity.signApproval({ approval_id: 'apr_1', action_digest: 'e'.repeat(64), level: 'confirm', expires_at: '2026-11-13T06:35:00Z' }, true),
    (error) => error.code === 'approval_expired',
  );
});

test('the web app declares only the two link capabilities', () => {
  assert.deepEqual([...WEB_CAPABILITIES], ['device.open_url', 'device.whatsapp.compose']);
  assert.ok(Object.isFrozen(WEB_CAPABILITIES));
});

// ---------------------------------------------------------------- pairing

function pairingClient(script) {
  const calls = [];
  return {
    calls,
    async pair(body) {
      calls.push(body);
      const step = script[calls.length - 1];
      if (step instanceof Error) throw step;
      return step;
    },
  };
}

const platformRejected = () =>
  new ApiError({ status: 422, code: 'validation_error', message: 'not valid', detail: { errors: [{ field: 'body.platform', problem: "Input should be 'ios' or 'macos'" }] } });

test('pairing registers as web when the server knows it', async () => {
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const client = pairingClient([{ device_id: 'dev_w', server_name: 'ZORO', server_time: '2026-11-13T06:30:00Z' }]);
  const record = await pairDevice({ client, identity, code: 'k7qm-2xwd', deviceName: 'ZORO web app (iPhone)' });
  assert.equal(record.platform, 'web');
  assert.equal(client.calls.length, 1);
  const body = client.calls[0];
  assert.equal(body.pairing_code, 'K7QM2XWD');
  assert.equal(body.platform, 'web');
  assert.deepEqual(body.capabilities, ['device.open_url', 'device.whatsapp.compose']);
  assert.equal(base64ToBytes(body.auth_public_key_b64).length, 65);
  assert.equal(base64ToBytes(body.approval_public_key_b64).length, 65);
  assert.notEqual(body.auth_public_key_b64, body.approval_public_key_b64);
  assert.equal(await identity.isPaired(), true);
});

test('a server that does not know the web platform yet is paired as ios with the same keys and code', async () => {
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const client = pairingClient([platformRejected(), { device_id: 'dev_i', server_name: 'ZORO', server_time: 'x' }]);
  const record = await pairDevice({ client, identity, code: 'K7QM-2XWD', deviceName: 'n' });
  assert.equal(record.platform, 'ios');
  assert.deepEqual(client.calls.map((call) => call.platform), ['web', 'ios']);
  assert.equal(client.calls[0].auth_public_key_b64, client.calls[1].auth_public_key_b64);
  assert.equal(client.calls[0].pairing_code, client.calls[1].pairing_code);
});

test('a wrong code, a short code and an unreachable server store nothing', async () => {
  const wrong = new ApiError({ status: 400, code: 'pairing_code_invalid', message: 'no' });
  for (const [script, code, expected] of [
    [[wrong], 'AAAA-BBBB', 'pairing_code_invalid'],
    [[], 'AAAA', 'pairing_code_incomplete'],
    [[new ApiError({ status: 0, code: 'unreachable', message: 'x', retryable: true })], 'AAAA-BBBB', 'unreachable'],
  ]) {
    const identity = new DeviceIdentity({ store: new MemoryStore() });
    const client = pairingClient(script);
    await assert.rejects(pairDevice({ client, identity, code, deviceName: 'n' }), (error) => error.code === expected);
    assert.equal(await identity.isPaired(), false);
    if (expected === 'pairing_code_invalid') assert.equal(client.calls.length, 1); // not retried as ios
  }
});

test('codes are normalised as the server does, and shown as it prints them', () => {
  assert.equal(normaliseCode(' k7qm-2xwd '), 'K7QM2XWD');
  assert.equal(normaliseCode('K7QM 2XWD 99'), 'K7QM2XWD');
  assert.equal(displayCode('k7qm2xwd'), 'K7QM-2XWD');
  assert.equal(displayCode('k7q'), 'K7Q');
  assert.equal(defaultDeviceName({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' }), 'ZORO web app (iPhone)');
  assert.equal(defaultDeviceName({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 0 }), 'ZORO web app (Mac)');
  assert.equal(defaultDeviceName({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 5 }), 'ZORO web app (iPad)');
  assert.equal(defaultDeviceName({ userAgent: 'something else' }), 'ZORO web app');
});

// ---------------------------------------------------------------- sealed cache

test('the conversation cache is sealed: no plaintext at rest, a non-extractable AES-GCM key', async () => {
  const keyStore = new MemoryStore();
  const cacheStore = new MemoryStore();
  const cache = new SealedCache({ keyStore, cacheStore });
  const secret = { conversationId: 'conv_1', messages: [{ text: 'my favourite tea is masala chai — मसाला चाय' }] };
  await cache.put('conversation', secret);
  assert.deepEqual(await cache.get('conversation'), secret);

  const stored = await cacheStore.get('conversation');
  assert.deepEqual(Object.keys(stored).sort(), ['data', 'iv', 'v']);
  const visible = JSON.stringify(stored) + Buffer.from(stored.data, 'base64').toString('latin1') + Buffer.from(stored.data, 'base64').toString('utf8');
  assert.ok(!visible.includes('masala') && !visible.includes('conv_1') && !visible.includes('मसाला'));

  const key = await keyStore.get('cache-key');
  assert.equal(key.algorithm.name, 'AES-GCM');
  assert.equal(key.algorithm.length, 256);
  assert.equal(key.extractable, false);
  await assert.rejects(subtle.exportKey('raw', key));
});

test('each write uses a fresh nonce; a record moved under another name or altered is dropped', async () => {
  const keyStore = new MemoryStore();
  const cacheStore = new MemoryStore();
  const cache = new SealedCache({ keyStore, cacheStore });
  await cache.put('a', { n: 1 });
  const first = await cacheStore.get('a');
  await cache.put('a', { n: 1 });
  const second = await cacheStore.get('a');
  assert.notEqual(first.iv, second.iv);
  assert.notEqual(first.data, second.data);

  await cacheStore.set('b', second); // moved: the name is bound in as additional data
  assert.equal(await cache.get('b'), null);
  assert.equal(await cacheStore.get('b'), undefined);

  const bytes = Buffer.from(second.data, 'base64');
  bytes[0] ^= 1;
  await cacheStore.set('a', { ...second, data: bytes.toString('base64') });
  assert.equal(await cache.get('a'), null);
});

test('destroy() deletes the key, so anything left behind is unreadable', async () => {
  const keyStore = new MemoryStore();
  const cacheStore = new MemoryStore();
  const cache = new SealedCache({ keyStore, cacheStore });
  await cache.put('conversation', { text: 'private' });
  const leftover = await cacheStore.get('conversation');
  await cache.destroy();
  assert.equal(await keyStore.get('cache-key'), undefined);
  assert.deepEqual(await cacheStore.keys(), []);
  await cacheStore.set('conversation', leftover); // as if the delete had been interrupted
  const reopened = new SealedCache({ keyStore, cacheStore });
  assert.equal(await reopened.get('conversation'), null);
  assert.equal(await reopened.get('missing'), null);
});

// ---------------------------------------------------------------- preferences (the only localStorage use)

function fakeStorage() {
  const map = new Map();
  return { map, getItem: (key) => map.get(key) ?? null, setItem: (key, value) => map.set(key, String(value)), removeItem: (key) => map.delete(key) };
}

test('preferences hold interface choices only, validate what they read, and survive bad storage', () => {
  const storage = fakeStorage();
  const prefs = new Prefs({ storage });
  assert.deepEqual(prefs.all, { ...DEFAULT_PREFS });
  const changes = [];
  prefs.subscribe((_all, changed) => changes.push(changed));
  prefs.set({ lang: 'hi', rate: 1.2, reduceMotion: 'on' });
  prefs.set({ lang: 'hi' }); // no change, no event
  assert.deepEqual(changes, [['lang', 'rate', 'reduceMotion']]);
  assert.deepEqual([...storage.map.keys()], ['zoro.prefs.v1']);
  const saved = JSON.parse(storage.map.get('zoro.prefs.v1'));
  assert.deepEqual(Object.keys(saved).sort(), Object.keys(DEFAULT_PREFS).sort());
  for (const forbidden of ['token', 'deviceId', 'device_id', 'key', 'conversation', 'messages', 'nonce']) {
    assert.equal(forbidden in saved, false);
  }
  assert.equal(new Prefs({ storage }).get('lang'), 'hi');

  assert.deepEqual(sanitizePrefs({ lang: 'xx', rate: 9, extra: 'token-abc', speakReplies: 'always' }), { ...DEFAULT_PREFS, speakReplies: 'always' });
  storage.map.set('zoro.prefs.v1', '{not json');
  assert.deepEqual(new Prefs({ storage }).all, { ...DEFAULT_PREFS });
  const blocked = new Prefs({ storage: { getItem() { throw new Error('blocked'); }, setItem() { throw new Error('blocked'); }, removeItem() {} } });
  blocked.set({ lang: 'hi' });
  assert.equal(blocked.get('lang'), 'hi');
  prefs.reset();
  assert.equal(storage.map.size, 0);
});

test('reduced motion follows the preference, then the device', () => {
  assert.equal(shouldReduceMotion('system', true), true);
  assert.equal(shouldReduceMotion('system', false), false);
  assert.equal(shouldReduceMotion('on', false), true);
  assert.equal(shouldReduceMotion('off', true), false);
});
