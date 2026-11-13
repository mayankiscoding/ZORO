// A value loaded from the server, with the four states every section shows: loading, ready
// (which may be empty), error, and disconnected (an error whose code is `unreachable`).
// Nothing is cached beyond the page: a reload asks the server again.

export class Resource {
  /** @param {(signal: AbortSignal) => Promise<any>} load */
  constructor(load) {
    this._load = load;
    this._listeners = new Set();
    this._abort = null;
    this._ticket = 0;
    /** @type {'idle' | 'loading' | 'ready' | 'error'} */
    this.status = 'idle';
    this.value = null;
    this.error = null;
    this.loadedAt = null;
  }

  /** @param {(resource: Resource) => void} listener */
  subscribe(listener) {
    this._listeners.add(listener);
    return () => this._listeners.delete(listener);
  }

  _emit() {
    for (const listener of [...this._listeners]) listener(this);
  }

  /** Load or reload. A newer call supersedes an older one. Keeps the last good value on screen
   * while reloading. */
  async refresh() {
    this._abort?.abort();
    const controller = new AbortController();
    this._abort = controller;
    const ticket = ++this._ticket;
    if (this.status !== 'ready') {
      this.status = 'loading';
      this.error = null;
      this._emit();
    }
    try {
      const value = await this._load(controller.signal);
      if (ticket !== this._ticket) return this.value;
      this.value = value;
      this.status = 'ready';
      this.error = null;
      this.loadedAt = new Date();
    } catch (error) {
      if (ticket !== this._ticket || error?.name === 'AbortError') return this.value;
      this.error = error;
      this.status = 'error';
    }
    this._emit();
    return this.value;
  }

  /** Change the value locally after a successful write (a delete, an answer). */
  set(value) {
    this.value = value;
    this.status = 'ready';
    this.error = null;
    this._emit();
  }

  /** Forget everything (the pairing was forgotten). */
  reset() {
    this._abort?.abort();
    this._ticket += 1;
    this.status = 'idle';
    this.value = null;
    this.error = null;
    this.loadedAt = null;
    this._emit();
  }
}
