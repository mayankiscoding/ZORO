// Key-value stores for values that must not go to localStorage: CryptoKey objects (which
// IndexedDB can hold without ever exposing key material to script) and sealed cache records.
//
// Every store has the same four async methods, so the identity and cache code can run in Node
// tests against `MemoryStore` and in the browser against `IndexedDbStore`.

const DB_NAME = 'zoro-web';
const DB_VERSION = 1;
export const STORE_NAMES = Object.freeze(['identity', 'cache']);

/** In-memory store (tests, and the fallback when IndexedDB is unavailable: private browsing in
 * some browsers). Nothing survives a reload. */
export class MemoryStore {
  constructor() {
    this._map = new Map();
    this.persistent = false;
  }

  async get(key) {
    return this._map.get(key);
  }

  async set(key, value) {
    this._map.set(key, value);
  }

  async delete(key) {
    this._map.delete(key);
  }

  async clear() {
    this._map.clear();
  }

  async keys() {
    return [...this._map.keys()];
  }
}

let dbPromise = null;

function openDatabase(indexedDB) {
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        for (const name of STORE_NAMES) {
          if (!request.result.objectStoreNames.contains(name)) request.result.createObjectStore(name);
        }
      };
      request.onsuccess = () => {
        const db = request.result;
        db.onversionchange = () => {
          db.close();
          dbPromise = null;
        };
        resolve(db);
      };
      request.onerror = () => reject(request.error || new Error('IndexedDB could not be opened'));
      request.onblocked = () => reject(new Error('IndexedDB is blocked by another tab'));
    }).catch((error) => {
      dbPromise = null;
      throw error;
    });
  }
  return dbPromise;
}

/** One object store of the `zoro-web` IndexedDB database. */
export class IndexedDbStore {
  /** @param {string} name one of STORE_NAMES @param {IDBFactory} [indexedDB] */
  constructor(name, indexedDB = globalThis.indexedDB) {
    if (!STORE_NAMES.includes(name)) throw new Error(`unknown store: ${name}`);
    this._name = name;
    this._idb = indexedDB;
    this.persistent = true;
  }

  async _run(mode, work) {
    const db = await openDatabase(this._idb);
    return new Promise((resolve, reject) => {
      const tx = db.transaction(this._name, mode);
      const request = work(tx.objectStore(this._name));
      let result;
      if (request) {
        request.onsuccess = () => {
          result = request.result;
        };
      }
      tx.oncomplete = () => resolve(result);
      tx.onerror = () => reject(tx.error || new Error('IndexedDB transaction failed'));
      tx.onabort = () => reject(tx.error || new Error('IndexedDB transaction was aborted'));
    });
  }

  get(key) {
    return this._run('readonly', (store) => store.get(key));
  }

  set(key, value) {
    return this._run('readwrite', (store) => store.put(value, key)).then(() => undefined);
  }

  delete(key) {
    return this._run('readwrite', (store) => store.delete(key)).then(() => undefined);
  }

  clear() {
    return this._run('readwrite', (store) => store.clear()).then(() => undefined);
  }

  keys() {
    return this._run('readonly', (store) => store.getAllKeys());
  }
}

/** The stores the app uses. Falls back to memory when IndexedDB cannot be opened, and says so
 * through `persistent` so the interface can tell the owner that pairing will not survive.
 * @returns {Promise<{identity: MemoryStore | IndexedDbStore, cache: MemoryStore | IndexedDbStore, persistent: boolean}>} */
export async function openStores(indexedDB = globalThis.indexedDB) {
  if (indexedDB) {
    try {
      await openDatabase(indexedDB);
      return {
        identity: new IndexedDbStore('identity', indexedDB),
        cache: new IndexedDbStore('cache', indexedDB),
        persistent: true,
      };
    } catch {
      /* fall through to memory */
    }
  }
  return { identity: new MemoryStore(), cache: new MemoryStore(), persistent: false };
}
