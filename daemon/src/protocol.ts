/**
 * Wire protocol between the phone app and the CC-Go daemon.
 *
 * Transport: a single WebSocket carrying JSON frames.
 *  - Client → daemon: `{ id, method, params }` requests.
 *  - Daemon → client: `{ id, result | error }` responses, plus
 *    `{ type: "event", sessionId?, event }` pushes.
 *
 * Session content is modeled as a list of "items" (user / assistant / tool /
 * notice). The daemon owns the item list; the phone renders it and may
 * replace any item wholesale (`item.updated` carries the full item). This
 * keeps re-renders trivial and makes snapshot + live stream idempotent by
 * item id — the same merging trick dsh-go uses with seq-ordered durable
 * events, minus the server-side persistence.
 */

import { z } from 'zod'

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

export const PermissionMode = z.enum([
  'default',
  'acceptEdits',
  'plan',
  'bypassPermissions',
])
export type PermissionMode = z.infer<typeof PermissionMode>

export const SendMode = z.enum(['queue', 'interrupt'])
export type SendMode = z.infer<typeof SendMode>

// ---------------------------------------------------------------------------
// Transcript items (what the phone renders)
// ---------------------------------------------------------------------------

/** Image mime types the Messages API accepts as base64 image blocks. */
export const ImageMimeType = z.enum(['image/jpeg', 'image/png', 'image/gif', 'image/webp'])
export type ImageMimeType = z.infer<typeof ImageMimeType>

/** An image attachment travelling with a user message (compressed client-side). */
export const Attachment = z.object({
  name: z.string(),
  mimeType: ImageMimeType,
  dataBase64: z.string(),
})
export type Attachment = z.infer<typeof Attachment>

/** An image returned by a tool (e.g. Read on an image file), bounded. */
export const ToolResultImage = z.object({
  mimeType: z.string(),
  dataBase64: z.string(),
})
export type ToolResultImage = z.infer<typeof ToolResultImage>

export const UserItem = z.object({
  kind: z.literal('user'),
  id: z.string(),
  text: z.string(),
  /** How this message entered the conversation (for UI styling). */
  source: z.enum(['phone', 'daemon']).default('phone'),
  /** Images sent with this message, when any. */
  attachments: z.array(Attachment).optional(),
  createdAt: z.number(),
})
export type UserItem = z.infer<typeof UserItem>

export const AssistantItem = z.object({
  kind: z.literal('assistant'),
  id: z.string(),
  /** Streamed-so-far / final text. Replaced wholesale on updates. */
  text: z.string(),
  thinking: z.string().default(''),
  status: z.enum(['streaming', 'done']),
  createdAt: z.number(),
})
export type AssistantItem = z.infer<typeof AssistantItem>

export const ToolItem = z.object({
  kind: z.literal('tool'),
  id: z.string(),
  /** Claude's tool_use block id, when known (same as id). */
  claudeCallId: z.string().optional(),
  name: z.string(),
  /** Raw tool input (JSON object). */
  input: z.record(z.string(), z.unknown()).default({}),
  status: z.enum(['running', 'awaiting-permission', 'done', 'error', 'denied']),
  /** Short human-readable result summary, when available. */
  summary: z.string().optional(),
  /** Full result text (newlines preserved), truncated at the cap below. */
  resultText: z.string().optional(),
  /** True when resultText was cut at the cap. */
  resultTruncated: z.boolean().optional(),
  /** Images in the result, bounded (count and size). */
  resultImages: z.array(ToolResultImage).optional(),
  createdAt: z.number(),
})
export type ToolItem = z.infer<typeof ToolItem>

export const NoticeItem = z.object({
  kind: z.literal('notice'),
  id: z.string(),
  level: z.enum(['info', 'warn', 'error']),
  text: z.string(),
  createdAt: z.number(),
})
export type NoticeItem = z.infer<typeof NoticeItem>

export const Item = z.discriminatedUnion('kind', [
  UserItem,
  AssistantItem,
  ToolItem,
  NoticeItem,
])
export type Item = z.infer<typeof Item>

// ---------------------------------------------------------------------------
// Session descriptions (for the session list)
// ---------------------------------------------------------------------------

/** Token usage & cumulative cost of a session, from the latest turn's result. */
export const SessionUsage = z.object({
  inputTokens: z.number().int().nonnegative(),
  outputTokens: z.number().int().nonnegative(),
  cacheReadTokens: z.number().int().nonnegative(),
  cacheCreationTokens: z.number().int().nonnegative(),
  /** input + cache_read + cache_creation — the context the next turn re-sends. */
  contextTokens: z.number().int().nonnegative(),
  /** Cumulative session cost in USD, as reported by Claude Code. */
  costUsd: z.number(),
})
export type SessionUsage = z.infer<typeof SessionUsage>

export const SessionSummary = z.object({
  id: z.string(),
  title: z.string(),
  cwd: z.string(),
  /** Idle | running a turn | blocked on a permission request. */
  phase: z.enum(['idle', 'running', 'awaiting-permission']),
  createdAt: z.number(),
  updatedAt: z.number(),
  /** Claude Code's own session id, when a turn has started at least once. */
  claudeSessionId: z.string().nullable(),
  model: z.string().nullable(),
  permissionMode: PermissionMode,
  /** How this session came to exist: created by the phone/daemon or
   *  imported from an existing Claude Code session (history takeover). */
  origin: z.enum(['created', 'imported']).default('created'),
  /** The Claude session id this session was imported from, when imported.
   *  Claude's resume forks under ever-new ids, so this stays stable and
   *  keeps import idempotency and discovery's managed flag correct across
   *  forks. Null for created sessions. */
  originClaudeSessionId: z.string().nullable().default(null),
  /** Usage & cost once at least one turn has finished; absent before that. */
  usage: SessionUsage.optional(),
})
export type SessionSummary = z.infer<typeof SessionSummary>

// ---------------------------------------------------------------------------
// Server → client events
// ---------------------------------------------------------------------------

export const SessionEvent = z.discriminatedUnion('ev', [
  z.object({
    ev: z.literal('snapshot'),
    items: z.array(Item),
    phase: z.enum(['idle', 'running', 'awaiting-permission']),
    pendingPermission: z
      .object({ itemId: z.string(), name: z.string(), input: z.record(z.string(), z.unknown()) })
      .nullable(),
  }),
  z.object({ ev: z.literal('item.added'), item: Item }),
  z.object({ ev: z.literal('item.updated'), item: Item }),
  z.object({ ev: z.literal('phase'), phase: z.enum(['idle', 'running', 'awaiting-permission']) }),
  z.object({ ev: z.literal('summary'), summary: SessionSummary }),
])
export type SessionEvent = z.infer<typeof SessionEvent>

export const DaemonEvent = z.discriminatedUnion('type', [
  z.object({ type: z.literal('session'), sessionId: z.string(), event: SessionEvent }),
  z.object({ type: z.literal('sessions.changed') }),
  z.object({ type: z.literal('permission.request'), sessionId: z.string(), itemId: z.string(), name: z.string() }),
])
export type DaemonEvent = z.infer<typeof DaemonEvent>

// ---------------------------------------------------------------------------
// Requests (method + params) and responses
// ---------------------------------------------------------------------------

export const ClientRequest = z.object({
  id: z.string(),
  method: z.string(),
  params: z.record(z.string(), z.unknown()).default({}),
})
export type ClientRequest = z.infer<typeof ClientRequest>

export const ServerResponse = z.object({
  id: z.string(),
  ok: z.literal(true),
  result: z.unknown(),
})
export type ServerResponse = z.infer<typeof ServerResponse>

export const ServerError = z.object({
  id: z.string(),
  ok: z.literal(false),
  error: z.object({ code: z.string(), message: z.string() }),
})

export const HostInfo = z.object({
  name: z.string(),
  version: z.string(),
  daemonId: z.string(),
  /** Directory the daemon was started in (default cwd for new sessions). */
  defaultCwd: z.string(),
  claudeVersion: z.string().nullable(),
})
export type HostInfo = z.infer<typeof HostInfo>

// ---- Typed params / results per method ------------------------------------

export const PairRequest = z.object({ code: z.string() })
export const PairResult = z.object({ token: z.string(), deviceId: z.string(), host: HostInfo })

export const HelloParams = z.object({ token: z.string(), deviceName: z.string().default('phone') })
export const HelloResult = z.object({ host: HostInfo })

export const SessionCreateParams = z.object({
  cwd: z.string().optional(),
  title: z.string().optional(),
  model: z.string().optional(),
  permissionMode: PermissionMode.optional(),
})
export type SessionCreateParams = z.infer<typeof SessionCreateParams>

export const SessionPromptParams = z.object({
  sessionId: z.string(),
  text: z.string().min(1),
  mode: SendMode.default('queue'),
  attachments: z.array(Attachment).max(4).optional(),
})

export const SessionConfigureParams = z.object({
  sessionId: z.string(),
  model: z.string().nullable().optional(),
  permissionMode: PermissionMode.optional(),
  title: z.string().optional(),
})

export const PermissionRespondParams = z.object({
  sessionId: z.string(),
  itemId: z.string(),
  allow: z.boolean(),
  /** Remember this tool name for the rest of the session. */
  allowToolForSession: z.boolean().default(false),
})

// ---- Projects & session history (multi-project-history) --------------------

export const ProjectInfo = z.object({
  /** Canonical absolute path (realpath-resolved when it exists). */
  path: z.string(),
  /** Display name — directory basename. */
  name: z.string(),
  /** False when the directory no longer exists on disk. */
  available: z.boolean(),
  /** Number of cc-go sessions whose cwd is this project. */
  sessionCount: z.number().int().nonnegative(),
})
export type ProjectInfo = z.infer<typeof ProjectInfo>

export const ProjectsListResult = z.object({ projects: z.array(ProjectInfo) })
export type ProjectsListResult = z.infer<typeof ProjectsListResult>

export const ProjectsRegisterParams = z.object({ path: z.string().min(1) })
export const ProjectsRegisterResult = z.object({ project: ProjectInfo })

export const DiscoveredSession = z.object({
  /** Claude Code's own session id (the .jsonl filename stem). */
  claudeSessionId: z.string(),
  /** First user message (truncated), falling back to a time-based title. */
  title: z.string(),
  lastActiveAt: z.number(),
  messageCount: z.number().int().nonnegative(),
  /** True when a cc-go session already tracks this Claude session. */
  managed: z.boolean(),
  /** cc-go session id when managed, else null. */
  ccGoSessionId: z.string().nullable().default(null),
})
export type DiscoveredSession = z.infer<typeof DiscoveredSession>

export const SessionsDiscoverParams = z.object({ cwd: z.string().min(1) })
export const SessionsDiscoverResult = z.object({ sessions: z.array(DiscoveredSession) })
export type SessionsDiscoverResult = z.infer<typeof SessionsDiscoverResult>

export const SessionHistoryParams = z.object({
  claudeSessionId: z.string().min(1),
  cwd: z.string().min(1),
  /** 1-based source line number; the page returns items from lines before it. */
  beforeLine: z.number().int().positive().optional(),
  limit: z.number().int().positive().max(500).default(100),
})
export type SessionHistoryParams = z.infer<typeof SessionHistoryParams>

export const SessionHistoryResult = z.object({
  /** Chronological order within the page. */
  items: z.array(Item),
  /** Cursor for the next (older) page; null when history is exhausted. */
  nextBeforeLine: z.number().int().nullable(),
})
export type SessionHistoryResult = z.infer<typeof SessionHistoryResult>

export const SessionImportParams = z.object({
  claudeSessionId: z.string().min(1),
  cwd: z.string().min(1),
  title: z.string().optional(),
})
export const SessionImportResult = z.object({ summary: SessionSummary })

// ---- Models & slash commands (transcript-data-protocol) ---------------------

export const ModelInfoDto = z.object({
  /** Model identifier to pass back via session.configure. */
  id: z.string(),
  displayName: z.string(),
})
export type ModelInfoDto = z.infer<typeof ModelInfoDto>

export const HostModelsResult = z.object({
  models: z.array(ModelInfoDto),
  /** Current model when known (any live/recent session), else null. */
  current: z.string().nullable(),
})
export type HostModelsResult = z.infer<typeof HostModelsResult>

export const SessionCommandsParams = z.object({ sessionId: z.string() })
export const SessionCommandsResult = z.object({
  /** Slash command names without the leading slash, terminal-bound ones filtered. */
  commands: z.array(z.object({ name: z.string(), description: z.string().optional() })),
})
export type SessionCommandsResult = z.infer<typeof SessionCommandsResult>

/** Error codes used across the wire. */
export const ErrorCodes = {
  UNAUTHORIZED: 'unauthorized',
  PAIRING_FAILED: 'pairing_failed',
  NOT_FOUND: 'not_found',
  BAD_REQUEST: 'bad_request',
  BUSY: 'busy',
  INTERNAL: 'internal',
} as const
