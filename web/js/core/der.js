// ECDSA signature encodings.
//
// WebCrypto returns a P-256 signature as the raw concatenation r || s (IEEE P1363, 64 bytes).
// The ZORO server verifies DER (`SEQUENCE { INTEGER r, INTEGER s }`), which is what the
// Secure Enclave on iPhone and Mac produces. These two functions convert between them.

const P256_FIELD_BYTES = 32;

/** Minimal big-endian unsigned integer as a DER INTEGER body: no redundant leading zeros, and a
 * 0x00 prefix when the top bit is set (DER integers are signed).
 * @param {Uint8Array} value */
function derIntegerBody(value) {
  let start = 0;
  while (start < value.length - 1 && value[start] === 0) start += 1;
  const trimmed = value.subarray(start);
  if (trimmed[0] & 0x80) {
    const padded = new Uint8Array(trimmed.length + 1);
    padded.set(trimmed, 1);
    return padded;
  }
  return trimmed;
}

/** DER length octets (short form below 128, long form above).
 * @param {number} length */
function derLength(length) {
  if (length < 0x80) return [length];
  const octets = [];
  let rest = length;
  while (rest > 0) {
    octets.unshift(rest & 0xff);
    rest >>>= 8;
  }
  return [0x80 | octets.length, ...octets];
}

/** Convert a raw r || s signature to DER.
 * @param {ArrayBuffer | Uint8Array} raw
 * @param {number} [fieldBytes] size of r and of s in bytes (32 for P-256)
 * @returns {Uint8Array} */
export function rawSignatureToDer(raw, fieldBytes = P256_FIELD_BYTES) {
  const bytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
  if (bytes.length !== fieldBytes * 2) {
    throw new RangeError(`raw signature must be ${fieldBytes * 2} bytes, got ${bytes.length}`);
  }
  const r = derIntegerBody(bytes.subarray(0, fieldBytes));
  const s = derIntegerBody(bytes.subarray(fieldBytes));
  const body = [0x02, ...derLength(r.length), ...r, 0x02, ...derLength(s.length), ...s];
  return Uint8Array.from([0x30, ...derLength(body.length), ...body]);
}

/** Convert a DER ECDSA signature back to raw r || s. Strict: rejects trailing bytes, negative or
 * non-minimal integers and values wider than the field.
 * @param {ArrayBuffer | Uint8Array} der
 * @param {number} [fieldBytes]
 * @returns {Uint8Array} */
export function derSignatureToRaw(der, fieldBytes = P256_FIELD_BYTES) {
  const bytes = der instanceof Uint8Array ? der : new Uint8Array(der);
  let offset = 0;

  const readLength = () => {
    if (offset >= bytes.length) throw new RangeError('DER signature is truncated');
    const first = bytes[offset++];
    if (first < 0x80) return first;
    const count = first & 0x7f;
    if (count === 0 || count > 2) throw new RangeError('DER length is not supported');
    let length = 0;
    for (let i = 0; i < count; i += 1) {
      if (offset >= bytes.length) throw new RangeError('DER signature is truncated');
      length = (length << 8) | bytes[offset++];
    }
    if (length < 0x80) throw new RangeError('DER length is not minimal');
    return length;
  };

  const readInteger = () => {
    if (bytes[offset++] !== 0x02) throw new RangeError('DER signature: expected INTEGER');
    const length = readLength();
    if (length === 0 || offset + length > bytes.length) throw new RangeError('DER integer is truncated');
    let body = bytes.subarray(offset, offset + length);
    offset += length;
    if (body[0] & 0x80) throw new RangeError('DER integer is negative');
    if (body.length > 1 && body[0] === 0 && !(body[1] & 0x80)) {
      throw new RangeError('DER integer is not minimal');
    }
    if (body[0] === 0) body = body.subarray(1);
    if (body.length > fieldBytes) throw new RangeError('DER integer is wider than the field');
    const out = new Uint8Array(fieldBytes);
    out.set(body, fieldBytes - body.length);
    return out;
  };

  if (bytes[offset++] !== 0x30) throw new RangeError('DER signature: expected SEQUENCE');
  const total = readLength();
  if (offset + total !== bytes.length) throw new RangeError('DER signature has the wrong length');
  const r = readInteger();
  const s = readInteger();
  if (offset !== bytes.length) throw new RangeError('DER signature has trailing bytes');
  const raw = new Uint8Array(fieldBytes * 2);
  raw.set(r, 0);
  raw.set(s, fieldBytes);
  return raw;
}
