# ZORO design spec

Normative. Builders implement against this document, `CLAUDE.md`, and the seed contract code in
`backend/app/schemas/`, `backend/app/core/types.py`, `backend/app/db/base.py`, `backend/app/security/egress.py`.
Verified facts about third-party APIs are in `docs/research/research-2026-11-12.json` (read the topic you need).

## 1. What ZORO is

One assistant the owner talks to in Hindi, English or Hinglish, on iPhone and Mac. Behind it: a private
backend the owner runs (their Mac or a home server, reached over Tailscale) that holds memory, runs
specialist agents and tools, and decides what may leave the machine. The phone and the Mac are both
interfaces *and* execution environments: device tools (alarms, reminders, photos, health, music, Mac
automation) run natively on the device when the backend asks.

Anti-goals: a chatbot skin; a pile of unrelated demo screens; fake data that looks live; a model that
can approve its own actions; pretending iOS allows things it does not.

## 2. Shape of the system

```
iPhone app ─┐                      ┌─ model gateway ── Gemini / OpenAI-compatible / local
            ├─ HTTPS + SSE + WS ───┤─ supervisor graph (LangGraph) ── specialist agents
Mac app ────┘   (Tailscale)        │─ tool executor ── policy engine ── audit log
   │                               │─ domain packages (finance, shopping, …) as plugins
   └─ native device tools ◀────────┤─ MCP gateway (tool groups over Streamable HTTP)
      (run on request)             └─ PostgreSQL + pgvector, object store, optional Redis
```

A **turn**: device sends text (typed, or transcribed on device) → backend routes it → agents call tools
through the executor → results stream back as events (text, cards, agent activity). When a tool needs
the owner's approval or must run on the device, the turn **suspends**; the device answers and the turn
**resumes**. Approvals are device signatures the model cannot produce.

Deterministic first: intent routing, slot filling, money maths and analytics are plain code. A model is
used for open-ended language (interpretation, drafting, synthesis) and only when the privacy policy allows
that data to reach that model. With no model available ZORO still routes and answers known intents.

## 3. Repository layout and ownership

```
zoro/
  config/            runtime config, reloadable without rebuilding apps (models, policy, providers, charges)
  backend/app/
    core/ db/ schemas/ security/ tools/ plugins.py main.py cli.py api/     ← kernel
    providers/                                                             ← model gateway
    agents/ orchestrator/                                                  ← supervisor + specialists
    mcp/ devices/                                                          ← MCP gateway, device hub + device tools
    memory/ documents/ finance/ investment/ shopping/ research/
    fitness/ vision/ voice/ music/ communications/ automation/             ← domain packages
  backend/tests/<package>/
  ios/Packages/<Package>/        Swift packages shared by both apps
  ios/ZORO, ios/ZOROWidgets, ios/ZOROTests, ios/ZOROUITests, ios/project.yml
  macos/ZOROMac, macos/Tests, macos/project.yml
  infrastructure/ docs/ scripts/ docker-compose.yml .env.example
```

Every backend package registers itself through `app/<pkg>/plugin.py: register(reg)`; nobody edits a shared
file to add a tool, router, intent or capability. ORM models live in `app/<pkg>/models.py` on the shared
`Base` and are discovered by package name. Migrations are generated once, after all packages exist.

## 4. Security model

**Devices and sessions.** A device pairs once with a one-time code (`python -m app.cli pairing-code`,
10-minute validity, stored hashed) and registers two P-256 public keys: an *auth key* and an *approval
key* whose use requires user presence (Secure Enclave access control: Face ID / Touch ID / passcode).
Sessions: challenge → signature → 15-minute JWT (HS256, `sub` = device id, `sid`). No refresh tokens;
the device re-signs. Revoking a device or flipping the kill switch invalidates sessions immediately.

**Policy engine.** `PolicyEngine.evaluate(tool, ctx) → allow | approval(level) | deny(reason)`, from static
tool metadata only. Order: kill switch → device not revoked → agent on the tool's allowlist → permission
grant → rate limit → risk rule:

| Risk | Rule |
|---|---|
| LOW | allow |
| MEDIUM | allow when the owner asked for it in this turn and the turn is not tainted; otherwise `confirm` |
| HIGH | `confirm` showing recipient and exact content; `biometric` if the turn is tainted or the owner enabled "Face ID for high-risk" |
| CRITICAL | always `biometric`; 2-minute expiry; payments and trades are never executed by ZORO, only handed off |

**Approvals.** The server computes `action_digest = sha256(canonical {tool, args})` and creates an
`ApprovalRequest`. The device shows it, authenticates the owner when required, and signs
`zoro-approval-v1|approval_id|action_digest|1or0|signed_at`. The server verifies the signature against the
device's registered key for that level, checks digest and expiry, rejects replays, then executes exactly
the digested arguments. Security settings changes (privacy mode, kill switch, permissions, device revoke,
memory export, category delete) carry a `SignedProof` made with the approval key.

**Privacy modes.** `strict_private` (default): no external inference, private retrieval, read-only finance.
`cloud_intelligence`: approved external providers, only data classes the owner granted per provider
(`cloud.sensitive`, `cloud.financial`, `cloud.health` grants; default public + personal), redaction before
sending (PAN, Aadhaar, card and account numbers, UPI IDs, phone, email). Enforced by `decide_egress` inside
the gateway; every model request carries the set of data classes of everything in its prompt. Moving to
cloud mode needs a signed proof. A client may ask for a stricter mode per turn, never a looser one.

**Taint.** Results of tools marked `untrusted_output` are wrapped
(`<untrusted source="…">…</untrusted>`), never placed in the system role, and mark the turn tainted, which
raises the approval level one step for requests the owner made in this turn (MEDIUM: allow → confirm;
HIGH: confirm → biometric). A tool never grants another tool permissions.

**Audit.** Append-only, hash-chained (`hash = sha256(prev_hash + canonical record)`): every policy decision,
approval, tool run, egress decision, settings change. No raw sensitive payloads; arguments are summarised.

**Secrets.** Integration tokens are encrypted with AES-256-GCM (`ZORO_DATA_KEY`) in `integration_credentials`
through `SecretStore`. Nothing sensitive is logged. The app keeps keys in Keychain / Secure Enclave.

**Kill switch.** One flag: all tool execution and all external inference stop; only auth and security
endpoints answer.

## 5. Kernel interfaces (backend)

```python
# app/tools/spec.py
@dataclass(frozen=True)
class ToolSpec:
    name: str                              # "<package>.<verb_noun>", e.g. "finance.spending_summary"
    description: str                       # shown to models and MCP clients
    input_model: type[BaseModel]
    output_model: type[BaseModel]
    handler: ToolHandler | None            # async (ctx, args) -> output_model; None for device tools
    risk: RiskLevel
    data_classes: frozenset[DataClass]     # what the result may contain
    permission: str | None                 # grant key, e.g. "finance.read"
    agents: frozenset[AgentId]             # allowlist
    mcp_group: str                         # e.g. "finance-mcp"
    executor: Literal["backend", "device"] = "backend"
    device_platforms: frozenset[DevicePlatform] = frozenset()
    timeout_s: float = 20
    rate_limit_per_min: int = 60
    untrusted_output: bool = False
    summarizer: Callable[[BaseModel, str], str] | None = None   # (result, "en"|"hi"|"hinglish") -> sentence
    card: Callable[[BaseModel], UICard | None] | None = None

class ToolContext:   # turn_id, conversation_id, device_id, agent, privacy_mode, lang, timezone, tainted,
                     # user_initiated, now(), db (async session factory), gateway, secrets, objects,
                     # audit, settings, emit(event)

ToolOutcome = Completed(result) | NeedsApproval(request) | NeedsDeviceAction(request) | Denied(reason) | Failed(error)

class ToolExecutor:
    async def execute(self, ctx, tool_name, raw_args, *, call_id) -> ToolOutcome
    async def resume_with_approval(self, ctx, call_id, decision) -> ToolOutcome
    async def resume_with_device_result(self, ctx, call_id, result) -> ToolOutcome

# app/tools/intents.py — how a package teaches the local router its intents (no model needed)
@dataclass(frozen=True)
class IntentSpec:
    name: str; agent: AgentId; tool: str
    keywords: Mapping[str, Sequence[str]]                    # {"en": […], "hi": […], "hinglish": […]}
    extract: Callable[[str, IntentContext], dict | None]     # slot filling; None = not this intent
    examples: Sequence[str] = (); priority: int = 0

# app/plugins.py
class PluginRegistry:
    add_tool(spec) · add_intent(spec) · add_router(router)   # routers mounted under /v1
    add_capability(cap) · add_permission(key, title, default) · add_startup(fn) · add_shutdown(fn)
    set_device_dispatcher(dispatcher)
```

Executor pipeline: allowlist → validate args → policy → rate limit → run with timeout → validate result →
audit → wrap if untrusted. Device tools: when the target is the requesting device the outcome is
`NeedsDeviceAction`; otherwise `DeviceDispatcher.dispatch(device_id, request, timeout)` pushes it over that
device's channel. Offline target → `Failed("device_offline")`.

Kernel also provides: settings, `Clock`, `Money` helpers, `AuditLog`, `ApprovalService`, `KillSwitch`,
`SecretStore`, `FieldCipher`, `ObjectStore` (filesystem or MinIO), `EmbeddingType` + vector search helper
(pgvector on PostgreSQL, portable fallback on SQLite), FastAPI dependencies (`get_session`,
`require_device`), and test fixtures (`client`, `db`, `paired_device` with software keys, fake gateway
under `tests/fakes/`).

## 6. Model gateway (`app/providers`)

`gateway.chat(ChatRequest) -> ChatResponse`, `gateway.stream(...)`, `gateway.embed(texts, data_classes)`.
A request names a `TaskClass`, never a model. `config/models.yaml` holds providers (kind, base URL, key env
var, locality, allowed data classes), models (id, price per 1M tokens, context window, capabilities) and
routes (task → ordered model list). Two adapters cover everything: Gemini native (`generateContent`) and
OpenAI-compatible (OpenAI, xAI, DeepSeek, Qwen, Kimi, Groq, Together, Ollama / any local server). Per
request: egress decision → redaction → context-window trim → call with retry and backoff → circuit breaker
and rate-limit detection → fallback to the next permitted model → usage event (tokens, latency, cost,
error). Health checks are cheap and cached. Config reloads on change. If no permitted model exists the
gateway raises `NoPermittedModel`; callers fall back to deterministic behaviour. A deterministic local
hashing embedder (`local-hash-v1`) keeps memory search working offline.

## 7. Orchestrator and agents

`AgentSpec` (in `app/agents`): id, role, system prompt, input/output models, tool allowlist (derived from
`ToolSpec.agents`), task class, max seconds, max tokens, max tool iterations, retry and fallback policy,
restrictions. Seventeen specs (see `AgentId`). The Voice agent is the conversational front (language,
brevity, speakable phrasing); the Security agent is the explainer for policy decisions and has no power
over them.

Supervisor graph per turn:

1. **ingest** — conversation state, language id (script + lexicon), privacy mode, budget.
2. **route** — registered `IntentSpec`s scored locally; if confidence is low and a model is permitted, a
   structured routing call; else the personal assistant. Emits `route`.
3. **recall** — memory retrieval for enabled categories, each item labelled with its data class.
4. **work** — selected agents run in parallel for read-only work (deterministic tool plan from extracted
   slots, or a bounded model tool loop). Tool calls that need approval or a device are queued.
5. **actions** — queued calls run one at a time; each may `interrupt()` for an approval or device result.
   Code before `interrupt()` re-runs on resume, so it must be side-effect free.
6. **synthesize** — model phrasing when permitted, otherwise the tools' `summarizer` text. A numeric guard
   rejects any reply containing a number absent from tool results and falls back to the deterministic text.
7. **remember** — the memory agent proposes memories (sensitive ones land in `pending_review`).
8. **finish** — persist message, usage, audit; emit `turn_completed`.

Limits: recursion limit, per-turn token / tool-call / wall-clock budgets, per-agent timeouts. State is
checkpointed (PostgreSQL in production, SQLite or memory in development) so a suspended turn survives a
restart and can be resumed from another device.

## 8. API surface

Cross-cutting (models in `app/schemas`): `POST /v1/auth/pair|challenge|token` · `POST /v1/turns` (SSE) ·
`POST /v1/turns/{id}/resume` (SSE) · `POST /v1/turns/{id}/cancel` · `GET /v1/conversations` ·
`GET /v1/conversations/{id}/messages` · `DELETE /v1/conversations/{id}` · `GET /v1/approvals/pending` ·
`GET /v1/security/state` · `PUT /v1/security/privacy-mode` · `POST /v1/security/kill-switch` ·
`PUT /v1/security/permissions/{key}` · `POST /v1/security/devices/{id}/revoke` · `GET /v1/security/audit` ·
`GET /v1/capabilities` · `GET /v1/costs/summary` · `GET /v1/models/routes` · `GET /v1/devices/channel` (WS) ·
`GET /healthz`. Lists are cursor-paginated (`Page`). Errors use `ErrorBody` with a stable `code`.

| Package | API prefix | MCP group(s) |
|---|---|---|
| memory | `/v1/memory` | memory-mcp |
| documents | `/v1/documents` | document-mcp, storage-mcp |
| finance | `/v1/finance` | finance-mcp |
| investment | `/v1/investments` | investment-mcp |
| shopping | `/v1/shopping` | shopping-mcp |
| research | `/v1/research` | browser-research-mcp |
| fitness | `/v1/fitness` | fitness-mcp |
| vision | `/v1/vision` | ios-photos-mcp |
| voice | `/v1/voice` | — |
| music | `/v1/music` | music-mcp |
| communications | `/v1/communications` | communication-mcp |
| automation | `/v1/automations` | — |
| devices | `/v1/devices` | ios-device-mcp, mac-device-mcp, calendar-mcp, location-mcp, notification-mcp, home-assistant-mcp |

The MCP gateway serves each group at `/mcp/<group>` (Streamable HTTP, bearer device token), every call going
through the same executor and policy. External MCP servers (for example Swiggy Instamart) are allowlisted
clients whose results are untrusted.

## 9. Apple architecture

Swift packages under `ios/Packages/` (tools 6.0, language mode 5 + strict-concurrency warnings, iOS 18 /
macOS 15, Swift Testing, no third-party dependencies):

| Package | Targets | Depends on |
|---|---|---|
| ZoroKit | ZoroCore, AgentClient, SecurityManager, PermissionManager, ConversationManager, MemoryClient, ModelRouter | — |
| ZoroDesign | ZoroDesign | — |
| ZoroVoice | AudioEngine, VoiceInterface | ZoroKit |
| ZoroDevice | NativeActionBroker, HealthIntegration, MusicIntegration | ZoroKit |
| ZoroPhotos | PhotoIntelligence | ZoroKit |
| ZoroCommerce | ShoppingInterface, FinancialInterface, InvestmentsFeature | ZoroKit, ZoroDesign |
| ZoroLife | FitnessFeature, PhotosFeature, MusicFeature | ZoroKit, ZoroDesign |
| ZoroSystem | SystemFeatures (memory, integrations, device control, security and privacy, settings, history, agent activity) | ZoroKit, ZoroDesign |
| ZoroApp | ZoroAppUI (navigation, Home, Live Voice, onboarding, composition root, App Intents) | all |

`ZoroCore` holds Codable mirrors of the backend contract (snake_case decoding, money as `Decimal` from
string, ISO-8601 with or without fractional seconds) and the protocols features depend on, so feature
packages never import capability packages: `ZoroAPI` (typed requests + SSE turn stream),
`DeviceIdentityProviding` (pair, sign challenge / approval / proof), `KeyStoring`, `BiometricAuthenticating`,
`VoiceSessionControlling`, `DeviceActionExecuting`, `PhotoSearching`, `HealthDataProviding`,
`MusicControlling`, `LocalIntentClassifying`, plus `ZoroServices` injected through the SwiftUI environment.
`ZoroApp` wires concrete implementations. The Xcode app targets are thin wrappers (entry point, Info.plist,
entitlements, `AppShortcutsProvider`, widget extension for the Lock Screen control and Live Activity).

Local storage: SQLite (system library) in a file with complete data protection; sensitive columns
additionally sealed with AES-GCM using a Keychain key. On-device first: language id, intent
classification for device commands, photo indexing and search, health queries, speech recognition and
synthesis in private mode.

Voice: `VoiceInterface` runs a state machine (idle, listening, processing, delegating, tool execution,
speaking, error, private) over two engines. *On-device*: Apple speech recognition → turn over SSE →
sentence-chunked system speech, barge-in stops speech and cancels the turn. *Cloud* (cloud mode, key
present): direct WebSocket to the realtime voice model with an ephemeral token minted by the backend; the
model's single tool is "ask ZORO", which runs a normal turn, so policy stays on the backend; replies whose
`cloud_voice_allowed` is false are spoken on device instead. No wake word outside an active session.
Latency is measured (time to first feedback, to first audio), not promised.

## 10. Experience

**First run.** Welcome → connect to your ZORO server (address + pairing code, or scan the QR the setup
script prints) → the device creates its keys → choose language and voice → set up the Action Button and
Lock Screen control (guided, optional). Permissions are asked in context, the first time a feature needs
them, each with one plain sentence on what it is for.

**Every day.** Press the Action Button (or tap the orb, or say "Ask ZORO" to Siri) → the orb listens →
words appear as you speak → the orb shows who is working → the answer is spoken and shown, with cards you
can act on → follow-ups keep context ("add the second one"). Anything consequential shows exactly what
will happen and waits for you.

**Navigation.** iPhone: four tabs — *ZORO* (orb, live voice, current conversation), *Spaces* (Shopping,
Finance, Investments, Fitness, Photos, Music), *Activity* (agent activity, history), *You* (Memory,
Integrations, Device control, Security and privacy, Settings). Mac: sidebar with the same sections and a
menu-bar orb for quick voice. Every section has empty, loading, error and disconnected states that say
what to do next.

**Visual identity.** Native materials, system backgrounds, SF Symbols; one bold element, the orb, and one
structural idea, the *rekha*: a single horizontal line across the voice screen. Devanagari hangs from a
headline and Latin sits on a baseline, so your voice hangs below the line and ZORO's rises above it — the
bilingual conversation drawn on one stroke. Everything else stays quiet.

- Colour (light / dark): *neel* indigo `#2A2F8F` / `#5B62E0` · *mor* peacock teal `#0B7F86` / `#19B5B0` ·
  *genda* marigold `#D98A00` / `#FFB321` · *lac* red `#B5302A` / `#FF6B5E` · *moonstone* `#6E7A8A` /
  `#A9B4C2` (private mode). Neutrals are system semantic colours. Peacock iridescence (neel → mor → a
  thread of genda) is the orb's signature; no purple-pink gradients.
- Type: SF Pro Expanded semibold for titles and amounts; New York (system serif) for ZORO's own words;
  SF Pro for interface text; monospaced digits for figures; extra leading on mixed-script lines.
- Orb states: idle (slow breath) · listening (opens, ripples with your voice) · processing (iridescent arc
  turns) · delegating (one satellite per working agent) · tool execution (satellites dock, a ring sweeps) ·
  speaking (marigold warmth with ZORO's voice) · error (lac tint, one shake, then settles) · private
  (moonstone, sealed ring, no iridescence). Reduce Motion: no deformation, opacity only. Low Power: 30 fps.
- Words: sentence case, plain verbs, one name per action through a flow, errors say what happened and what
  to do. No all-caps labels.

## 11. Environment variables

`ZORO_ENV` · `ZORO_DATABASE_URL` (default `sqlite+aiosqlite:///./.local/zoro.db`; production
`postgresql+psycopg://…`) · `ZORO_SECRET_KEY` · `ZORO_DATA_KEY` (base64, 32 bytes) · `ZORO_CONFIG_DIR` ·
`ZORO_REDIS_URL` (optional) · `ZORO_OBJECT_STORE` (`fs` | `minio`) · `ZORO_OBJECT_DIR` · `ZORO_MINIO_*` ·
`ZORO_PUBLIC_BASE_URL` · `ZORO_DEFAULT_PRIVACY_MODE` · `ZORO_CONVERSATION_RETENTION_DAYS` (30) ·
`ZORO_ACCESS_TOKEN_TTL_SECONDS` (900). Provider keys: `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`,
`DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY` + `QWEN_BASE_URL`, `MOONSHOT_API_KEY`, `GROQ_API_KEY`,
`TOGETHER_API_KEY`, `OLLAMA_BASE_URL`, `ELEVENLABS_API_KEY`, `GOOGLE_TTS_API_KEY`. Integrations:
`SPOTIFY_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET`, `STRAVA_CLIENT_ID` / `_SECRET`, `KITE_API_KEY` /
`_SECRET`, `DHAN_CLIENT_ID` / `DHAN_ACCESS_TOKEN`, `FLIPKART_AFFILIATE_ID` / `_TOKEN`,
`HOME_ASSISTANT_URL` / `_TOKEN`. A missing key disables that integration and shows in the capability
registry as "needs credentials"; it is never an error at startup.

## 12. Verification on this machine

| Check | Command | Possible here |
|---|---|---|
| Backend tests | `cd backend && uv run --no-sync pytest` | yes |
| Lint, types | `uv run --no-sync ruff check . && uv run --no-sync mypy app` | yes |
| PostgreSQL + pgvector integration | `scripts/dev_db.sh start`, then `pytest -m postgres` | yes (Homebrew PostgreSQL 17) |
| Swift packages build + tests (macOS host) | `scripts/swiftpm.sh <Package> test` | yes |
| iOS app build, UI tests, simulator | `xcodebuild` | no — Xcode is not installed |
| Docker Compose health | `docker compose up` | no — Docker is not installed |
| Live provider calls | needs API keys | no — none configured |
