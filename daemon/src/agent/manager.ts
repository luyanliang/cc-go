/**
 * SessionManager — owns the live Sessions, persists their summaries, and
 * fans session events out to subscribed connections.
 *
 * After a daemon restart, persisted summaries come back as "cold" sessions:
 * Claude's own transcript still exists on disk, so the conversation can be
 * resumed by id, but the item history shown on the phone starts fresh with a
 * notice. (Replaying ~/.claude/projects JSONL into items is a later
 * milestone — happy-cli's sessionScanner is the reference.)
 */

import { randomUUID } from 'node:crypto'
import type { DaemonEvent, HostModelsResult, ModelInfoDto, PermissionMode, SessionSummary } from '../protocol.js'
import type { Store } from '../store.js'
import { collectHistory, titleFromHistory } from '../history.js'
import { Session, type SessionCallbacks } from './session.js'

export class SessionManager {
  private sessions = new Map<string, Session>()
  private listeners = new Set<(event: DaemonEvent) => void>()
  /** Host-level model catalog from the most recent session init (D4); null
   *  until any query has initialized on a CLI that supports supportedModels(). */
  private modelsCache: { models: ModelInfoDto[]; current: string | null } | null = null
  /** Probe-session factory (host.models cold path); injectable for tests. */
  probeSessionFactory: (cwd: string) => Session = (cwd) =>
    new Session(
      {
        onEvent: () => {},
        onSummary: () => {},
        onModels: (models, current) => this.noteModels(models, current),
      },
      { cwd, title: 'model-probe' },
    )

  /** 空目录不缓存：保持"未确认支持"，让后续请求仍能走探测。 */
  private noteModels(models: ModelInfoDto[], current: string | null): void {
    if (models.length === 0) return
    this.modelsCache = { models, current }
  }

  constructor(private readonly store: Store) {}

  /** Latest host-level model catalog, when known. */
  get models(): { models: ModelInfoDto[]; current: string | null } | null {
    return this.modelsCache
  }

  /**
   * host.models 的三级降级链（D4）：init 缓存 → 活查询直取（限时）→
   * 短命探测 → 空目录（旧 CLI）。空目录不进缓存——避免旧 CLI 的一次
   * 空回调把目录永久钉死，升级后仍可经探测恢复。探测会话不进会话列表。
   */
  async hostModels(): Promise<HostModelsResult> {
    if (this.modelsCache) return this.modelsCache
    for (const session of this.sessions.values()) {
      // 限时：卡死的 CLI 不能拖住整个 RPC（后面还有探测级兜底）。
      const live = await Promise.race([
        session.tryLiveModels().catch(() => null),
        new Promise<null>((resolve) => setTimeout(() => resolve(null), 3000)),
      ])
      if (live && live.models.length > 0) {
        this.modelsCache = live
        return live
      }
    }
    const cwd = this.store.listSessions()[0]?.cwd ?? process.cwd()
    const probe = this.probeSessionFactory(cwd)
    const result = await probe.probeModels().catch(() => null)
    if (result && result.models.length > 0) {
      this.modelsCache = result
      return result
    }
    return { models: [], current: result?.current ?? null }
  }

  onEvent(listener: (event: DaemonEvent) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  private emit(event: DaemonEvent): void {
    for (const listener of this.listeners) listener(event)
  }

  list(): SessionSummary[] {
    // Live sessions win over their persisted summaries; cold (persisted but
    // not rehydrated) sessions stay listed after a daemon restart — the phone
    // must see every session the daemon manages, not just live ones.
    const byId = new Map<string, SessionSummary>()
    for (const summary of this.store.listSessions()) byId.set(summary.id, summary)
    for (const session of this.sessions.values()) byId.set(session.id, session.summary())
    return [...byId.values()].sort((a, b) => b.updatedAt - a.updatedAt)
  }

  get(id: string): Session | undefined {
    return this.sessions.get(id)
  }

  /** Callbacks shared by every Session the manager creates. The session
   *  reference is late-bound (created inside `new Session(...)`). */
  private sessionCallbacks(get: () => Session): SessionCallbacks {
    return {
      onEvent: (event) => this.emit(event),
      onSummary: () => {
        this.store.upsertSession(get().summary())
        this.emit({ type: 'sessions.changed' })
      },
      onModels: (models: ModelInfoDto[], current: string | null) => {
        this.noteModels(models, current)
      },
    }
  }

  create(opts: {
    cwd: string
    title?: string
    model?: string
    permissionMode?: PermissionMode
    origin?: 'created' | 'imported'
  }): Session {
    let session!: Session
    session = new Session(this.sessionCallbacks(() => session), opts)
    this.sessions.set(session.id, session)
    this.store.upsertSession(session.summary())
    this.emit({ type: 'sessions.changed' })
    return session
  }

  /**
   * Take over an external Claude Code session as a regular cc-go session
   * (multi-project-history D5): the first prompt resumes the Claude session
   * (`resume: claudeSessionId`) and the phone's transcript comes pre-filled
   * with the replayed history. Idempotent per claudeSessionId — importing
   * twice returns the same cc-go session. The transcript file on disk is
   * never modified. Throws HistoryError (mapped by server.ts) when the
   * session does not exist or is unparseable, before anything is created.
   */
  async importSession(claudeSessionId: string, cwd: string, title?: string): Promise<Session> {
    // Idempotency must match BOTH ids: Claude's resume forks under new
    // session ids, so after the first prompt claudeSessionId has moved on —
    // the stable originClaudeSessionId keeps re-imports from forking a
    // second cc-go session for the same conversation.
    const isSameConversation = (s: { claudeSessionId: string | null; originClaudeSessionId: string | null }): boolean =>
      s.claudeSessionId === claudeSessionId || s.originClaudeSessionId === claudeSessionId
    for (const session of this.sessions.values()) {
      if (isSameConversation(session)) return session
    }
    const persisted = this.store.listSessions().find((s) => isSameConversation(s))
    if (persisted) {
      const live = this.ensureLive(persisted.id)
      if (live) return live
    }

    const history = await collectHistory(claudeSessionId, cwd)
    const session = this.create({
      cwd,
      title: title ?? titleFromHistory(history) ?? 'Imported session',
      origin: 'imported',
    })
    session.claudeSessionId = claudeSessionId
    session.originClaudeSessionId = claudeSessionId
    session.seedHistoryItems(history)
    session.configure({}) // persist claudeSessionId + origin link in the summary
    session.startHistoryTail() // external writes (terminal --resume) sync in
    return session
  }

  /**
   * Bring a persisted-but-not-live session back to life (after daemon
   * restart) so it can be watched or prompted again. Keeps the same id;
   * Claude context survives via `resume: claudeSessionId`.
   */
  rehydrate(summary: SessionSummary): Session {
    let session!: Session
    session = new Session(
      this.sessionCallbacks(() => session),
      {
        id: summary.id,
        cwd: summary.cwd,
        title: summary.title,
        model: summary.model ?? undefined,
        permissionMode: summary.permissionMode,
      },
    )
    session.claudeSessionId = summary.claudeSessionId
    session.origin = summary.origin
    session.originClaudeSessionId = summary.originClaudeSessionId ?? null
    session.createdAt = summary.createdAt
    session.updatedAt = summary.updatedAt
    if (summary.origin === 'imported' && summary.claudeSessionId) {
      // Imported sessions re-derive their history from Claude's transcript on
      // disk, so a daemon restart does not lose the phone's item list.
      void this.reseedImportedHistory(session, summary.claudeSessionId, summary.cwd)
    } else {
      session.adoptColdStart(
        'Reconnected after daemon restart — earlier items are in Claude\'s transcript, not shown here.',
      )
    }
    this.sessions.set(session.id, session)
    return session
  }

  private async reseedImportedHistory(
    session: Session,
    claudeSessionId: string,
    cwd: string,
  ): Promise<void> {
    try {
      session.seedHistoryItems(await collectHistory(claudeSessionId, cwd))
    } catch {
      session.adoptColdStart(
        'Reconnected after daemon restart — history replay failed; earlier items are in Claude\'s transcript.',
      )
    } finally {
      session.startHistoryTail()
    }
  }

  /** Get a live session, rehydrating a cold one on demand. */
  ensureLive(id: string): Session | undefined {
    const live = this.sessions.get(id)
    if (live) return live
    const summary = this.store.listSessions().find((s) => s.id === id)
    if (!summary) return undefined
    return this.rehydrate(summary)
  }

  dispose(id: string): boolean {
    const session = this.sessions.get(id)
    if (!session) return false
    session.dispose()
    this.sessions.delete(id)
    this.store.deleteSession(id)
    this.emit({ type: 'sessions.changed' })
    return true
  }

  disposeAll(): void {
    for (const session of this.sessions.values()) session.dispose()
    this.sessions.clear()
  }
}

export function newSessionId(): string {
  return randomUUID()
}
