/**
 * Session — one Claude Code conversation driven through the official
 * @anthropic-ai/claude-agent-sdk.
 *
 * Pattern follows happy-cli's claudeRemote + Session split:
 *  - a prompt queue feeds a pushable async iterable (the SDK's `prompt`),
 *  - one `query()` lives across turns while there is work, then ends and is
 *    recreated with `resume: <claudeSessionId>` on the next prompt or after
 *    an interrupt (Claude's --resume copies history under a NEW session id —
 *    we track the current id from every message frame),
 *  - `canUseTool` gates tool calls behind a pending Promise that the phone
 *    resolves via `permission.respond`,
 *  - everything the phone renders is a list of Items; every mutation is
 *    emitted wholesale so snapshot + live stream stay idempotent.
 */

import { randomUUID } from 'node:crypto'
import { closeSync, fstatSync, openSync, readSync, statSync } from 'node:fs'
import {
  query,
  type CanUseTool,
  type Options,
  type PermissionResult,
  type SDKMessage,
  type SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk'
import type {
  AssistantItem,
  DaemonEvent,
  Item,
  PermissionMode,
  SendMode,
  SessionEvent,
  SessionSummary,
  ToolItem,
  UserItem,
} from '../protocol.js'
import {
  TranscriptMapper,
  newestTranscriptIn,
  summarizeToolContent,
  transcriptPath,
  transcriptSharesLineage,
} from '../history.js'

// ---------------------------------------------------------------------------
// Minimal pushable async iterable feeding the SDK prompt stream
// ---------------------------------------------------------------------------

class PushablePrompt {
  private buffered: SDKUserMessage[] = []
  private waiter: ((r: IteratorResult<SDKUserMessage>) => void) | null = null
  private closed = false

  push(message: SDKUserMessage): void {
    if (this.closed) return
    if (this.waiter) {
      const w = this.waiter
      this.waiter = null
      w({ value: message, done: false })
    } else {
      this.buffered.push(message)
    }
  }

  close(): void {
    this.closed = true
    if (this.waiter) {
      const w = this.waiter
      this.waiter = null
      w({ value: undefined, done: true })
    }
  }

  isClosed(): boolean {
    return this.closed
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    return {
      next: (): Promise<IteratorResult<SDKUserMessage>> =>
        new Promise((resolve) => {
          const next = this.buffered.shift()
          if (next !== undefined || this.closed) {
            resolve(next !== undefined ? { value: next, done: false } : { value: undefined, done: true })
          } else {
            this.waiter = resolve
          }
        }),
    }
  }
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

export interface SessionCallbacks {
  /** Called for every transcript mutation / phase change. */
  onEvent(event: DaemonEvent): void
  /** Persisted whenever the summary-relevant state changes. */
  onSummary(): void
}

interface QueuedPrompt {
  text: string
}

interface PendingPermission {
  resolve: (result: PermissionResult) => void
  itemId: string
}

const ECHO_GUARD_MS = 90_000

// History tail (multi-project-history D6): poll cadence and the windows used
// to drop our own writes echoed back through the transcript file.
const TAIL_POLL_MS = 3_000
const TAIL_USER_ECHO_MS = 90_000
const TAIL_ASSISTANT_DUP_MS = 10 * 60_000

export class Session {
  readonly id: string
  title: string
  cwd: string
  model: string | null
  permissionMode: PermissionMode
  claudeSessionId: string | null = null
  /** How this session came to exist (list badge on the phone). */
  origin: 'created' | 'imported' = 'created'
  /** Stable "imported from" Claude session id — survives forks, so import
   *  idempotency and discovery's managed flag stay correct after resume
   *  rewrites claudeSessionId. */
  originClaudeSessionId: string | null = null
  createdAt = Date.now()
  updatedAt = Date.now()

  private callbacks: SessionCallbacks
  private items: Item[] = []
  private phase: 'idle' | 'running' | 'awaiting-permission' = 'idle'
  private queue: QueuedPrompt[] = []
  private allowedForSession = new Set<string>()
  private deniedForSession = new Set<string>()

  private loopActive = false
  private currentPushable: PushablePrompt | null = null
  private currentAbort: AbortController | null = null
  private pendingPermissions = new Map<string, PendingPermission>()
  private echoGuard = new Map<string, number>()
  private disposed = false
  /** text/thinking blocks currently streaming, keyed by content-block index. */
  private blockKinds = new Map<number, 'text' | 'thinking' | 'tool_use'>()
  private currentAssistant: AssistantItem | null = null

  // ---- history tail state (D6) ----------------------------------------------
  private tailTimer: NodeJS.Timeout | null = null
  private tailMapper: TranscriptMapper | null = null
  private tailSid: string | null = null
  private tailOffset = 0
  private tailLastSize = -1
  /** uuid/callId tails of transcript items already shown (fork dedupe). */
  private tailKnown = new Set<string>()

  constructor(
    callbacks: SessionCallbacks,
    opts: {
      id?: string
      cwd: string
      title?: string
      model?: string
      permissionMode?: PermissionMode
      origin?: 'created' | 'imported'
    },
  ) {
    this.callbacks = callbacks
    this.id = opts.id ?? randomUUID()
    this.cwd = opts.cwd
    this.title = opts.title ?? 'New session'
    this.model = opts.model ?? null
    this.permissionMode = opts.permissionMode ?? 'default'
    this.origin = opts.origin ?? 'created'
  }

  /**
   * Mark a rehydrated session: Claude's transcript survives via
   * `claudeSessionId`, but the phone's item history starts with this notice.
   */
  adoptColdStart(notice: string): void {
    this.addNotice('info', notice)
  }

  /**
   * Prefill the transcript with replayed history items (session.import, and
   * rehydrating an imported session after a daemon restart). Item ids keep
   * the mapper's `hist-<claudeSessionId>-*` form so they cannot collide with
   * live item ids; item.added events fire so a connection that already
   * watched (rehydrate case) receives them — snapshot merges stay idempotent.
   */
  seedHistoryItems(items: Item[]): void {
    for (const item of items) {
      this.items.push(item)
      this.emitSessionEvent({ ev: 'item.added', item })
    }
    if (items.length > 0) {
      this.updatedAt = Date.now()
      this.emitSessionEvent({ ev: 'summary', summary: this.summary() })
    }
  }

  // ---- history tail: external writes to this session's transcript --------

  /**
   * Watch Claude's transcript file for writes this session did not make —
   * e.g. the user resuming the same conversation in a terminal — and merge
   * the new items into the phone's transcript (multi-project-history D6).
   * Enabled only for imported sessions. Starts from offset 0 and relies on
   * uuid/callId dedupe, so it is safe against replays and forked copies.
   */
  startHistoryTail(): void {
    if (this.tailTimer || this.disposed || !this.claudeSessionId) return
    for (const item of this.items) {
      const key = tailKeyOf(item)
      if (key !== null) this.tailKnown.add(key)
    }
    this.tailSid = this.claudeSessionId
    this.tailMapper = new TranscriptMapper(this.claudeSessionId)
    void this.tailPoll()
    this.tailTimer = setInterval(() => void this.tailPoll(), TAIL_POLL_MS)
    this.tailTimer.unref()
  }

  private stopHistoryTail(): void {
    if (this.tailTimer) {
      clearInterval(this.tailTimer)
      this.tailTimer = null
    }
  }

  private tailPoll(): void {
    if (this.disposed) return
    try {
      const sid = this.claudeSessionId
      if (!sid || !this.tailMapper) return

      // The conversation moved to a different session id — either our own
      // SDK resume forking, or a lineage-confirmed terminal fork adopted
      // below. Re-sync from the new file's start; uuid dedupe absorbs the
      // copied history, and only genuinely new lines surface.
      if (sid !== this.tailSid) {
        this.tailSid = sid
        this.tailOffset = 0
        this.tailLastSize = -1
        this.tailMapper = new TranscriptMapper(sid)
      }

      const file = transcriptPath(sid, this.cwd)

      // A terminal `--resume` forks under a NEW id while our file goes
      // quiet. Follow the newest transcript ONLY if it shares lineage with
      // what we already show — an unrelated conversation in the same project
      // must never hijack this session's identity.
      if (this.tailLastSize >= 0) {
        const current = statOrNull(file)
        if (current && current.size === this.tailLastSize) {
          const newest = newestTranscriptIn(this.cwd)
          if (
            newest &&
            newest.claudeSessionId !== sid &&
            newest.mtimeMs > current.mtimeMs &&
            transcriptSharesLineage(newest.file, this.tailKnown)
          ) {
            this.trackClaudeSession(newest.claudeSessionId) // next poll re-syncs
          }
        }
      }

      // Incremental read from tailOffset — never the whole file per poll.
      const fd = openSync(file, 'r')
      let size = 0
      let chunk = ''
      try {
        size = fstatSync(fd).size
        if (size < this.tailOffset) {
          // truncated/rewritten: re-sync from the start
          this.tailOffset = 0
          this.tailMapper = new TranscriptMapper(sid)
        }
        if (size > this.tailOffset) {
          const buf = Buffer.alloc(size - this.tailOffset)
          readSync(fd, buf, 0, buf.length, this.tailOffset)
          chunk = buf.toString('utf8')
        }
      } finally {
        closeSync(fd)
      }
      this.tailLastSize = size
      if (chunk === '') return

      const lastNewline = chunk.lastIndexOf('\n')
      if (lastNewline === -1) return // no complete line yet — wait for more
      const complete = chunk.slice(0, lastNewline + 1)
      this.tailOffset += Buffer.byteLength(complete, 'utf8')

      let merged = 0
      for (const line of complete.split('\n')) {
        for (const item of this.tailMapper.processLine(line)) {
          if (this.mergeTailedItem(item)) merged++
        }
      }
      // Persist the refreshed summary + notify list watchers once per batch
      // (per-item onSummary would spam the store and sessions.changed).
      if (merged > 0) this.callbacks.onSummary()
    } catch {
      // file gone or unreadable — the next poll retries
    }
  }

  /** @returns true when the item was shown to watchers. */
  private mergeTailedItem(item: Item): boolean {
    const key = tailKeyOf(item)
    if (key === null) return false
    if (this.tailKnown.has(key)) return false
    this.tailKnown.add(key)
    if (this.isTailEcho(item)) return false
    this.items.push(item)
    this.emitSessionEvent({ ev: 'item.added', item })
    this.touch()
    return true
  }

  /** Drop items that merely echo what already happened through this daemon
   *  (phone prompts echoed into the file; SDK-streamed assistant replies). */
  private isTailEcho(item: Item): boolean {
    if (item.kind === 'user') {
      return this.items.some(
        (i) =>
          i.kind === 'user' &&
          i.text === item.text &&
          item.createdAt - i.createdAt >= -5_000 &&
          item.createdAt - i.createdAt < TAIL_USER_ECHO_MS,
      )
    }
    if (item.kind === 'assistant') {
      return this.items.some(
        (i) =>
          i.kind === 'assistant' &&
          i.text === item.text &&
          Math.abs(item.createdAt - i.createdAt) < TAIL_ASSISTANT_DUP_MS,
      )
    }
    if (item.kind === 'tool') {
      return item.claudeCallId !== undefined &&
        this.items.some((i) => i.kind === 'tool' && i.claudeCallId === item.claudeCallId)
    }
    return false
  }

  // ---- public API ----------------------------------------------------------

  get currentPhase(): 'idle' | 'running' | 'awaiting-permission' {
    return this.phase
  }

  summary(): SessionSummary {
    return {
      id: this.id,
      title: this.title,
      cwd: this.cwd,
      phase: this.phase,
      createdAt: this.createdAt,
      updatedAt: this.updatedAt,
      claudeSessionId: this.claudeSessionId,
      model: this.model,
      permissionMode: this.permissionMode,
      origin: this.origin,
      originClaudeSessionId: this.originClaudeSessionId,
    }
  }

  snapshot(): SessionEvent {
    const pending = [...this.pendingPermissions.values()][0]
    let pendingPermission: Extract<SessionEvent, { ev: 'snapshot' }>['pendingPermission'] = null
    if (pending) {
      const item = this.findItem(pending.itemId)
      if (item && item.kind === 'tool') {
        pendingPermission = { itemId: item.id, name: item.name, input: item.input }
      }
    }
    return { ev: 'snapshot', items: structuredClone(this.items), phase: this.phase, pendingPermission }
  }

  configure(opts: { model?: string | null; permissionMode?: PermissionMode; title?: string }): void {
    if (opts.model !== undefined) this.model = opts.model
    if (opts.permissionMode !== undefined) this.permissionMode = opts.permissionMode
    if (opts.title !== undefined) this.title = opts.title
    this.touch()
    this.callbacks.onSummary()
    this.emitSessionEvent({ ev: 'summary', summary: this.summary() })
  }

  /** Send a user message. `queue` waits for the current turn; `interrupt`
   *  aborts it first. */
  prompt(text: string, mode: SendMode): void {
    this.addUserItem(text, 'phone')
    if (this.title === 'New session') {
      this.title = text.slice(0, 48).replace(/\s+/g, ' ').trim() || 'New session'
      this.callbacks.onSummary()
    }
    if (mode === 'interrupt' && this.phase === 'running') {
      this.queue.push({ text })
      this.currentAbort?.abort()
      return
    }
    if (this.loopActive && this.currentPushable && !this.currentPushable.isClosed()) {
      // A query() is alive, parked on pushable.next() between turns: hand the
      // prompt straight to it with priority "next" so the SDK runs it after
      // the current turn. (Routing it through this.queue would deadlock —
      // the queue is only drained between queries.)
      this.currentPushable.push(userMessage(text, 'next'))
      this.echoGuard.set(text, Date.now())
      return
    }
    this.queue.push({ text })
    void this.pump()
  }

  /** Interrupt the current turn (phone stop button). */
  cancel(): void {
    if (this.phase === 'running' || this.phase === 'awaiting-permission') {
      this.denyAllPermissions('Session interrupted')
      this.currentAbort?.abort()
    }
  }

  /** Resolve a permission request from the phone. */
  respondPermission(itemId: string, allow: boolean, allowToolForSession: boolean): void {
    const pending = this.pendingPermissions.get(itemId)
    if (!pending) return
    this.pendingPermissions.delete(itemId)
    const item = this.findItem(itemId)
    if (item && item.kind === 'tool') {
      item.status = allow ? 'running' : 'denied'
      this.updateItem(item)
    }
    if (allowToolForSession && item && item.kind === 'tool') {
      if (allow) this.allowedForSession.add(item.name)
      else this.deniedForSession.add(item.name)
    }
    pending.resolve(
      allow
        ? { behavior: 'allow' }
        : { behavior: 'deny', message: 'Denied from phone' },
    )
    if (this.pendingPermissions.size === 0 && this.phase === 'awaiting-permission') {
      this.setPhase('running')
    }
  }

  dispose(): void {
    this.disposed = true
    this.stopHistoryTail()
    this.denyAllPermissions('Session closed')
    this.currentAbort?.abort()
    this.currentPushable?.close()
  }

  // ---- query loop ----------------------------------------------------------

  private async pump(): Promise<void> {
    if (this.loopActive || this.disposed) return
    if (this.queue.length === 0) {
      this.setPhase('idle')
      return
    }
    this.loopActive = true
    try {
      while (!this.disposed && this.queue.length > 0) {
        await this.runOneQuery()
      }
    } finally {
      this.loopActive = false
      if (!this.disposed) this.setPhase('idle')
    }
  }

  /** One query() lifetime — may span several turns while prompts keep coming. */
  private async runOneQuery(): Promise<void> {
    const pushable = new PushablePrompt()
    const abort = new AbortController()
    this.currentPushable = pushable
    this.currentAbort = abort
    this.setPhase('running')

    const options: Options = {
      cwd: this.cwd,
      resume: this.claudeSessionId ?? undefined,
      model: this.model ?? undefined,
      permissionMode: this.permissionMode,
      includePartialMessages: true,
      abortController: abort,
      canUseTool: this.canUseTool,
      env: envWithEntrypoint(),
    }

    const first = this.queue.shift()
    if (!first) return
    pushable.push(userMessage(first.text))
    this.echoGuard.set(first.text, Date.now())

    try {
      const q = query({ prompt: pushable, options })
      for await (const message of q) {
        this.handleMessage(message)
      }
    } catch (err) {
      if (!abort.signal.aborted) {
        this.addNotice('error', `Query failed: ${errorMessage(err)}`)
      }
    } finally {
      this.currentPushable = null
      this.currentAbort = null
    }
  }

  private canUseTool: CanUseTool = async (toolName, input, opts): Promise<PermissionResult | null> => {
    if (this.disposed) return { behavior: 'deny', message: 'Session closed' }
    if (this.permissionMode === 'bypassPermissions' || this.allowedForSession.has(toolName)) {
      return { behavior: 'allow' }
    }
    if (this.deniedForSession.has(toolName)) {
      // canUseTool can fire before the assistant message lands the item —
      // create it if absent so the transcript still shows the denial.
      let deniedItem = this.items.find(
        (it): it is ToolItem =>
          it.kind === 'tool' && it.status === 'running' && it.name === toolName,
      )
      if (!deniedItem) deniedItem = this.addToolItem(toolName, input)
      deniedItem.status = 'denied'
      deniedItem.summary = '本会话已拒绝此类工具'
      this.updateItem(deniedItem)
      return { behavior: 'deny', message: 'Denied for this session from phone' }
    }
    // Find the tool item created from the assistant tool_use block; fall back
    // to a placeholder when the block has not streamed yet.
    let item = this.items.find(
      (it): it is ToolItem => it.kind === 'tool' && it.status === 'running' && it.name === toolName,
    )
    if (!item) {
      item = this.addToolItem(toolName, input)
    }
    item.status = 'awaiting-permission'
    this.updateItem(item)
    this.setPhase('awaiting-permission')

    return await new Promise<PermissionResult>((resolve) => {
      this.pendingPermissions.set(item!.id, { resolve, itemId: item!.id })
      this.callbacks.onEvent({
        type: 'permission.request',
        sessionId: this.id,
        itemId: item!.id,
        name: toolName,
      })
      opts.signal.addEventListener('abort', () => {
        const pending = this.pendingPermissions.get(item!.id)
        if (pending) {
          this.pendingPermissions.delete(item!.id)
          resolve({ behavior: 'deny', message: 'Cancelled' })
        }
      }, { once: true })
    })
  }

  // ---- SDK message handling --------------------------------------------------

  private handleMessage(message: SDKMessage): void {
    switch (message.type) {
      case 'system':
        if (message.subtype === 'init') {
          this.trackClaudeSession(message.session_id)
        }
        break
      case 'stream_event':
        this.handleStreamEvent(message)
        break
      case 'assistant':
        this.handleAssistant(message)
        break
      case 'user':
        this.handleUserEcho(message)
        break
      case 'result':
        this.handleResult(message)
        break
      default:
        break // informational messages are ignored in v1
    }
  }

  private handleStreamEvent(message: Extract<SDKMessage, { type: 'stream_event' }>): void {
    if (message.parent_tool_use_id !== null) return // subagent stream — v1 skips
    const event = message.event
    switch (event.type) {
      case 'message_start':
        this.blockKinds.clear()
        break
      case 'content_block_start':
        this.blockKinds.set(event.index, event.content_block.type as 'text' | 'thinking' | 'tool_use')
        if (event.content_block.type === 'text' && !this.currentAssistant) {
          this.currentAssistant = this.addAssistantItem()
        }
        break
      case 'content_block_delta': {
        const kind = this.blockKinds.get(event.index)
        if (event.delta.type === 'text_delta' && kind === 'text') {
          const item = this.ensureAssistant()
          item.text += event.delta.text
          this.updateItem(item)
        } else if (event.delta.type === 'thinking_delta' && kind === 'thinking') {
          const item = this.ensureAssistant()
          item.thinking += event.delta.thinking
        }
        break
      }
      case 'message_stop':
        this.currentAssistant = null
        break
      default:
        break
    }
  }

  private handleAssistant(message: Extract<SDKMessage, { type: 'assistant' }>): void {
    if (message.parent_tool_use_id !== null) return // subagent output — v1 skips
    this.trackClaudeSession(message.session_id)
    const blocks = message.message.content
    const texts: string[] = []
    const thinking: string[] = []
    if (!Array.isArray(blocks)) return
    for (const block of blocks) {
      if (block.type === 'text') texts.push(block.text)
      else if (block.type === 'thinking') thinking.push(block.thinking)
      else if (block.type === 'tool_use') this.addToolItem(block.name, block.input as Record<string, unknown>, block.id)
    }
    if (texts.length > 0 || thinking.length > 0) {
      // Replace the streamed draft with the complete message (handles edits).
      const existing = this.currentAssistant
      const item = existing ?? this.addAssistantItem()
      item.text = texts.join('\n\n')
      item.thinking = thinking.join('\n\n')
      item.status = 'done'
      this.updateItem(item)
      this.currentAssistant = null
    }
    if (this.phase === 'idle') this.setPhase('running')
  }

  private handleUserEcho(message: Extract<SDKMessage, { type: 'user' }>): void {
    // Tool results for TOP-LEVEL tool calls arrive in user messages whose
    // parent_tool_use_id is null (non-null marks subagent frames) — handle
    // them before the echo branch, which would otherwise drop them.
    const content = message.message.content
    if (message.parent_tool_use_id === null && Array.isArray(content)) {
      let sawToolResult = false
      for (const block of content) {
        if (block.type !== 'tool_result') continue
        sawToolResult = true
        const toolUseId = block.tool_use_id
        const item = this.items.find(
          (it): it is ToolItem => it.kind === 'tool' && it.claudeCallId === toolUseId,
        )
        if (!item) continue
        if (item.status === 'denied') continue // phone's denial is the final word
        item.status = block.is_error ? 'error' : 'done'
        item.summary = summarizeToolContent(block.content, 400)
        this.updateItem(item)
      }
      if (sawToolResult) return
    }
    if (message.parent_tool_use_id !== null) return // subagent output — skip
    // Our own prompt echoed back — drop if it matches something we just sent.
    const text = userMessageText(message)
    if (text !== null && this.consumeEcho(text)) return
    if (text !== null && !message.isSynthetic) this.addUserItem(text, 'phone')
  }

  private handleResult(message: Extract<SDKMessage, { type: 'result' }>): void {
    if (message.subtype !== 'success' && !this.currentAbort?.signal.aborted) {
      const detail = 'result' in message && typeof message.result === 'string' ? message.result : message.subtype
      this.addNotice('error', `Turn failed: ${detail}`)
    }
    // A turn finished and no work remains: end the query so pump() returns
    // the session to idle (and the next prompt starts a fresh resume).
    // Without this the for-await parks on pushable.next() forever and the
    // session never leaves phase=running after a natural turn end.
    if (this.queue.length === 0 && this.pendingPermissions.size === 0) {
      this.currentPushable?.close()
    }
    this.touch()
    this.callbacks.onSummary()
  }

  // ---- item helpers ---------------------------------------------------------

  private ensureAssistant(): AssistantItem {
    if (this.currentAssistant) return this.currentAssistant
    const created = this.addAssistantItem()
    this.currentAssistant = created
    return created
  }

  private addAssistantItem(): AssistantItem {
    const item: AssistantItem = {
      kind: 'assistant',
      id: randomUUID(),
      text: '',
      thinking: '',
      status: 'streaming',
      createdAt: Date.now(),
    }
    this.addItem(item)
    return item
  }

  private addUserItem(text: string, source: UserItem['source']): void {
    const item: UserItem = { kind: 'user', id: randomUUID(), text, source, createdAt: Date.now() }
    this.addItem(item)
  }

  private addToolItem(name: string, input: Record<string, unknown>, claudeCallId?: string): ToolItem {
    const item: ToolItem = {
      kind: 'tool',
      id: claudeCallId ?? randomUUID(),
      claudeCallId,
      name,
      input,
      status: 'running',
      createdAt: Date.now(),
    }
    this.addItem(item)
    return item
  }

  private addNotice(level: 'info' | 'warn' | 'error', text: string): void {
    this.addItem({ kind: 'notice', id: randomUUID(), level, text, createdAt: Date.now() })
  }

  private addItem(item: Item): void {
    this.items.push(item)
    this.touch()
    this.callbacks.onEvent(this.sessionEvent({ ev: 'item.added', item: structuredClone(item) }))
  }

  private updateItem(item: Item): void {
    const idx = this.items.findIndex((it) => it.id === item.id)
    if (idx < 0) return
    this.items[idx] = structuredClone(item)
    this.touch()
    this.callbacks.onEvent(this.sessionEvent({ ev: 'item.updated', item: structuredClone(item) }))
  }

  private findItem(id: string): Item | undefined {
    return this.items.find((it) => it.id === id)
  }

  private sessionEvent(event: SessionEvent): DaemonEvent {
    return { type: 'session', sessionId: this.id, event }
  }

  private emitSessionEvent(event: SessionEvent): void {
    this.callbacks.onEvent(this.sessionEvent(event))
  }

  private setPhase(phase: 'idle' | 'running' | 'awaiting-permission'): void {
    if (this.phase === phase) return
    this.phase = phase
    this.callbacks.onEvent(this.sessionEvent({ ev: 'phase', phase }))
  }

  private touch(): void {
    this.updatedAt = Date.now()
  }

  private trackClaudeSession(sessionId: string | null | undefined): void {
    if (!sessionId || sessionId === this.claudeSessionId) return
    this.claudeSessionId = sessionId
    this.callbacks.onSummary()
  }

  private consumeEcho(text: string): boolean {
    const sentAt = this.echoGuard.get(text)
    if (sentAt !== undefined && Date.now() - sentAt < ECHO_GUARD_MS) {
      this.echoGuard.delete(text)
      return true
    }
    return false
  }

  private denyAllPermissions(reason: string): void {
    for (const [id, pending] of this.pendingPermissions) {
      this.pendingPermissions.delete(id)
      const item = this.findItem(pending.itemId)
      if (item && item.kind === 'tool') {
        item.status = 'denied'
        this.updateItem(item)
      }
      pending.resolve({ behavior: 'deny', message: reason })
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function userMessage(text: string, priority?: 'now' | 'next' | 'later'): SDKUserMessage {
  const message: SDKUserMessage = {
    type: 'user',
    message: { role: 'user', content: text },
    parent_tool_use_id: null,
  }
  if (priority) message.priority = priority
  return message
}

function userMessageText(message: Extract<SDKMessage, { type: 'user' }>): string | null {
  const content = message.message.content
  if (typeof content === 'string') return content
  if (Array.isArray(content) && content.every((b) => b.type === 'text')) {
    return content.map((b) => String((b as { text?: unknown }).text ?? '')).join('\n')
  }
  return null
}

// Tool-result summaries come from the shared summarizeToolContent in
// history.ts so live rows and replayed rows clip identically.


function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message
  return String(err)
}

function statOrNull(file: string): { size: number; mtimeMs: number } | null {
  try {
    return statSync(file)
  } catch {
    return null
  }
}
/** Dedupe key for transcript-derived items: the uuid (user/assistant) or
 *  tool-call id after the `hist-<sessionId>-` prefix. Stable across forks —
 *  a forked copy of the transcript keeps the same line uuids, so replayed
 *  history collapses onto what the phone already has. */
function tailKeyOf(item: Item): string | null {
  const m = /^hist-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-(.+)$/i.exec(item.id)
  if (m === null) return null
  return item.kind === 'tool' && item.claudeCallId ? `tool:${item.claudeCallId}` : `${item.kind}:${m[1]}`
}

/** Tag the spawned Claude so its sessions stay visible in `claude --resume`. */
function envWithEntrypoint(): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(process.env)) {
    if (typeof value === 'string') env[key] = value
  }
  env.CLAUDE_CODE_ENTRYPOINT = env.CLAUDE_CODE_ENTRYPOINT || 'cc-go'
  return env
}
