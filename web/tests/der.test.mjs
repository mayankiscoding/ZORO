// DER conversion, verified the way the server verifies: `ECDSA(SHA-256)` over the UTF-8 message
// with a DER signature and the public key loaded from its X9.63 uncompressed point.

import assert from 'node:assert/strict';
import { createPublicKey, createVerify, verify as verifyOneShot } from 'node:crypto';
import { test } from 'node:test';

import { base64ToBytes, bytesToBase64, utf8 } from '../js/core/bytes.js';
import { derSignatureToRaw, rawSignatureToDer } from '../js/core/der.js';

const { subtle } = globalThis.crypto;

function hex(text) {
  return Uint8Array.from(text.match(/../g).map((pair) => Number.parseInt(pair, 16)));
}

function toHex(bytes) {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

/** Node public key from the wire format the server stores (base64 X9.63 point). */
function publicKeyFromX963(pointB64) {
  const point = base64ToBytes(pointB64);
  assert.equal(point.length, 65);
  assert.equal(point[0], 0x04);
  const b64url = (bytes) => Buffer.from(bytes).toString('base64url');
  return createPublicKey({
    key: { kty: 'EC', crv: 'P-256', x: b64url(point.subarray(1, 33)), y: b64url(point.subarray(33)) },
    format: 'jwk',
  });
}

async function browserStyleKey() {
  const pair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
  const pointB64 = bytesToBase64(await subtle.exportKey('raw', pair.publicKey));
  return { pair, pointB64 };
}

test('known encodings: small values, high bit, leading zeros', () => {
  const one = new Uint8Array(64);
  one[31] = 1;
  one[63] = 2;
  assert.equal(toHex(rawSignatureToDer(one)), '3006020101020102');

  const high = new Uint8Array(64).fill(0xff);
  const der = rawSignatureToDer(high);
  assert.equal(der.length, 72); // 2 + (2 + 33) * 2
  assert.equal(toHex(der.subarray(0, 5)), '3046022100');
  assert.deepEqual(derSignatureToRaw(der), high);

  const mixed = new Uint8Array(64);
  mixed.set(hex('00007f'), 0); // r starts with zero bytes then 0x7f: no padding needed
  mixed.fill(0x11, 3, 32);
  mixed.set(hex('0080'), 32); // s starts with a zero byte then 0x80: needs one 0x00 back
  mixed.fill(0x22, 34, 64);
  const mixedDer = rawSignatureToDer(mixed);
  assert.equal(mixedDer[3], 30); // r: 32 - 2 leading zeros
  assert.equal(mixedDer[4], 0x7f);
  assert.equal(mixedDer[4 + 30 + 1], 32); // s: 31 significant bytes + 0x00 pad
  assert.equal(mixedDer[4 + 30 + 2], 0x00);
  assert.deepEqual(derSignatureToRaw(mixedDer), mixed);
});

test('an all-zero half encodes as INTEGER 0 and round-trips', () => {
  const raw = new Uint8Array(64);
  raw[63] = 9;
  assert.equal(toHex(rawSignatureToDer(raw)), '3006020100020109');
  assert.deepEqual(derSignatureToRaw(rawSignatureToDer(raw)), raw);
});

test('wrong raw length is refused', () => {
  assert.throws(() => rawSignatureToDer(new Uint8Array(63)), RangeError);
  assert.throws(() => rawSignatureToDer(new Uint8Array(65)), RangeError);
  assert.throws(() => rawSignatureToDer(new Uint8Array(0)), RangeError);
});

test('strict DER parsing: trailing bytes, wrong tags, negative, non-minimal, too wide, truncated', () => {
  const good = rawSignatureToDer(new Uint8Array(64).fill(0x42));
  assert.throws(() => derSignatureToRaw(Uint8Array.of(...good, 0)), RangeError);
  assert.throws(() => derSignatureToRaw(Uint8Array.of(0x31, ...good.subarray(1))), RangeError);
  assert.throws(() => derSignatureToRaw(hex('3006028001020101')), RangeError); // indefinite-style length
  assert.throws(() => derSignatureToRaw(hex('3006020180020101')), RangeError); // negative r
  assert.throws(() => derSignatureToRaw(hex('300702020001020101')), RangeError); // 0x00 0x01 is not minimal
  assert.throws(() => derSignatureToRaw(good.subarray(0, good.length - 3)), RangeError);
  assert.throws(() => derSignatureToRaw(hex('3006030101020101')), RangeError); // BIT STRING, not INTEGER
  const wide = Uint8Array.of(0x30, 0x26, 0x02, 0x21, 0x01, ...new Uint8Array(32), 0x02, 0x01, 0x01);
  assert.throws(() => derSignatureToRaw(wide), RangeError); // 33 significant bytes
});

test('a browser-style signature verifies with node:crypto exactly as the server would', async () => {
  const { pair, pointB64 } = await browserStyleKey();
  assert.equal(pair.privateKey.extractable, false);
  const publicKey = publicKeyFromX963(pointB64);
  const messages = [
    'zoro-auth-v1|dev_01HZXK3V9Q|n0nce-AbC_123',
    'zoro-approval-v1|apr_01HZXK3V9Q|' + 'a'.repeat(64) + '|1|2026-11-13T06:30:00Z',
    'नमस्ते ZORO | ₹1,23,456.50',
  ];
  for (const message of messages) {
    for (let round = 0; round < 40; round += 1) {
      const raw = new Uint8Array(await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, utf8(message)));
      assert.equal(raw.length, 64);
      const der = rawSignatureToDer(raw);
      // DER, SHA-256, UTF-8 bytes: what `cryptography`'s `key.verify(sig, msg, ECDSA(SHA256()))` checks.
      assert.equal(createVerify('SHA256').update(Buffer.from(utf8(message))).verify(publicKey, der), true);
      assert.equal(verifyOneShot('sha256', utf8(message), { key: publicKey, dsaEncoding: 'der' }, der), true);
      assert.deepEqual(derSignatureToRaw(der), raw);
      // The raw form is not accepted where DER is expected: the conversion is not optional.
      assert.equal(createVerify('SHA256').update(Buffer.from(utf8(message))).verify(publicKey, raw), false);
    }
  }
});

test('a signature over one message does not verify another, and a flipped bit is refused', async () => {
  const { pair, pointB64 } = await browserStyleKey();
  const publicKey = publicKeyFromX963(pointB64);
  const raw = new Uint8Array(await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, utf8('approve')));
  const der = rawSignatureToDer(raw);
  assert.equal(createVerify('SHA256').update('decline').verify(publicKey, der), false);
  const tampered = Uint8Array.from(raw);
  tampered[40] ^= 0x01;
  assert.equal(createVerify('SHA256').update('approve').verify(publicKey, rawSignatureToDer(tampered)), false);
});

test('signatures with short r or s (leading zero bytes) still convert and verify', async () => {
  const { pair, pointB64 } = await browserStyleKey();
  const publicKey = publicKeyFromX963(pointB64);
  let shortSeen = 0;
  for (let i = 0; i < 1500 && shortSeen < 3; i += 1) {
    const message = `short-${i}`;
    const raw = new Uint8Array(await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, utf8(message)));
    if (raw[0] !== 0 && raw[32] !== 0) continue;
    shortSeen += 1;
    const der = rawSignatureToDer(raw);
    assert.ok(der.length < 72); // 72 only when both halves are full width with the top bit set
    assert.equal(createVerify('SHA256').update(message).verify(publicKey, der), true);
    assert.deepEqual(derSignatureToRaw(der), raw);
  }
  assert.ok(shortSeen >= 1, 'expected at least one signature with a leading zero byte in 1500 tries');
});
