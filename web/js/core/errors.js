// From an error (an `ApiError`, a turn `error` event, an `IdentityError`) to what the screen
// says and which single action it offers. The server's own sentence is used for turn errors,
// because it is already in the owner's language; everything else maps to an interface string.

/** @typedef {{key: string, params?: Record<string, string>, kind: 'error' | 'disconnected',
 *   action: 'retry' | 'reconnect' | 'pair' | null, serverMessage?: string}} ErrorView */

const PAIR_AGAIN = new Set(['device_revoked', 'device_not_found', 'invalid_signature', 'not_paired', 'challenge_invalid']);

/** @param {{code?: string, status?: number, message?: string, retryable?: boolean} | null | undefined} error
 * @param {{online?: boolean}} [env]
 * @returns {ErrorView} */
export function describeError(error, { online = globalThis.navigator?.onLine !== false } = {}) {
  const code = error?.code ?? 'unexpected';
  const status = error?.status ?? 0;

  if (code === 'unreachable' || status === 0 && code === 'network') {
    return { key: online ? 'state.disconnected' : 'state.offline', kind: 'disconnected', action: 'reconnect' };
  }
  if (code === 'kill_switch_active') return { key: 'state.kill_switch', kind: 'error', action: 'retry' };
  if (code === 'device_revoked') return { key: 'state.revoked', kind: 'error', action: 'pair' };
  if (PAIR_AGAIN.has(code)) return { key: 'state.session', kind: 'error', action: 'pair' };
  if (code === 'stream_unsupported') return { key: 'state.stream', kind: 'error', action: null };
  if (code === 'protocol') return { key: 'state.protocol', kind: 'error', action: null };
  if (code === 'rate_limited' || status === 429) return { key: 'state.rate_limited', kind: 'error', action: 'retry' };
  if (status === 403) return { key: 'state.forbidden', kind: 'error', action: null };
  if (status === 404) return { key: 'state.not_found', kind: 'error', action: null };
  if (status >= 500 || code === 'internal_error') return { key: 'state.server_error', kind: 'error', action: 'retry' };
  return { key: 'state.unexpected', kind: 'error', action: error?.retryable ? 'retry' : null };
}

/** What to say about a failed turn. A turn `error` event carries the server's sentence in the
 * owner's language; transport failures do not.
 * @param {{code?: string, status?: number, message?: string, retryable?: boolean} | null} error
 * @returns {ErrorView} */
export function describeTurnError(error) {
  const view = describeError(error);
  const fromEvent = error && error.status === undefined && typeof error.message === 'string' && error.message.trim();
  if (fromEvent && view.key === 'state.unexpected') {
    return { ...view, serverMessage: error.message.trim(), action: error.retryable ? 'retry' : view.action };
  }
  if (fromEvent && view.key === 'state.server_error') return { ...view, serverMessage: error.message.trim() };
  return view;
}

/** Which pairing error sentence fits. @param {{code?: string, status?: number} | null} error */
export function pairingErrorKey(error) {
  switch (error?.code) {
    case 'pairing_code_incomplete':
      return 'pair.error.incomplete';
    case 'pairing_code_invalid':
      return 'pair.error.invalid';
    case 'rate_limited':
      return 'pair.error.rate_limited';
    case 'device_name_invalid':
      return 'pair.error.name';
    case 'unreachable':
      return 'pair.error.unreachable';
    case 'webcrypto_unavailable':
    case 'key_extractable':
    case 'public_key_invalid':
    case 'public_key_reused':
      return 'pair.error.crypto';
    default:
      return 'pair.error.other';
  }
}

/** Which sentence fits a failed approval answer. @param {{code?: string, status?: number} | null} error */
export function approvalErrorKey(error) {
  switch (error?.code) {
    case 'needs_user_presence_key':
      return 'approval.biometric.body';
    case 'approval_expired':
      return 'approval.expired';
    case 'invalid_signature':
    case 'wrong_device':
      return 'approval.error.signature';
    case 'approval_replayed':
    case 'approval_not_found':
    case 'approval_owner_not_found':
    case 'turn_not_suspended':
    case 'resume_mismatch':
    case 'turn_state_lost':
      return 'approval.error.gone';
    case 'unreachable':
      return 'approval.error.unreachable';
    default:
      return describeError(error).key;
  }
}
