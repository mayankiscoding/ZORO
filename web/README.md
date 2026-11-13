# ZORO for Safari

A companion web app the owner installs on the iPhone with Safari's **Add to Home Screen**, served by
their own ZORO server. It makes ZORO usable before the native app can be built. It is not the primary
client (the SwiftUI apps are, see `CLAUDE.md` rule 12), it follows the same contract and security
rules, and it says on screen what it cannot do.

Status: **working against the backend as it exists**, checked on this machine with unit tests, an
end-to-end run against the real backend, and a run in headless Chrome. **Not checked on an iPhone or
in Safari** (see "Not verified here").

No build step and no dependencies: hand-written HTML, CSS and ES modules, a web app manifest and a
service worker. Node is needed only to run the tests and the two small tools.

## How it is served

The app must come from the **same origin as the API** (`/v1/...`). Its Content-Security-Policy allows
that origin only, and it never asks for a server address: it talks to the server it was opened from.

| Way | Status | How |
|---|---|---|
| The backend mounts `web/` at `/app/` | **needs a backend change** (listed in the report: static mount, redirect `/app` to `/app/`, the security headers of `tools/serve.mjs`) | then open `https://<your-server>/app/` |
| The bundled static server in front of the backend | **working** | `node web/tools/serve.mjs --backend http://127.0.0.1:8000 --port 8765` serves `/app/` and passes everything else (including streamed replies and the WebSocket device channel) to the backend. It listens on `127.0.0.1` only. |

HTTPS is required. Browsers give WebCrypto keys, the microphone and service workers only to a secure
address (`https://`, or `http://127.0.0.1` for development). On a tailnet:

```
cd backend && uv run --no-sync uvicorn app.main:create_app --factory --port 8000
node web/tools/serve.mjs --backend http://127.0.0.1:8000 --port 8765
tailscale serve --bg 8765        # prints https://<machine>.<tailnet>.ts.net
```

Only the app itself is served: `index.html`, `manifest.webmanifest`, `sw.js`, `css/`, `js/`, `icons/`.
Tests, tools and this file are never served.

## Install on an iPhone

1. On the server, make a pairing code: `cd backend && uv run --no-sync python -m app.cli pairing-code`
   (one use, valid 10 minutes).
2. On the iPhone, open `https://<machine>.<tailnet>.ts.net/app/` in **Safari** (the phone must be on
   your tailnet).
3. Share, then **Add to Home Screen**. Open ZORO from the Home Screen. Pair from there: Safari and
   the Home Screen app keep separate storage, so a pairing made in the Safari tab does not carry over.
4. Get started, type the code, Connect. The browser makes its keys, the server registers the public
   halves. Choose the language, then Start using ZORO.

A link of the form `https://<server>/app/#pair=K7QM-2XWD` pre-fills the code. The part after `#` is
never sent to the server.

## What works

| Area | Status |
|---|---|
| Pairing with a one-time code; challenge, signature, 15-minute token; re-signing on 401 | working, verified end to end |
| Conversation: typed turns over streaming fetch (SSE), every event type handled, cancel, resume, history from the server | working, verified end to end |
| Approvals at level `confirm`: the sheet shows the exact content and digest, Approve / Decline are signed with this browser's key | working, verified end to end |
| Device actions: `device.open_url` and `device.whatsapp.compose` are offered as a link the owner taps; every other device tool is answered `unsupported` at once | working, verified end to end |
| Cards: products, basket, basket comparison, finance summary, transactions, memory, message draft, sources, photo query, music; any other kind is shown with a generic view of its own values | memory, draft and the generic view verified in a browser; the others are written against the backend's models and not exercised with live data here |
| Spaces: finance summary (this month, last month), basket and store comparison; Memory list with delete and "Keep"; Security (read-only); Activity and history with delete | working; empty states verified in a browser (no statements or baskets exist in a fresh database) |
| Device channel (WebSocket): online presence, approvals pushed from elsewhere, link requests from another device's turn | presence verified end to end; pushed frames verified with unit tests |
| Spoken replies with the browser's speech synthesis, sentence by sentence, Hindi or English voice by language, **on-device voices only** | logic unit-tested; audio not heard here |
| Speech recognition (Web Speech API) with push-to-talk and barge-in | logic unit-tested with fakes; **needs a browser that offers it** (see limits) |
| English and Hindi interface; light, dark and Increase Contrast; Reduce Motion; 320 to 430 points and desktop | verified in headless Chrome |
| Opens offline from the service worker and shows the last conversation from the sealed cache | verified in headless Chrome |

## What only the native apps can do

The web app says each of these on screen (first run, Security, "What the web app can do").

- **Approvals that need Face ID or Touch ID** (`biometric` level: critical actions, high-risk actions
  on a tainted turn or with "Face ID for high-risk" on) and **every security setting change** (privacy
  mode, kill switch, permissions, revoking a device, memory export, deleting a memory category). A
  browser has no hardware-backed key whose use requires user presence. The web app registers the
  second public key the contract asks for and throws its private half away before pairing finishes,
  so no script in the page can ever sign with it. Such requests are shown with an explanation and
  can be cancelled, not answered.
- **Device tools**: alarms, timers, reminders, calendar, contacts, HomeKit, Shortcuts, music control,
  location, notifications, Health, photo search. They are refused honestly, never simulated.
- The Action Button, Lock Screen control, Siri, live cloud voice, notifications, background work.

Limits of a browser, stated plainly:

- **No background listening and no wake word.** ZORO listens only while the app is open and the orb
  is listening, after a tap or while the button is held.
- **Speech recognition is the browser's, not your server's.** Depending on browser and device it may
  send audio to Apple or Google, so the app asks once before first use and can be turned off in
  Settings. Safari does not always offer speech recognition to Home Screen web apps; when it is
  missing or refused, the composer points to the dictation key on the keyboard.
- **Spoken replies use on-device voices only.** A network voice would send ZORO's reply to the browser
  maker. With no on-device voice for a language, replies in it are shown, not spoken.
- **Remote images are not loaded** (product pictures), so nothing is requested from a third party.
- The device channel is open only while the app is on screen.

## Security

- **Keys**: ECDSA P-256 made with WebCrypto as non-extractable keys, kept as `CryptoKey` objects in
  IndexedDB. Public keys are sent as base64 of the 65-byte X9.63 point. Signatures are converted
  from the browser's raw `r || s` to DER, as the server verifies.
- **Signed strings**: `zoro-auth-v1|device_id|nonce` and
  `zoro-approval-v1|approval_id|action_digest|1or0|signed_at`, checked against vectors written by
  `backend/app/security/crypto.py` and by the server's own `verify_signature`.
- **Session token**: in memory only; a reload or a 401 signs a new challenge. No cookies.
- **Conversation cache**: the last conversation is kept on the device sealed with AES-256-GCM under a
  non-extractable key; each record is bound to its name. "Forget this pairing" deletes the keys,
  which makes anything left unreadable.
- **localStorage** holds interface preferences only (language, voice, motion). No token, device id,
  key or conversation text.
- **Content-Security-Policy**: `default-src 'none'`, scripts and styles from this origin only, no
  inline code, connections to this origin only. There is no `innerHTML` in the app: server and tool
  text is always inserted as text.
- **Service worker**: caches the app shell only (the file list is in `sw.js`); API requests are not
  handled by it at all, so no answer, token or personal data enters a browser cache. Updates are
  versioned by a hash of the shell files; the owner chooses when to reload.
- **Links** are opened only after a tap, only `https`, with `noopener,noreferrer`, and the full
  address is shown first.

Known weaknesses a browser cannot remove: the keys are not hardware-backed (a compromised browser
profile could use them, though not copy them), and the device channel passes the token in the
WebSocket address because browsers cannot set a header there.

## Tests

```
cd web
node --test tests/*.test.mjs     # unit tests (no network, no browser)
node tests/e2e.mjs               # the web client modules against the real backend
node tests/browser.mjs           # the real app in headless Chrome against the real backend
```

- `e2e.mjs` starts the backend itself (uvicorn from `backend/.venv`, free local port, temporary
  SQLite database, no provider keys), makes a pairing code with the backend CLI, pairs, signs in,
  runs turns to completion, completes an approval round trip and a device link, and stops the server.
- `browser.mjs` needs a Chrome, Chromium or Edge already installed; it is skipped with a message
  when there is none. It downloads nothing. `--shots <dir>` chooses where screenshots go.
- `signing.test.mjs` runs the server's `verify_signature` from `backend/.venv` when it is present.

Tools:

```
PYTHONPATH=. uv run --no-sync python ../web/tools/make_vectors.py > ../web/tests/vectors/signing.json   # from backend/
node tools/make-icons.mjs        # draws the icon (SVG + PNG) from numbers; no asset is imported
node tools/stamp-shell.mjs       # rewrites the file list and version in sw.js after any change
```

Run `stamp-shell.mjs` after changing any file under `css/`, `js/`, `icons/`, `index.html` or the
manifest; a unit test fails until it is done.

## Layout

```
index.html  manifest.webmanifest  sw.js
css/      tokens.css (the design tokens of docs/design/design-system.md), app.css
icons/    drawn by tools/make-icons.mjs
js/app.js                 composition root, navigation
js/core/                  contract: api, sse, identity, signing, der, pairing, conversation,
                          turn-reducer, device-actions, channel, sealed-cache, store, prefs, format
js/voice/                 sentences, speaker, recognizer, levels, voice-session
js/ui/                    orb (canvas, eight states), rekha, cards, approval, components, icons, dom
js/screens/               pairing, home, home-composer, activity, spaces, you
js/i18n/                  en.js, hi.js (same keys; the Hindi is a reference translation, not yet
                          reviewed by a second native speaker)
tests/                    unit tests, e2e.mjs, browser.mjs, vectors/
tools/                    serve.mjs, make-icons.mjs, stamp-shell.mjs, make_vectors.py, verify_signature.py
```

## Not verified here

This machine has no iPhone, no Safari automation and no Xcode. Not checked:

- Safari on iOS and the installed Home Screen app: safe areas, keyboard behaviour, the status bar,
  Dynamic Type sizes, VoiceOver reading order, Add to Home Screen itself.
- Speech recognition and speech synthesis with real audio, in any browser.
- The orb's frame rate on a phone (60 frames a second was measured in headless Chrome on this Mac).
- Whether `connect-src 'self'` covers the same-origin WebSocket in every Safari version; if a
  version blocks it the channel stays off and the app works without it.
- SF Pro Expanded for titles relies on the system font's width axis (`font-stretch`); where the
  browser does not offer it, titles are set in the regular width.
- Cards for products, baskets, comparisons, finance and transactions with live data.
