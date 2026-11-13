// The exact strings a device signs. They mirror `backend/app/security/crypto.py`
// (auth_message, approval_message, action_message) and `iso_seconds` in
// `backend/app/schemas/common.py`. `web/tests/signing.test.mjs` checks them against vectors
// produced by those Python functions.

/** `YYYY-MM-DDTHH:MM:SSZ` in UTC, seconds precision: the timestamp form inside signed strings.
 * @param {Date | string | number} when */
export function isoSeconds(when) {
  const date = when instanceof Date ? when : new Date(when);
  if (Number.isNaN(date.getTime())) throw new RangeError('isoSeconds: not a valid time');
  return `${date.toISOString().slice(0, 19)}Z`;
}

/** A `Date` cut to whole seconds, so the value sent as `signed_at` and the value inside the
 * signed string are the same instant.
 * @param {Date} [now] */
export function signingTime(now = new Date()) {
  return new Date(Math.floor(now.getTime() / 1000) * 1000);
}

/** Session challenge: signed with the auth key.
 * @param {string} deviceId @param {string} nonce */
export function authMessage(deviceId, nonce) {
  return `zoro-auth-v1|${deviceId}|${nonce}`;
}

/** Approval decision: signed with the auth key for level `confirm`.
 * @param {string} approvalId @param {string} actionDigest @param {boolean} approved
 * @param {Date | string | number} signedAt */
export function approvalMessage(approvalId, actionDigest, approved, signedAt) {
  return `zoro-approval-v1|${approvalId}|${actionDigest}|${approved ? '1' : '0'}|${isoSeconds(signedAt)}`;
}

/** Security settings proof. The web app never signs one (it has no user-presence key); the
 * builder exists so the contract is covered by the same vector test as the other two.
 * @param {string} action @param {string} subject @param {Date | string | number} signedAt */
export function actionMessage(action, subject, signedAt) {
  return `zoro-action-v1|${action}|${subject}|${isoSeconds(signedAt)}`;
}
