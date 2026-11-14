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
import type { DaemonEvent, PermissionMode, SessionSummary } from '../protocol.js'
import type { Store } from '../store.js'
import { collectHistory, titleFromHistory } from '../history.js'
import { Session } from './session.js'

export class SessionManager {
  private sessions = new Map<string, Session>()
  private listeners = new Set<(event: DaemonEvent) => void>()

  constructor(private readonly store: Store) {}

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

  create(opts: {
    cwd: string
    title?: string
    model?: string
    permissionMode?: PermissionMode
    origin?: 'created' | 'imported'
  }): Session {
    const session = new Session(
      {
        onEvent: (event) => this.emit(event),
        onSummary: () => {
          this.store.upsertSession(session.summary())
          this.emit({ type: 'sessions.changed' })
        },
      },
      opts,
    )
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
    const session = new Session(
      {
        onEvent: (event) => this.emit(event),
        onSummary: () => {
          this.store.upsertSession(session.summary())
          this.emit({ type: 'sessions.changed' })
        },
      },
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
