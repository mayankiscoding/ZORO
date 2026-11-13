# ZORO

A private, voice-first personal assistant: native iPhone and Mac apps, a web app for Safari, and a
Python backend you run on your own machine. Hindi, English and Hinglish.

## What is here and how far it is verified

| Part | Where | Verified on the build Mac (no Xcode, no Docker) |
|---|---|---|
| Backend (agents, tools, policy, MCP gateway, memory, finance, shopping, investments, …) | `backend/` | 1,565 tests pass; lint and type check clean |
| Swift packages (core, design, voice, device, photos, dashboards, app shell, composition) | `ios/Packages/` | built and unit-tested for macOS only |
| Mac companion | `macos/` | compiles; smoke test renders its windows |
| iPhone app, widgets, Xcode projects | `ios/ZORO*`, `ios/project.yml` | generated, **never compiled** (needs Xcode) |
| Web app for Safari | `web/` | unit, end-to-end and headless-Chrome tests reported passing; not tried on an iPhone |
| Cloud `.ipa` builds | `.github/workflows/ios-build.yml`, `codemagic.yaml` | **never run** |

No provider API keys were available, so no live model, voice, Spotify, Gmail or shopping call was made.

## Start the backend

```sh
scripts/install.sh          # checks prerequisites, creates .env with fresh keys
scripts/dev_up.sh           # local PostgreSQL + backend on 127.0.0.1:8787
cd backend && uv run --no-sync python -m app.cli pairing-code
```

## Get ZORO on your iPhone

- Today, without Xcode: the web app. See `web/README.md`.
- Native app: see `docs/setup/install-on-iphone.md` (Xcode, cloud-built `.ipa` plus sideloading, or TestFlight).
- First build in Xcode: `docs/setup/first-xcode-build.md` and `docs/setup/unverified-ios-code.md`.
- Siri: `docs/setup/siri.md`.

## More

- Design and rules: `docs/architecture/design-spec.md`, `CLAUDE.md`
- Decisions: `docs/architecture/adr/0001-foundations.md`
- Device tools: `docs/architecture/device-contract.md`
- API: `docs/api/openapi.json`
- Assets and licences: `assets/LICENSES.md`

Keep this folder out of iCloud-synced locations (Desktop, Documents): it holds your assistant's data.
