/**
 * Persistent daemon state under ~/.cc-go/:
 *  - devices.json: paired phone device tokens
 *  - sessions.json: session metadata so the list survives daemon restarts
 *
 * Written atomically (tmp + rename). No secrets beyond device tokens live
 * here; those are random 32-byte values with no other meaning.
 */

import { randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import type { SessionSummary } from './protocol.js'

export interface PairedDevice {
  id: string
  name: string
  token: string
  createdAt: number
}

interface StoreData {
  daemonId: string
  daemonName: string
  devices: PairedDevice[]
  sessions: SessionSummary[]
  /** Registered project directories (canonical paths). Whitelist for
   *  session creation / discovery / import (multi-project-history D2). */
  projects: string[]
}

export class Store {
  readonly dir: string
  private data: StoreData

  constructor(dir?: string) {
    this.dir = dir ?? join(homedir(), '.cc-go')
    if (!existsSync(this.dir)) mkdirSync(this.dir, { recursive: true })
    this.data = this.load()
  }

  private fileFor(name: string): string {
    return join(this.dir, name)
  }

  private load(): StoreData {
    const fallback: StoreData = {
      daemonId: randomBytes(8).toString('hex'),
      daemonName: defaultHostName(),
      devices: [],
      sessions: [],
      projects: [],
    }
    try {
      const raw = readFileSync(this.fileFor('store.json'), 'utf8')
      return { ...fallback, ...(JSON.parse(raw) as Partial<StoreData>) }
    } catch {
      return fallback
    }
  }

  private save(): void {
    const file = this.fileFor('store.json')
    const tmp = `${file}.tmp`
    writeFileSync(tmp, JSON.stringify(this.data, null, 2), { mode: 0o600 })
    renameSync(tmp, file)
  }

  get daemonId(): string {
    return this.data.daemonId
  }

  get daemonName(): string {
    return this.data.daemonName
  }

  setDaemonName(name: string): void {
    this.data.daemonName = name
    this.save()
  }

  // ---- devices ------------------------------------------------------------

  listDevices(): readonly PairedDevice[] {
    return this.data.devices
  }

  findDeviceByToken(token: string): PairedDevice | undefined {
    return this.data.devices.find((d) => d.token === token)
  }

  addDevice(name: string): PairedDevice {
    const device: PairedDevice = {
      id: randomBytes(8).toString('hex'),
      name: name || 'phone',
      token: randomBytes(32).toString('hex'),
      createdAt: Date.now(),
    }
    this.data.devices.push(device)
    this.save()
    return device
  }

  removeDevice(id: string): void {
    this.data.devices = this.data.devices.filter((d) => d.id !== id)
    this.save()
  }

  // ---- sessions -----------------------------------------------------------

  listSessions(): SessionSummary[] {
    return this.data.sessions
  }

  upsertSession(summary: SessionSummary): void {
    const idx = this.data.sessions.findIndex((s) => s.id === summary.id)
    if (idx >= 0) this.data.sessions[idx] = summary
    else this.data.sessions.unshift(summary)
    this.save()
  }

  deleteSession(id: string): void {
    this.data.sessions = this.data.sessions.filter((s) => s.id !== id)
    this.save()
  }

  // ---- projects -----------------------------------------------------------

  /**
   * Canonical form for project directories: realpath when the path exists
   * (collapses symlinks and `..` segments alike), plain resolution otherwise.
   * Registration and every whitelist check MUST go through this so `..`
   * traversal or a symlinked alias cannot slip past an exact-match compare.
   */
  canonicalProjectPath(dir: string): string {
    const resolved = resolve(dir)
    try {
      return realpathSync(resolved)
    } catch {
      return resolved
    }
  }

  listProjects(): readonly string[] {
    return this.data.projects
  }

  addProject(dir: string): string {
    const canonical = this.canonicalProjectPath(dir)
    if (!this.data.projects.includes(canonical)) {
      this.data.projects.push(canonical)
      this.save()
    }
    return canonical
  }

  removeProject(dir: string): void {
    const canonical = this.canonicalProjectPath(dir)
    this.data.projects = this.data.projects.filter((p) => p !== canonical)
    this.save()
  }

  hasProject(dir: string): boolean {
    return this.data.projects.includes(this.canonicalProjectPath(dir))
  }
}

function defaultHostName(): string {
  return homedir().split('/').pop() || 'computer'
}
