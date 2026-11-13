# ADR 0001 — Foundations

Status: accepted, 2026-11-13. Evidence: `docs/research/research-2026-11-12.json` (official docs fetched 2026-11-12).

## Context

A single owner wants a private, voice-first assistant across iPhone 17 and Mac, India-first, using Gemini
credits where allowed. The build machine has no Xcode, no Docker and little disk.

## Decisions

| # | Decision | Why | Rejected |
|---|---|---|---|
| 1 | **LangGraph 1.2** for the supervisor graph, with `interrupt()` / `Command(resume=…)` and the PostgreSQL checkpointer | MIT, active, first-class human-approval interrupts and durable state — exactly the suspend/resume a signed approval needs | agno (overlaps), Letta (server API in flux), pydantic-ai (ideas only: typed tools and outputs) |
| 2 | **Own thin memory layer on PostgreSQL + pgvector**, not Mem0 | We need per-record source, confidence, verification time, sensitivity and review state; Mem0 adds OpenAI / PostHog / Qdrant dependencies and telemetry that is on by default | Mem0 self-hosted (possible later behind the same interface, with `MEM0_TELEMETRY=false`) |
| 3 | **MCP Python SDK 2.x** (`MCPServer`, Streamable HTTP) for the gateway | Official SDK; v2 renamed FastMCP and removed WebSocket, so we pin `>=2.3,<3` | Reference servers repo (mostly archived, described as educational) |
| 4 | **Two model adapters**: Gemini native and OpenAI-compatible | Covers Gemini, OpenAI, xAI, DeepSeek, Qwen, Kimi, Groq, Together and Ollama with one HTTP client each; every model id, URL and price is in `config/models.yaml` | Vendor SDKs per provider (weight, churn) |
| 5 | **Gemini `generateContent`** for chat today | Stable and widely served; Google now labels it legacy in favour of the Interactions API, so the adapter has an `api_style` switch | Interactions API first (could not be exercised without a key) |
| 6 | **Voice: device connects straight to Gemini Live with an ephemeral token**; on-device Apple speech is the private default | Lowest latency, key never on the phone, policy stays on the backend because the live model's only tool is "ask ZORO" | Pipecat / LiveKit server pipelines (unneeded hop for one user; revisit for server-side voice) |
| 7 | **Deterministic first**: local intent router, slot filling, analytics and money maths in code; a numeric guard on model wording | Cost, latency, offline use, and "a model must never invent a total" | Model-routed everything |
| 8 | **Approvals are device signatures** (P-256; approval key bound to user presence in the Secure Enclave) | The model cannot forge one; the server executes exactly the digested arguments | In-band "are you sure?" prompts |
| 9 | **Strict private mode is the default**; egress decided by one pure function inside the gateway | A privacy rule that lives in a prompt is not a rule | Per-agent privacy checks |
| 10 | **Money as integer paise in the database, `Decimal` in code, strings in JSON** | Exact on PostgreSQL and SQLite alike | `NUMERIC` (lossy on SQLite), floats |
| 11 | **Swift packages + thin Xcode wrappers**; language mode 5 with strict-concurrency warnings; Swift Testing | Nearly all Swift type-checks and tests on the macOS host without Xcode; mode 5 avoids new hard errors from SDK annotations we cannot see here; XCTest is absent from Command Line Tools | One monolithic app target; Swift 6 mode before a first Xcode build |
| 12 | **No finance or trading framework embedded** (TradingAgents, FinGPT, FinRobot, FinRL) | US-data oriented or heavy or stale; we borrow the analyst-team structure only | Embedding any of them |
| 13 | **Shopping: official routes only** — Swiggy Instamart through its official MCP server; Flipkart Affiliate API when the owner has affiliate credentials; everything else is search handoff plus owner-confirmed price capture | No other quick-commerce app publishes an API; unofficial "MCP servers" are scrapers | Scraping, unofficial APIs |
| 14 | **Finance data: statement imports first**; Account Aggregator stays an interface | Only regulated entities may be an FIU | Pretending a personal app can be an FIU |
| 15 | **One PostgreSQL driver (psycopg 3)** for SQLAlchemy and the LangGraph checkpointer | Fewer moving parts | asyncpg + psycopg |
| 16 | **Local infrastructure without Docker is first-class** (`scripts/dev_db.sh`, Homebrew PostgreSQL 17 + pgvector); Docker Compose is provided for hosts that have it | The build machine has no Docker | Docker-only setup |

## Known risks

- Model ids and prices change monthly (several Gemini ids retire on 2026-11-17 and 2026-12-01; Gemini 3.8
  prices double on 2027-01-01). They are configuration, stamped with the date verified.
- Hindi: Apple's on-device model does not list Hindi; `SpeechTranscriber` and Vision OCR support for
  `hi-IN` must be checked at runtime. Hinglish quality on any engine needs testing on a device.
- iOS-only code paths (AlarmKit, ActivityKit, controls, message composer, HomeKit) cannot be compiled here.
- Swiggy production access is by application; local development works without approval.
- Broker APIs need a static IP and daily two-factor login; ZORO stays read-only and hands orders off.
