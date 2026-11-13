// The signed strings, checked against vectors written by the backend's own functions
// (web/tools/make_vectors.py -> tests/vectors/signing.json), and signatures checked both ways:
// Python-made DER verifies in WebCrypto after conversion, and browser-made signatures verify in
// the server's `verify_signature` (run from the backend virtualenv when it is present).

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { base64ToBytes, bytesToBase64, utf8 } from '../js/core/bytes.js';
import { derSignatureToRaw } from '../js/core/der.js';
import { DeviceIdentity } from '../js/core/identity.js';
import { actionMessage, approvalMessage, authMessage, isoSeconds, signingTime } from '../js/core/signing.js';
import { MemoryStore } from '../js/core/store.js';
import { BACKEND_DIR, BACKEND_PYTHON, backendAvailable } from './helpers/backend.mjs';

const vectors = JSON.parse(readFileSync(new URL('./vectors/signing.json', import.meta.url), 'utf8'));
const { subtle } = globalThis.crypto;

test('the vector file came from the backend functions and covers every signed string', () => {
  assert.match(vectors.generated_by, /backend\/app\/security\/crypto\.py/);
  assert.ok(vectors.auth.length >= 3);
  assert.ok(vectors.approval.length >= 4);
  assert.ok(vectors.action.length >= 4);
  assert.ok(vectors.timestamps.length >= 5);
});

test('authMessage matches auth_message', () => {
  for (const vector of vectors.auth) {
    assert.equal(authMessage(vector.device_id, vector.nonce), vector.message);
  }
});

test('approvalMessage matches approval_message, for approve and decline', () => {
  assert.ok(vectors.approval.some((vector) => vector.approved) && vectors.approval.some((vector) => !vector.approved));
  for (const vector of vectors.approval) {
    assert.equal(
      approvalMessage(vector.approval_id, vector.action_digest, vector.approved, vector.signed_at),
      vector.message,
    );
  }
});

test('actionMessage matches action_message', () => {
  for (const vector of vectors.action) {
    assert.equal(actionMessage(vector.action, vector.subject, vector.signed_at), vector.message);
  }
});

test('isoSeconds matches iso_seconds: UTC, whole seconds, offsets and fractions folded in', () => {
  for (const vector of vectors.timestamps) {
    assert.equal(isoSeconds(vector.input), vector.iso_seconds);
    assert.equal(isoSeconds(new Date(vector.input)), vector.iso_seconds);
  }
  assert.throws(() => isoSeconds('not a time'), RangeError);
});

test('signingTime cuts to the second, so signed_at and the signed string name the same instant', () => {
  const cut = signingTime(new Date('2026-11-13T06:30:00.999Z'));
  assert.equal(cut.toISOString(), '2026-11-13T06:30:00.000Z');
  assert.equal(isoSeconds(cut), '2026-11-13T06:30:00Z');
  // What the server does with the `signed_at` it receives: parse, then iso_seconds.
  assert.equal(isoSeconds(new Date(isoSeconds(cut))), isoSeconds(cut));
});

test('DER signatures made by the Python library verify in WebCrypto after conversion', async () => {
  const signed = vectors.python_signed;
  const key = await subtle.importKey(
    'raw',
    base64ToBytes(signed.public_key_x963_b64),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
  assert.ok(signed.signatures.length >= 3);
  for (const item of signed.signatures) {
    const raw = derSignatureToRaw(base64ToBytes(item.signature_der_b64));
    assert.equal(await subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, raw, utf8(item.message)), true);
    assert.equal(await subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, raw, utf8(`${item.message}x`)), false);
  }
});

test('public keys leave the browser as base64 of the 65-byte X9.63 point', async () => {
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const keys = await identity.createKeys();
  for (const b64 of [keys.authPublicKeyB64, keys.approvalPublicKeyB64]) {
    const point = base64ToBytes(b64);
    assert.equal(point.length, 65);
    assert.equal(point[0], 0x04);
    assert.equal(bytesToBase64(point), b64);
    assert.match(b64, /^[A-Za-z0-9+/]+=*$/); // standard alphabet with padding: b64decode(validate=True)
  }
  assert.notEqual(keys.authPublicKeyB64, keys.approvalPublicKeyB64);
});

test("the server's verify_signature accepts what DeviceIdentity signs", { skip: !backendAvailable() && 'backend virtualenv not present' }, async () => {
  const identity = new DeviceIdentity({ store: new MemoryStore(), now: () => new Date('2026-11-13T06:30:00.400Z') });
  const keys = await identity.createKeys();
  await identity.commitPairing({ deviceId: 'dev_vector', serverName: 'ZORO', platform: 'web', deviceName: 'test', keys });

  const challenge = await identity.signChallenge('n0nce-AbC_123');
  const approval = { approval_id: 'apr_1', action_digest: 'c'.repeat(64), level: 'confirm', expires_at: '2026-11-13T06:35:00Z' };
  const approve = await identity.signApproval(approval, true);
  const decline = await identity.signApproval(approval, false);
  const items = [
    // accepted
    { public_key_b64: keys.authPublicKeyB64, message: authMessage('dev_vector', 'n0nce-AbC_123'), signature_b64: challenge.signature_b64 },
    { public_key_b64: keys.authPublicKeyB64, message: approvalMessage('apr_1', approval.action_digest, true, approve.signed_at), signature_b64: approve.signature_b64 },
    { public_key_b64: keys.authPublicKeyB64, message: approvalMessage('apr_1', approval.action_digest, false, decline.signed_at), signature_b64: decline.signature_b64 },
    // refused: an approve signature offered for the decline string, the wrong key, another digest
    { public_key_b64: keys.authPublicKeyB64, message: approvalMessage('apr_1', approval.action_digest, false, approve.signed_at), signature_b64: approve.signature_b64 },
    { public_key_b64: keys.approvalPublicKeyB64, message: approvalMessage('apr_1', approval.action_digest, true, approve.signed_at), signature_b64: approve.signature_b64 },
    { public_key_b64: keys.authPublicKeyB64, message: approvalMessage('apr_1', 'd'.repeat(64), true, approve.signed_at), signature_b64: approve.signature_b64 },
  ];
  assert.equal(approve.signed_at, '2026-11-13T06:30:00Z');

  const run = spawnSync(BACKEND_PYTHON, ['../web/tools/verify_signature.py'], {
    cwd: BACKEND_DIR,
    input: JSON.stringify(items),
    encoding: 'utf8',
    env: { PATH: process.env.PATH ?? '/usr/bin:/bin', PYTHONPATH: '.', PYTHONDONTWRITEBYTECODE: '1', ZORO_ENV: 'test' },
  });
  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(JSON.parse(run.stdout), [true, true, true, false, false, false]);
});
