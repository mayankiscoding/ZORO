// The device channel (`GET /v1/devices/channel`, WebSocket, JSON text frames).
//
//   server -> device  {"type": "device_action", "action": DeviceActionRequest}
//                     {"type": "approval_required", "approval": ApprovalRequest}
//   device -> server  {"type": "hello", "capabilities": [...]}
//                     {"type": "device_action_result", "result": DeviceActionResult}
//                     {"type": "ping"}
//
// The channel is open only while the web app is on screen: a browser tab cannot stay connected
// in the background, and this app does not pretend to. While it is open the device counts as
// online, approvals raised elsewhere (an automation, an MCP client) arrive at once, and link
// requests from another device's turn can be offered to the owner. Without it the app still
// works: pending approvals are fetched when a screen opens.

import { WEB_CAPABILITIES } from './identity.js';

const PING_MS = 30_000;
const BACKOFF_MS = [1000, 2000, 5000, 10_000, 30_000];
const CLOSE_POLICY = 1008; // the server refused the token or the session ended

export class DeviceChannel {
  /** @param {{client: any, WebSocketImpl?: typeof WebSocket,
   *   onApproval?: (approval: any) => void, onDeviceAction?: (action: any) => void,
   *   onStatus?: (status: 'connecting' | 'online' | 'offline') => void,
   *   setTimer?: typeof setTimeout, clearTimer?: typeof clearTimeout}} options */
  constructor({
    client,
    WebSocketImpl = globalThis.WebSocket,
    onApproval = () => {},
    onDeviceAction = () => {},
    onStatus = () => {},
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = (id) => clearTimeout(id),
  }) {
    this._client = client;
    this._WebSocket = WebSocketImpl;
    this._onApproval = onApproval;
    this._onDeviceAction = onDeviceAction;
    this._onStatus = onStatus;
    this._setTimer = setTimer;
    this._clearTimer = clearTimer;
    this._socket = null;
    this._wanted = false;
    this._attempt = 0;
    this._retryTimer = null;
    this._pingTimer = null;
    this.status = 'offline';
  }

  get supported() {
    return typeof this._WebSocket === 'function';
  }

  /** Open the channel and keep it open until `stop()`. */
  start() {
    if (!this.supported || this._wanted) return;
    this._wanted = true;
    this._attempt = 0;
    this._connect();
  }

  /** Close the channel (the app went to the background, or the pairing was forgotten). */
  stop() {
    this._wanted = false;
    this._clearTimer(this._retryTimer);
    this._clearTimer(this._pingTimer);
    this._retryTimer = null;
    this._pingTimer = null;
    const socket = this._socket;
    this._socket = null;
    if (socket) {
      socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
      try {
        socket.close(1000, 'app_hidden');
      } catch {
        /* already closed */
      }
    }
    this._status('offline');
  }

  _status(status) {
    if (this.status === status) return;
    this.status = status;
    this._onStatus(status);
  }

  async _connect() {
    if (!this._wanted || this._socket) return;
    this._status('connecting');
    let url;
    try {
      url = await this._client.channelUrl();
    } catch {
      this._retry(); // not signed in or the server is unreachable: try again later
      return;
    }
    if (!this._wanted || this._socket) return;
    let socket;
    try {
      socket = new this._WebSocket(url);
    } catch {
      this._retry();
      return;
    }
    this._socket = socket;
    socket.onopen = () => {
      this._attempt = 0;
      this._send({ type: 'hello', capabilities: [...WEB_CAPABILITIES] });
      this._status('online');
      this._schedulePing();
    };
    socket.onmessage = (message) => this._frame(message.data);
    socket.onerror = () => {};
    socket.onclose = (event) => {
      if (this._socket !== socket) return;
      this._socket = null;
      this._clearTimer(this._pingTimer);
      this._status('offline');
      if (event?.code === CLOSE_POLICY) this._client.signOut?.(); // the token is no longer good
      this._retry();
    };
  }

  _retry() {
    if (!this._wanted) return;
    this._status('offline');
    const wait = BACKOFF_MS[Math.min(this._attempt, BACKOFF_MS.length - 1)];
    this._attempt += 1;
    this._clearTimer(this._retryTimer);
    this._retryTimer = this._setTimer(() => this._connect(), wait);
  }

  _schedulePing() {
    this._clearTimer(this._pingTimer);
    this._pingTimer = this._setTimer(() => {
      if (this._send({ type: 'ping' })) this._schedulePing();
    }, PING_MS);
  }

  _send(frame) {
    const socket = this._socket;
    if (!socket || socket.readyState !== 1) return false;
    try {
      socket.send(JSON.stringify(frame));
      return true;
    } catch {
      return false;
    }
  }

  _frame(data) {
    if (typeof data !== 'string') return;
    let frame;
    try {
      frame = JSON.parse(data);
    } catch {
      return; // not JSON: ignore, never act on it
    }
    if (!frame || typeof frame !== 'object') return;
    if (frame.type === 'approval_required' && frame.approval?.approval_id) {
      this._onApproval(frame.approval);
    } else if (frame.type === 'device_action' && frame.action?.action_id) {
      this._onDeviceAction(frame.action);
    }
  }

  /** Answer a device action that arrived over the channel. Falls back to the REST route when
   * the socket is gone. @param {Record<string, any>} result a `DeviceActionResult` */
  async sendResult(result) {
    if (this._send({ type: 'device_action_result', result })) return 'sent';
    await this._client.postDeviceResult(result);
    return 'posted';
  }
}
