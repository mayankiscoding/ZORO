// HTTP client for the ZORO backend contract (design spec section 8).
//
// Sessions: challenge -> signature with the auth key -> 15-minute bearer token. There are no
// refresh tokens. The token lives in memory only; a reload or a 401 signs a new challenge.
// Every request that needs a session retries once after a 401, then gives up with the
// server's error code so the interface can say what to do (pair again, turn ZORO back on, ...).

import { readEventStream } from './sse.js';

const API = '/v1';
const EXPIRY_MARGIN_MS = 30_000;
/** 401 codes that mean "sign in again"; the rest (revoked device, bad signature) will not heal. */
const REAUTH_CODES = new Set(['token_invalid', 'unauthorized']);
/** Codes that mean this browser must be paired again. */
export const REPAIR_CODES = new Set(['device_revoked', 'device_not_found', 'invalid_signature', 'not_paired']);

export class ApiError extends Error {
  /** @param {{status: number, code: string, message: string, retryable?: boolean, detail?: any}} body */
  constructor({ status, code, message, retryable = false, detail = null }) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.retryable = retryable;
    this.detail = detail;
  }

  get needsPairing() {
    return REPAIR_CODES.has(this.code);
  }
}

/** Turn a failed `Response` into an `ApiError` using the server's `ErrorBody` when there is one.
 * @param {Response} response */
async function errorFrom(response) {
  let body = null;
  try {
    body = await response.json();
  } catch {
    /* not JSON: a proxy or the web server answered */
  }
  if (body && typeof body.code === 'string') {
    return new ApiError({
      status: response.status,
      code: body.code,
      message: typeof body.message === 'string' ? body.message : 'The request failed.',
      retryable: Boolean(body.retryable),
      detail: body.detail ?? null,
    });
  }
  return new ApiError({
    status: response.status,
    code: response.status === 401 ? 'unauthorized' : `http_${response.status}`,
    message: `The server answered ${response.status}.`,
    retryable: response.status >= 500,
  });
}

function isAbort(error) {
  return Boolean(error) && (error.name === 'AbortError' || error.code === 20);
}

export class ZoroClient {
  /** @param {{baseUrl?: string, fetch?: typeof fetch, identity: any, now?: () => Date,
   *   onSession?: (state: 'signed_in' | 'signed_out') => void}} options */
  constructor({ baseUrl = '', fetch = globalThis.fetch?.bind(globalThis), identity, now = () => new Date(), onSession }) {
    this._base = baseUrl.replace(/\/+$/, '');
    this._fetch = fetch;
    this._identity = identity;
    this._now = now;
    this._onSession = onSession;
    this._token = null;
    this._expiresAt = 0;
    this._signingIn = null;
  }

  get baseUrl() {
    return this._base;
  }

  // ---------------------------------------------------------------- transport

  async _send(path, init) {
    try {
      return await this._fetch(this._base + path, init);
    } catch (error) {
      if (isAbort(error)) throw error;
      throw new ApiError({
        status: 0,
        code: 'unreachable',
        message: 'The ZORO server could not be reached.',
        retryable: true,
      });
    }
  }

  static _query(query) {
    if (!query) return '';
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined && value !== null && value !== '') params.set(key, String(value));
    }
    const text = params.toString();
    return text ? `?${text}` : '';
  }

  /** JSON request. `auth: false` is for health and pairing only.
   * @param {string} method @param {string} path
   * @param {{body?: any, query?: Record<string, any>, auth?: boolean, signal?: AbortSignal}} [options] */
  async json(method, path, { body, query, auth = true, signal } = {}) {
    const url = path + ZoroClient._query(query);
    const attempt = async () => {
      const headers = { Accept: 'application/json' };
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      if (auth) headers.Authorization = `Bearer ${await this.ensureSession()}`;
      return this._send(url, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal,
        cache: 'no-store',
        credentials: 'omit',
      });
    };
    let response = await attempt();
    if (response.status === 401 && auth) {
      const error = await errorFrom(response);
      if (!REAUTH_CODES.has(error.code)) throw error;
      this._dropSession();
      response = await attempt();
    }
    if (!response.ok) throw await errorFrom(response);
    if (response.status === 204) return null;
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  /** POST that answers with `text/event-stream`. Resolves once the stream is open, so errors
   * raised before any event (unknown conversation, kill switch, 401) reject here.
   * @param {string} path @param {any} body @param {{signal?: AbortSignal}} [options]
   * @returns {Promise<AsyncGenerator<Record<string, any>>>} */
  async stream(path, body, { signal } = {}) {
    const attempt = async () =>
      this._send(path, {
        method: 'POST',
        headers: {
          Accept: 'text/event-stream',
          'Content-Type': 'application/json',
          Authorization: `Bearer ${await this.ensureSession()}`,
        },
        body: JSON.stringify(body),
        signal,
        cache: 'no-store',
        credentials: 'omit',
      });
    let response = await attempt();
    if (response.status === 401) {
      const error = await errorFrom(response);
      if (!REAUTH_CODES.has(error.code)) throw error;
      this._dropSession();
      response = await attempt();
    }
    if (!response.ok) throw await errorFrom(response);
    if (!response.body) {
      throw new ApiError({
        status: response.status,
        code: 'stream_unsupported',
        message: 'This browser cannot read a streaming reply.',
      });
    }
    return readEventStream(response.body, { signal });
  }

  // ---------------------------------------------------------------- session

  _dropSession() {
    this._token = null;
    this._expiresAt = 0;
  }

  /** Forget the token (used when the pairing is forgotten or the app goes to the background
   * for long). */
  signOut() {
    this._dropSession();
    this._onSession?.('signed_out');
  }

  get sessionExpiresAt() {
    return this._token ? new Date(this._expiresAt) : null;
  }

  /** A valid bearer token, signing a new challenge when needed. Concurrent callers share one
   * sign-in. @param {{force?: boolean}} [options] */
  async ensureSession({ force = false } = {}) {
    if (!force && this._token && this._now().getTime() < this._expiresAt - EXPIRY_MARGIN_MS) {
      return this._token;
    }
    if (!this._signingIn) {
      this._signingIn = this._signIn().finally(() => {
        this._signingIn = null;
      });
    }
    return this._signingIn;
  }

  async _signIn() {
    const record = await this._identity.load();
    if (!record) {
      throw new ApiError({
        status: 401,
        code: 'not_paired',
        message: 'This browser is not paired with a ZORO server.',
      });
    }
    const challenge = await this.json('POST', `${API}/auth/challenge`, {
      body: { device_id: record.deviceId },
      auth: false,
    });
    const proof = await this._identity.signChallenge(challenge.nonce);
    const startedAt = this._now().getTime();
    const token = await this.json('POST', `${API}/auth/token`, { body: proof, auth: false });
    this._token = token.access_token;
    this._expiresAt = startedAt + Number(token.expires_in) * 1000;
    this._onSession?.('signed_in');
    return this._token;
  }

  // ---------------------------------------------------------------- auth and health

  health({ signal } = {}) {
    return this.json('GET', '/healthz', { auth: false, signal });
  }

  /** @param {Record<string, any>} body a `PairRequest` */
  pair(body) {
    return this.json('POST', `${API}/auth/pair`, { body, auth: false });
  }

  // ---------------------------------------------------------------- turns

  startTurn(request, options) {
    return this.stream(`${API}/turns`, request, options);
  }

  /** @param {string} turnId @param {{approval?: any, device_result?: any}} answer */
  resumeTurn(turnId, answer, options) {
    return this.stream(`${API}/turns/${encodeURIComponent(turnId)}/resume`, answer, options);
  }

  cancelTurn(turnId) {
    return this.json('POST', `${API}/turns/${encodeURIComponent(turnId)}/cancel`);
  }

  conversations({ cursor, limit = 20 } = {}) {
    return this.json('GET', `${API}/conversations`, { query: { cursor, limit } });
  }

  messages(conversationId, { cursor, limit = 50 } = {}) {
    return this.json('GET', `${API}/conversations/${encodeURIComponent(conversationId)}/messages`, {
      query: { cursor, limit },
    });
  }

  /** Every message of a conversation, oldest first (follows the cursor, bounded). */
  async allMessages(conversationId, { maxPages = 10 } = {}) {
    const items = [];
    let cursor;
    for (let page = 0; page < maxPages; page += 1) {
      const result = await this.messages(conversationId, { cursor, limit: 100 });
      items.push(...result.items);
      cursor = result.next_cursor;
      if (!cursor) break;
    }
    return items;
  }

  deleteConversation(conversationId) {
    return this.json('DELETE', `${API}/conversations/${encodeURIComponent(conversationId)}`);
  }

  // ---------------------------------------------------------------- approvals and devices

  pendingApprovals() {
    return this.json('GET', `${API}/approvals/pending`);
  }

  /** @param {{approval_id: string}} decision a signed `ApprovalDecision` */
  decideApproval(decision) {
    return this.json('POST', `${API}/approvals/${encodeURIComponent(decision.approval_id)}/decision`, {
      body: decision,
    });
  }

  postDeviceResult(result) {
    return this.json('POST', `${API}/devices/actions/${encodeURIComponent(result.action_id)}/result`, {
      body: result,
    });
  }

  devices() {
    return this.json('GET', `${API}/devices`);
  }

  /** WebSocket URL of the device channel. Browsers cannot set an Authorization header on a
   * WebSocket, so the contract's `token` query parameter is used. */
  async channelUrl() {
    const token = await this.ensureSession();
    const origin = this._base || globalThis.location?.origin || '';
    const url = new URL(`${API}/devices/channel`, origin);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('token', token);
    return url.toString();
  }

  // ---------------------------------------------------------------- read-only spaces

  securityState() {
    return this.json('GET', `${API}/security/state`);
  }

  capabilities(domain) {
    return this.json('GET', `${API}/capabilities`, { query: { domain } });
  }

  financeSummary(period = 'this_month') {
    return this.json('GET', `${API}/finance/summary`, { query: { period } });
  }

  basket() {
    return this.json('GET', `${API}/shopping/baskets`);
  }

  compareBasket(basketId) {
    return this.json('POST', `${API}/shopping/compare`, { body: basketId ? { basket_id: basketId } : {} });
  }

  memories({ cursor, limit = 50, status } = {}) {
    return this.json('GET', `${API}/memory`, { query: { cursor, limit, status } });
  }

  deleteMemory(memoryId) {
    return this.json('DELETE', `${API}/memory/${encodeURIComponent(memoryId)}`);
  }
}
