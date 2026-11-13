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
    const live = [...this.sessions.values()].map((s) => s.summary())
    return live.sort((a, b) => b.updatedAt - a.updatedAt)
  }

  get(id: string): Session | undefined {
    return this.sessions.get(id)
  }

  create(opts: { cwd: string; title?: string; model?: string; permissionMode?: PermissionMode }): Session {
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
    session.createdAt = summary.createdAt
    session.updatedAt = summary.updatedAt
    session.adoptColdStart('Reconnected after daemon restart — earlier items are in Claude\'s transcript, not shown here.')
    this.sessions.set(session.id, session)
    return session
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
