// The conversation: history from the server, the live turn, approvals, device actions, cancel.
// No DOM here; screens subscribe and render. Runs in Node for the tests and the end-to-end run.

import { ApiError } from './api.js';
import { errorState, fromServerMessage } from './messages.js';
import { planDeviceAction, refusedResult } from './device-actions.js';
import { canSignApproval, WEB_CAPABILITIES } from './identity.js';
import { activityRows, disconnected, initialTurn, isActive, reduceTurn, resumed } from './turn-reducer.js';

const CACHE_NAME = 'conversation';
const CACHE_MESSAGES = 60;
const MAX_INPUT = 8000;

function isAbort(error) {
  return Boolean(error) && (error.name === 'AbortError' || error.code === 20);
}

export class Conversation {
  /** @param {{client: any, identity: any, cache?: any, now?: () => Date,
   *   context?: () => {locale?: string, timezone?: string, languageHint?: string | null,
   *     responseLength?: string, forcePrivate?: boolean}}} options */
  constructor({ client, identity, cache = null, now = () => new Date(), context = () => ({}) }) {
    this._client = client;
    this._identity = identity;
    this._cache = cache;
    this._now = now;
    this._context = context;
    this._listeners = new Set();
    this._abort = null;
    this._run = 0;
    this.state = {
      conversationId: null,
      /** @type {import('./messages.js').ChatMessage[]} */
      messages: [],
      turn: initialTurn(),
      /** 'idle' | 'loading' | 'ready' | 'error' for the history request */
      history: 'idle',
      historyError: null,
      /** Text came from the sealed cache and has not been confirmed by the server yet. */
      fromCache: false,
      /** Facts about the last finished request, for the Activity screen. Not persisted. */
      last: null,
    };
  }

  // ---------------------------------------------------------------- subscriptions

  /** @param {(state: Conversation['state'], change: {type: string, [key: string]: any}) => void} listener */
  subscribe(listener) {
    this._listeners.add(listener);
    return () => this._listeners.delete(listener);
  }

  _emit(change) {
    for (const listener of [...this._listeners]) listener(this.state, change);
  }

  _set(patch, change = { type: 'change' }) {
    this.state = { ...this.state, ...patch };
    this._emit(change);
  }

  get busy() {
    return isActive(this.state.turn);
  }

  // ---------------------------------------------------------------- history

  /** Show what the sealed cache holds, so Home is not empty while the server is asleep. */
  async restore() {
    if (!this._cache) return false;
    let saved = null;
    try {
      saved = await this._cache.get(CACHE_NAME);
    } catch {
      saved = null;
    }
    if (!saved || !Array.isArray(saved.messages)) return false;
    this._set({ conversationId: saved.conversationId ?? null, messages: saved.messages, fromCache: true });
    return true;
  }

  async _persist() {
    if (!this._cache) return;
    try {
      await this._cache.put(CACHE_NAME, {
        conversationId: this.state.conversationId,
        messages: this.state.messages.slice(-CACHE_MESSAGES),
        savedAt: this._now().toISOString(),
      });
    } catch {
      /* the cache is a convenience; the server holds the history */
    }
  }

  /** Load a conversation's messages from the server. */
  async open(conversationId) {
    if (this.busy) await this.cancel();
    this._set({ conversationId, messages: [], turn: initialTurn(), history: 'loading', historyError: null, fromCache: false });
    return this.refresh();
  }

  /** Re-read the open conversation from the server (after a reconnect, or when another device
   * answered an approval). Leaves a running turn alone. */
  async refresh() {
    const conversationId = this.state.conversationId;
    if (!conversationId) {
      this._set({ history: 'ready', historyError: null });
      return true;
    }
    if (this.state.history !== 'loading') this._set({ history: this.state.messages.length ? this.state.history : 'loading' });
    try {
      const items = await this._client.allMessages(conversationId);
      if (this.state.conversationId !== conversationId) return false; // another one was opened meanwhile
      const patch = { messages: items.map(fromServerMessage), history: 'ready', historyError: null, fromCache: false };
      // A turn that was cut off or waited for another device is over once history has its reply.
      if (['disconnected', 'suspended'].includes(this.state.turn.phase) && this._turnAnswered(items)) {
        patch.turn = initialTurn();
      }
      this._set(patch, { type: 'history' });
      await this._persist();
      return true;
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        // Deleted on another device, or past the retention period.
        this._set({ conversationId: null, messages: [], history: 'ready', historyError: null, fromCache: false });
        await this._persist();
        return true;
      }
      this._set({ history: this.state.messages.length ? 'ready' : 'error', historyError: errorState(error) });
      return false;
    }
  }

  _turnAnswered(items) {
    const last = items[items.length - 1];
    if (!last || last.role !== 'assistant') return false;
    const turnId = this.state.turn.turnId;
    // Message ids carry the turn's id today (msg_<turn>a for the reply); a longer history than
    // the one on screen, ending in a reply, says the same without leaning on that.
    if (turnId && String(last.id).includes(turnId.replace(/^turn_/, ''))) return true;
    return items.length > this.state.messages.length + 1;
  }

  /** Start a new conversation (the old one stays in history). */
  async startNew() {
    if (this.busy) await this.cancel();
    this._set({ conversationId: null, messages: [], turn: initialTurn(), history: 'ready', historyError: null, fromCache: false, last: null });
    await this._persist();
  }

  /** The open conversation was deleted (from history). */
  async forgetLocal() {
    this._abort?.abort();
    this._set({ conversationId: null, messages: [], turn: initialTurn(), history: 'ready', historyError: null, fromCache: false });
    try {
      await this._cache?.remove(CACHE_NAME);
    } catch {
      /* nothing cached */
    }
  }

  // ---------------------------------------------------------------- turns

  _clientContext(record) {
    const extra = this._context() ?? {};
    return {
      platform: record?.platform ?? 'web',
      locale: extra.locale ?? 'en-IN',
      timezone: extra.timezone ?? 'Asia/Kolkata',
      capabilities: [...WEB_CAPABILITIES],
      app_state: extra.responseLength ? { response_length: extra.responseLength } : {},
    };
  }

  /** Send the owner's words. Resolves when the stream ends: completed, suspended or failed.
   * @param {string} text @param {{modality?: 'text' | 'voice'}} [options] */
  async send(text, { modality = 'text' } = {}) {
    const ownerText = String(text ?? '').trim().slice(0, MAX_INPUT);
    if (!ownerText) return this.state.turn;
    if (this.busy || this.state.turn.phase === 'suspended') await this.cancel();
    this._fold();
    const run = ++this._run;
    this._set({ turn: initialTurn({ ownerText, modality }) }, { type: 'turn_begin' });
    const controller = new AbortController();
    this._abort = controller;
    try {
      const record = await this._identity.load();
      const extra = this._context() ?? {};
      const request = {
        conversation_id: this.state.conversationId,
        input: { text: ownerText, modality, language_hint: extra.languageHint ?? null },
        client: this._clientContext(record),
      };
      // A client may ask for a stricter mode for its own turn, never a looser one.
      if (extra.forcePrivate) request.privacy_mode = 'strict_private';
      const events = await this._client.startTurn(request, { signal: controller.signal });
      await this._consume(events, run);
    } catch (error) {
      this._streamFailed(error, run);
    } finally {
      if (this._abort === controller) this._abort = null;
    }
    return this.state.turn;
  }

  async _consume(events, run) {
    for await (const event of events) {
      if (run !== this._run) return; // a newer turn took over
      const turn = reduceTurn(this.state.turn, event);
      const patch = { turn };
      if (event.type === 'turn_started' && event.conversation_id) patch.conversationId = event.conversation_id;
      this._set(patch, { type: 'event', event });
    }
    if (run !== this._run) return;
    await this._afterStream(run);
  }

  async _afterStream(run) {
    const turn = this.state.turn;
    if (turn.phase === 'completed') {
      this._fold();
      await this._persist();
      this._emit({ type: 'turn_end', outcome: 'completed', turn });
      return;
    }
    if (turn.phase === 'failed' || turn.phase === 'cancelled') {
      this._emit({ type: 'turn_end', outcome: turn.phase, turn });
      return;
    }
    if (turn.phase === 'suspended') {
      if (turn.deviceAction) {
        const plan = planDeviceAction(turn.deviceAction, this._now());
        if (plan.kind === 'refuse') {
          // Nothing for the owner to do: tell the server now so ZORO can say what it could not do.
          await this.answerDevice(refusedResult(turn.deviceAction, plan.errorCode, this._now()), run);
          return;
        }
      }
      this._emit({ type: 'turn_waiting', reason: turn.suspendedReason });
      return;
    }
    // The stream ended without a final event: the connection dropped. The server finishes the
    // turn on its own and the reply lands in history.
    this._set({ turn: disconnected(turn) }, { type: 'turn_end', outcome: 'disconnected' });
  }

  _streamFailed(error, run) {
    if (run !== this._run) return;
    if (isAbort(error)) return; // cancel() reports the outcome
    const turn = this.state.turn;
    if (turn.turnId && isActive(turn) && (!(error instanceof ApiError) || error.code === 'unreachable')) {
      this._set({ turn: disconnected(turn, error?.message ?? '') }, { type: 'turn_end', outcome: 'disconnected' });
      return;
    }
    this._set(
      { turn: { ...turn, phase: 'failed', error: errorState(error) } },
      { type: 'turn_end', outcome: 'failed' },
    );
  }

  /** Move a finished turn into the message list, keeping its key so the screen keeps its node. */
  _fold() {
    const turn = this.state.turn;
    if (!turn.ownerText || !['completed', 'failed', 'cancelled'].includes(turn.phase)) return;
    const key = turn.turnId ? `turn:${turn.turnId}` : `local:${this._run}`;
    const createdAt = this._now().toISOString();
    const messages = [
      ...this.state.messages,
      { id: `${key}:u`, key, role: 'user', text: turn.ownerText, language: 'en', createdAt, agents: [], cards: [] },
    ];
    if (turn.phase === 'completed') {
      messages.push({
        id: turn.completed?.messageId ?? `${key}:a`,
        key: `${key}:a`,
        role: 'assistant',
        text: turn.text,
        language: turn.completed?.language ?? 'en',
        createdAt,
        agents: [...new Set(turn.agents.map((item) => item.agent))],
        cards: turn.cards,
      });
    }
    // The live slot is cleared; what the request did stays available as `last`.
    const last = { outcome: turn.phase, route: turn.route, rows: activityRows(turn), at: createdAt, key };
    this.state = { ...this.state, messages, turn: initialTurn(), last };
    this._emit({ type: 'folded' });
  }

  /** Stop the running turn, or abandon one that waits for an answer. */
  async cancel() {
    const turn = this.state.turn;
    if (!isActive(turn) && turn.phase !== 'suspended' && turn.phase !== 'disconnected') return;
    this._run += 1; // events of the old stream are ignored from here on
    this._abort?.abort();
    this._abort = null;
    const cancelled = {
      ...turn,
      phase: 'cancelled',
      approval: null,
      deviceAction: null,
      suspendedReason: null,
      error: { code: 'cancelled', message: '', retryable: false },
    };
    this._set({ turn: cancelled }, { type: 'turn_end', outcome: 'cancelled' });
    if (turn.turnId) {
      try {
        await this._client.cancelTurn(turn.turnId);
      } catch {
        /* the server ends an orphaned turn by itself; nothing more to do from here */
      }
    }
  }

  // ---------------------------------------------------------------- answers

  /** Approve or decline the request the turn is waiting on. Only `confirm` level can be signed
   * here; anything else throws `IdentityError('needs_user_presence_key')` before a signature exists.
   * @param {boolean} approved */
  async decide(approved) {
    const turn = this.state.turn;
    const approval = turn.approval;
    if (turn.phase !== 'suspended' || !approval || !turn.turnId) return turn;
    const decision = await this._identity.signApproval(approval, approved);
    return this._resume(turn.turnId, { approval: decision }, { type: 'approval_sent', approved });
  }

  /** Send a device action result and continue the turn.
   * @param {Record<string, any>} result a `DeviceActionResult` */
  async answerDevice(result, run = this._run) {
    const turn = this.state.turn;
    if (run !== this._run || turn.phase !== 'suspended' || !turn.deviceAction || !turn.turnId) return turn;
    return this._resume(turn.turnId, { device_result: result }, { type: 'device_result_sent', ok: Boolean(result.ok) });
  }

  async _resume(turnId, answer, change) {
    const run = ++this._run;
    const before = this.state.turn;
    this._set({ turn: resumed(before) }, change);
    const controller = new AbortController();
    this._abort = controller;
    try {
      const events = await this._client.resumeTurn(turnId, answer, { signal: controller.signal });
      await this._consume(events, run);
    } catch (error) {
      if (run !== this._run || isAbort(error)) return this.state.turn;
      if (error instanceof ApiError && error.status === 409) {
        // Answered from another device, expired or cancelled meanwhile: history has the truth.
        this._set({ turn: { ...before, phase: 'failed', approval: null, deviceAction: null, error: errorState(error) } }, { type: 'turn_end', outcome: 'failed' });
        if ((await this.refresh()) && run === this._run) this._set({ turn: initialTurn() });
      } else if (error instanceof ApiError && error.code === 'unreachable') {
        this._set({ turn: { ...before, error: errorState(error) } }, { type: 'turn_waiting', reason: before.suspendedReason });
      } else {
        this._streamFailed(error, run);
      }
    } finally {
      if (this._abort === controller) this._abort = null;
    }
    return this.state.turn;
  }

  /** Answer an approval that is listed as pending but is not this screen's live turn (it came
   * from an automation, an MCP client or an earlier visit). Uses the one route that answers any
   * approval. @param {any} approval an `ApprovalRequest` @param {boolean} approved */
  async decidePending(approval, approved) {
    if (!canSignApproval(approval)) {
      const error = new Error('This approval needs Face ID or Touch ID.');
      error.code = 'needs_user_presence_key';
      throw error;
    }
    const live = this.state.turn;
    if (live.phase === 'suspended' && live.approval?.approval_id === approval.approval_id) {
      await this.decide(approved);
      return { owner: 'turn', approved, status: this.state.turn.phase, events: [] };
    }
    const decision = await this._identity.signApproval(approval, approved);
    const result = await this._client.decideApproval(decision);
    // A resumed turn may belong to the open conversation: its reply is in history now.
    if (result?.owner === 'turn') await this.refresh();
    return result;
  }
}
