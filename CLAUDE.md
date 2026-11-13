# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CC-Go lets an Android phone remotely control Claude Code running on the user's computer: the phone pairs with a daemon over TLS WebSocket, then creates/watches/prompts Claude Code sessions and answers permission requests from the chat UI. The SSH tunnel is planned for M4.

- `daemon/` — the PC side (Node.js/TypeScript): pairing, TLS, authenticated WebSocket, session management.
- `app/` — the Android client (Flutter, `dev.luke.cc_go`, minSdk 26): pairing, sessions, chat, permission UI, reconnect, and notification implementation. Background behavior still needs the device checks in `docs/VERIFICATION.md`.
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
node bin/cc-go.mjs [--port 8747] [--localhost] [--name <name>] [--code <code>] [--no-tls]
```

- All endpoints (HTTP + WebSocket) are served over **TLS by default** (`https`/`wss`): a self-signed ECDSA P-256 certificate is generated on first run into `~/.cc-go/tls-{cert,key}.pem` and reused. Startup prints its SHA-256 fingerprint next to the pairing code — clients pin it on first connection (TOFU) and fail closed if it changes.
- `--localhost` binds 127.0.0.1 (SSH-tunnel mode); default binds 0.0.0.0. `--no-tls` is a plaintext dev mode that forces loopback binding.
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
- **`src/agent/manager.ts`** — owns live sessions and fans events out to the server. Summaries are persisted on every change; after a daemon restart `ensureLive()` rehydrates a persisted session on demand — same id, Claude context survives via `resume: claudeSessionId`, but the phone's item history starts fresh with a notice (replaying `~/.claude/projects` JSONL is a later milestone).
- **`src/agent/session.ts`** — one Claude Code conversation via `@anthropic-ai/claude-agent-sdk` `query()`:
  - Prompts flow through a queue into `PushablePrompt` (a pushable async iterable passed as the SDK prompt stream). One `query()` spans multiple turns while work remains, then is recreated with `resume`. Claude's resume forks under a **new** session id, so the current id is re-tracked from every message frame (`trackClaudeSession`).
  - Send modes: `queue` (wait for the current turn) vs `interrupt` (abort, then send). `cancel` aborts and denies all pending permissions.
  - Permissions: `canUseTool` parks a Promise → `permission.request` event → phone answers via `permission.respond {itemId, allow, allowToolForSession}`.
  - Stream deltas build assistant items incrementally; the final `assistant` message replaces the draft wholesale. Own prompts echoed back by the SDK are dropped via a 90 s echo-guard map keyed by text.
  - Sets `CLAUDE_CODE_ENTRYPOINT=cc-go` so daemon sessions stay visible in `claude --resume`.
- **`src/store.ts`** — single `~/.cc-go/store.json` (atomic tmp+rename, mode 0600): daemon id/name, paired device tokens, session summaries.
- **`src/tls.ts`** — self-signed certificate lifecycle: generated on first run (`selfsigned`, ECDSA P-256), persisted in `~/.cc-go/`, reused across restarts; exposes the openssl-style SHA-256 fingerprint clients pin (TOFU).

## Conventions

- ESM with Node16 module resolution: relative imports in TS source must end in `.js` (e.g. `import { Store } from './store.js'`).
- Zod v4; anything that crosses the wire gets a schema in `protocol.ts`, and handlers validate params with `safeParse` before use.
- TypeScript is strict with `noUncheckedIndexedAccess`.
