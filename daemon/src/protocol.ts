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

export const UserItem = z.object({
  kind: z.literal('user'),
  id: z.string(),
  text: z.string(),
  /** How this message entered the conversation (for UI styling). */
  source: z.enum(['phone', 'daemon']).default('phone'),
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
  attachments: z.array(z.object({ name: z.string(), mimeType: z.string(), dataBase64: z.string() })).optional(),
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

/** Error codes used across the wire. */
export const ErrorCodes = {
  UNAUTHORIZED: 'unauthorized',
  PAIRING_FAILED: 'pairing_failed',
  NOT_FOUND: 'not_found',
  BAD_REQUEST: 'bad_request',
  BUSY: 'busy',
  INTERNAL: 'internal',
} as const
