// Byte helpers shared by the signing code, the sealed cache and the tests.
// Works in browsers and in Node 24 (btoa, atob, TextEncoder are built in).

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** @param {string} text */
export function utf8(text) {
  return encoder.encode(text);
}

/** @param {ArrayBuffer | Uint8Array} bytes */
export function fromUtf8(bytes) {
  return decoder.decode(bytes);
}

/** Standard base64 (with padding), as the server's `base64.b64decode(validate=True)` expects.
 * @param {ArrayBuffer | Uint8Array} input */
export function bytesToBase64(input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  let binary = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode(...bytes.subarray(i, i + step));
  }
  return btoa(binary);
}

/** @param {string} text */
export function base64ToBytes(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** @param {...Uint8Array} parts */
export function concatBytes(...parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}
