# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CC-Go lets an Android phone remotely control Claude Code running on the user's computer: the phone pairs with a daemon over TLS WebSocket, then creates/watches/prompts Claude Code sessions and answers permission requests from the chat UI. The SSH tunnel is planned for M4.

- `daemon/` — the PC side (Node.js/TypeScript): pairing, TLS, authenticated WebSocket, session management, project registry, and Claude Code session-history discovery/replay/takeover.
- `app/` — the phone side (Flutter, Android only, `dev.luke.cc_go`, minSdk 26). Implemented: pairing (code / QR / mDNS / SSH-tunnel host entries), multi-host management, direct + SSH-tunnel connections, session list grouped by project, chat transcript (queue-mode send, interrupt), inline permission cards, project session-history browse with read-only replay and takeover, background keep-alive + notifications, auto-reconnect with snapshot resync. Device acceptance steps live in `docs/VERIFICATION.md`.
- `reference/` — **read-only** third-party codebases kept for pattern reference: `dsh-Go` (Flutter chat-UI patterns) and `happy-main` (happy-cli — driving Claude Code via the Agent SDK). `docs/ARCHITECTURE.md` maps which techniques come from which project.
- `docs/ARCHITECTURE.md` (written in Chinese) — authoritative design doc: architecture diagram, confirmed decisions, milestones M1–M4.
- `openspec/` — spec-driven change management via the `openspec-*` skills. The task checkboxes are the acceptance record; do not check an item merely because code exists.
- `README.md` — setup and normal development entry point. `docs/VERIFICATION.md` — device acceptance steps.

## Commands

All daemon commands run from `daemon/`:

```bash
cd daemon
npm ci
npm run build        # tsc → dist/
npm run dev          # tsx watch src/index.ts
npm run typecheck    # tsc --noEmit
npm test             # vitest run — unit and local HTTP/WebSocket boundary tests
```

### Running the daemon

```bash
node bin/cc-go.mjs [--port 8747] [--localhost] [--name <name>] [--code <code>] [--no-tls] [--project <dir> ...]
```

- All endpoints (HTTP + WebSocket) are served over **TLS by default** (`https`/`wss`): a self-signed ECDSA P-256 certificate is generated on first run into `~/.cc-go/tls-{cert,key}.pem` and reused. Startup prints its SHA-256 fingerprint next to the pairing code — clients pin it on first connection (TOFU) and fail closed if it changes.
- `--localhost` binds 127.0.0.1 (SSH-tunnel mode); default binds 0.0.0.0. `--no-tls` is a plaintext dev mode that forces loopback binding. `--project <dir>` (repeatable) registers a project-directory whitelist — sessions may only be created/discovered/imported inside registered projects; with none registered, the startup directory becomes the default project.
- **LAN discovery & QR pairing** (`src/discovery.ts`): in default (LAN + TLS) mode the daemon advertises `_ccgo._tcp` over mDNS with its cert fingerprint in the TXT record, and the startup banner prints a `ccgo://pair?host=…&port=…&code=…&fingerprint=…` QR code (built by `pairingQrPayload` in `server.ts`). `--localhost` and `--no-tls` never advertise; the QR carries no fingerprint in plaintext mode.
- Requires the `claude` CLI on PATH and authenticated — the Agent SDK spawns it for every session.

### Smoke test (end-to-end, plays the phone)

```bash
mkdir -p /tmp/ccgo-test          # session cwd must exist; the client doesn't create it
node bin/cc-go.mjs --code 654321 # terminal 1
node test/smoke-client.mjs 654321  # terminal 2, from daemon/
```

The smoke client pairs over HTTPS, opens the WebSocket, and exercises: Q&A turn → permission-gated tool call (allowed from the "phone") → cancel mid-turn. Defaults to `127.0.0.1:8747` and `/tmp/ccgo-test`; flags: `--host/--port`, `--fingerprint <sha256>` (TOFU compare — mismatch exits non-zero), `--plain` (for a `--no-tls` daemon). First connection learns and stores the cert fingerprint in `/tmp/ccgo-smoke-known.json`.

### App (Flutter, Android)

```bash
cd app
flutter pub get              # first run or dependency changes
flutter analyze               # zero warnings required
flutter test
flutter run                   # needs a device visible in adb devices
flutter build apk --debug     # → build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release   # signed with the debug keystore (personal sideload, design D6)
```

- The project targets Flutter 3.50.0, JDK 17 and an Android SDK. For networks that cannot reach pub.dev, use the mirror command in `README.md` when installing dependencies. CI uses the default package source.
- Android: `applicationId dev.luke.cc_go`, minSdk 26, Android is the only platform.
- Full repository check: `bash scripts/check.sh --setup` on first use, then `bash scripts/check.sh`. CI uses the same command. Node and Flutter versions are pinned in `.node-version` and `.fvmrc`.

## Daemon architecture

Four layers, one direction of dependency: `server.ts` → `agent/manager.ts` → `agent/session.ts`, with `protocol.ts` defining every type that crosses the wire and `store.ts` persisting state.

- **`src/protocol.ts`** — Zod schemas for the whole wire protocol. A single WebSocket carries JSON frames: requests `{id, method, params}` → responses `{id, ok, result|error}`, plus pushes `{type: "event", event}`. A session transcript is a list of **items** (`user` / `assistant` / `tool` / `notice`); the daemon owns the list and every `item.updated` carries the complete item, so the phone replaces items wholesale and snapshot + live stream merge idempotently by item id.
- **`src/server.ts`** — network face. HTTP `/health`, `/info` (pre-pairing host info), `/pair` (6-digit code → long-lived device token; rate-limited, timing-safe compare). WebSocket `/ws`: first message must be `hello {token}` (10 s timeout). Transcript events go only to connections that called `session.watch`; `permission.request` and `sessions.changed` are broadcast to every authed connection (the phone needs notifications even without the chat screen open).
- **`src/agent/manager.ts`** — owns live sessions and fans events out to the server. Summaries are persisted on every change; after a daemon restart `ensureLive()` rehydrates a persisted session on demand — same id, Claude context survives via `resume: claudeSessionId`, replaying `~/.claude/projects` JSONL into items is implemented for imported sessions (`src/history.ts`); plain rehydrated sessions still start with a notice.
- **`src/agent/session.ts`** — one Claude Code conversation via `@anthropic-ai/claude-agent-sdk` `query()`:
  - Prompts flow through a queue into `PushablePrompt` (a pushable async iterable passed as the SDK prompt stream). One `query()` spans multiple turns while work remains, then is recreated with `resume`. Claude's resume forks under a **new** session id, so the current id is re-tracked from every message frame (`trackClaudeSession`).
  - Send modes: `queue` (wait for the current turn) vs `interrupt` (abort, then send). `cancel` aborts and denies all pending permissions.
  - Permissions: `canUseTool` parks a Promise → `permission.request` event → phone answers via `permission.respond {itemId, allow, allowToolForSession}`.
  - Stream deltas build assistant items incrementally; the final `assistant` message replaces the draft wholesale. Own prompts echoed back by the SDK are dropped via a 90 s echo-guard map keyed by text.
  - Sets `CLAUDE_CODE_ENTRYPOINT=cc-go` so daemon sessions stay visible in `claude --resume`.
- **`src/store.ts`** — single `~/.cc-go/store.json` (atomic tmp+rename, mode 0600): daemon id/name, paired device tokens, session summaries, project-directory whitelist.
- **`src/history.ts`** — reads Claude Code's own transcripts under `~/.claude/projects/<encoded-cwd>/`: discovery, paged replay through the shared JSONL→item `TranscriptMapper`, import prefill, and the lineage-checked tail that merges terminal-side `--resume` writes into imported sessions.
- **`src/tls.ts`** — self-signed certificate lifecycle: generated on first run (`selfsigned`, ECDSA P-256), persisted in `~/.cc-go/`, reused across restarts; exposes the openssl-style SHA-256 fingerprint clients pin (TOFU).
- **`src/discovery.ts`** — mDNS advertisement (`bonjour-service`, `_ccgo._tcp`, fingerprint in TXT) started by `server.ts` only in LAN+TLS mode; stopped when the server closes.

## App architecture

Pure-Dart cores, Flutter only at the edges — transport and state logic run (and are tested) headless. One `HostLink` connection under everything.

- **`lib/transport/`** — `host_link.dart` is the `smoke-client.mjs` logic as a Dart client: JSON-RPC request/response pairing over one WebSocket plus a typed event stream; `tofu.dart` pins the daemon cert's SHA-256 (first connection records it, mismatch refuses the connection, "forget host" clears it); `reconnecting_link.dart` adds exponential-backoff reconnect and replays `hello` + watch subscriptions afterwards, exposing link state as a `BehaviorSubject` (new subscribers immediately get the current value).
- **SSH tunnel mode** — `lib/transport/ssh/ssh_tunnel_link.dart`: dartssh2 connects, opens a `forwardLocal` direct-tcpip channel up front (forward-refused surfaces as a typed error from `connect`), bridges a local `127.0.0.1` ephemeral `ServerSocket` to it, and `HostLink` dials `wss://127.0.0.1:<port>/ws` — TLS + cert TOFU reuse unchanged. WS drop tears the tunnel down (the reconnecting wrapper does not close old links). SSH host-key fingerprints (`SHA256:<base64>`, case-sensitive) live in a separate `FingerprintStore` from the daemon cert pins.
- **`lib/state/`** — Riverpod providers: multi-host entries (`host_entry.dart`, `host_entries_v2` with legacy single-host auto-migration; SSH secrets in a dedicated secure-storage channel keyed by entry id, passphrase never persisted), pairing, session list, `chat_controller` + `transcript` (snapshot + live events merged idempotently by item id, matching the daemon's whole-item `item.updated` semantics).
- **`lib/notify/`** — `foreground_link.dart` runs `flutter_foreground_task` to hold the connection open with an honest persistent status notification; `app_notifier.dart` posts high-priority permission-request notifications and turn-finished alerts via `flutter_local_notifications` (tap deep-links into the session); `notification_policy.dart` is the pure decision layer (foreground suppression, running→idle edge detection, title cache) so triggers are unit-testable without plugins.
- **`lib/ui/`** — `pair_screen` / `session_list_screen` / `chat/` (screen + rows + composer) / `debug_events_screen` (raw event firehose, temporary) / `lifecycle_host.dart` — a dumb widget at the app root wiring it together: lifecycle → notification suppression, events → policy → notifications, notification taps → navigation, foreground-service start/stop, and the one-time skippable battery-optimization exemption prompt.
- **Android side** — manifest declares `FOREGROUND_SERVICE_DATA_SYNC` + `POST_NOTIFICATIONS`; `MainActivity.kt` exposes a MethodChannel to open the battery-optimization exemption settings; compileSdk 37 with core library desugaring (required by `flutter_local_notifications`).

## Conventions

- ESM with Node16 module resolution: relative imports in TS source must end in `.js` (e.g. `import { Store } from './store.js'`).
- Zod v4; anything that crosses the wire gets a schema in `protocol.ts`, and handlers validate params with `safeParse` before use.
- TypeScript is strict with `noUncheckedIndexedAccess`.
