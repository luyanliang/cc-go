/**
 * Integration test for the multi-project-history RPC surface: spins up the
 * real daemon (plaintext loopback), pairs over HTTP, then exercises the
 * WebSocket methods — whitelist rejection included (task 3.1/3.2).
 */

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import { Store } from '../src/store.js'
import { SessionManager } from '../src/agent/manager.js'
import { startDaemon } from '../src/server.js'
import { encodeCwd } from '../src/history.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-server-test-'))
  dirs.push(dir)
  return dir
}

const SID = 'abcdefab-cdef-4abc-8abc-222222222222'

let server: import('node:http').Server
let port: number
let token: string
let projectDir: string
let foreignDir: string

interface Frame {
  id?: string
  ok?: boolean
  result?: unknown
  error?: { code: string; message: string }
}

function rpc(ws: WebSocket, id: string, method: string, params: Record<string, unknown> = {}): Promise<Frame> {
  return new Promise((resolve, reject) => {
    const onMessage = (data: unknown): void => {
      const frame = JSON.parse(String(data)) as Frame
      if (frame.id === id) {
        ws.off('message', onMessage)
        resolve(frame)
      }
    }
    ws.on('message', onMessage)
    ws.send(JSON.stringify({ id, method, params }))
    setTimeout(() => {
      ws.off('message', onMessage)
      reject(new Error(`rpc ${method} timed out`))
    }, 5000).unref()
  })
}

function openSocket(): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`)
    ws.on('open', () => resolve(ws))
    ws.on('error', reject)
  })
}

beforeAll(async () => {
  const configDir = tempDir()
  projectDir = tempDir()
  foreignDir = tempDir()
  process.env.CLAUDE_CONFIG_DIR = configDir

  const transcriptDir = join(configDir, 'projects', encodeCwd(projectDir))
  mkdirSync(transcriptDir, { recursive: true })
  writeFileSync(
    join(transcriptDir, `${SID}.jsonl`),
    [
      JSON.stringify({ type: 'user', uuid: 'u1', timestamp: '2026-11-14T02:00:00.000Z', message: { role: 'user', content: '集成测试消息' } }),
      JSON.stringify({ type: 'assistant', uuid: 'a1', timestamp: '2026-11-14T02:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: '收到。' }] } }),
    ].join('\n') + '\n',
  )

  const home = tempDir()
  const store = new Store(home)
  store.addProject(projectDir) // registered; foreignDir deliberately is not

  server = startDaemon(new SessionManager(store), store, {
    port: 0,
    bindLan: false,
    pairingCode: '246810',
    version: 'test',
  })
  await new Promise<void>((resolve) => server.once('listening', resolve))
  port = (server.address() as { port: number }).port

  const pairRes = await fetch(`http://127.0.0.1:${port}/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ code: '246810', name: 'test-device' }),
  })
  const pairBody = (await pairRes.json()) as { token: string }
  token = pairBody.token
})

afterAll(() => {
  delete process.env.CLAUDE_CONFIG_DIR
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
  server.closeAllConnections?.()
  server.close()
})

describe('multi-project RPC surface', () => {
  it('registers, lists and gates directories through the whitelist', async () => {
    const ws = await openSocket()
    try {
      const hello = await rpc(ws, 'h', 'hello', { token })
      expect(hello.ok).toBe(true)

      // unregistered directory: discover and create are both rejected
      const badDiscover = await rpc(ws, 'd1', 'sessions.discover', { cwd: foreignDir })
      expect(badDiscover.ok).toBe(false)
      expect(badDiscover.error?.code).toBe('bad_request')

      const badCreate = await rpc(ws, 'c1', 'session.create', { cwd: foreignDir })
      expect(badCreate.ok).toBe(false)
      expect(badCreate.error?.code).toBe('bad_request')

      // the registered project lists with a sensible shape
      const list = await rpc(ws, 'p1', 'projects.list')
      expect(list.ok).toBe(true)
      const projects = (list.result as { projects: Array<Record<string, unknown>> }).projects
      const mine = projects.find((p) => p.path === projectDir)
      expect(mine).toMatchObject({ available: true, sessionCount: 0 })

      // runtime registration through an authed connection
      const reg = await rpc(ws, 'p2', 'projects.register', { path: foreignDir })
      expect(reg.ok).toBe(true)
      expect((reg.result as { project: { path: string } }).project.path).toBe(foreignDir)

      // a deleted directory stays listed but is marked unavailable
      rmSync(foreignDir, { recursive: true, force: true })
      const relist = await rpc(ws, 'p3', 'projects.list')
      const gone = ((relist.result as { projects: Array<Record<string, unknown>> }).projects).find(
        (p) => p.path === foreignDir,
      )
      expect(gone).toMatchObject({ available: false })
    } finally {
      ws.close()
    }
  })

  it('discovers, replays and imports sessions in a registered project', async () => {
    const ws = await openSocket()
    try {
      await rpc(ws, 'h', 'hello', { token })

      const discover = await rpc(ws, 'd1', 'sessions.discover', { cwd: projectDir })
      expect(discover.ok).toBe(true)
      const sessions = (discover.result as { sessions: Array<Record<string, unknown>> }).sessions
      expect(sessions).toHaveLength(1)
      expect(sessions[0]).toMatchObject({ claudeSessionId: SID, title: '集成测试消息', managed: false })

      const history = await rpc(ws, 'hh', 'session.history', { claudeSessionId: SID, cwd: projectDir })
      expect(history.ok).toBe(true)
      const hist = history.result as { items: Array<{ kind: string }>; nextBeforeLine: number | null }
      expect(hist.items.map((i) => i.kind)).toEqual(['user', 'assistant'])
      expect(hist.nextBeforeLine).toBe(null)

      const imp = await rpc(ws, 'i1', 'session.import', { claudeSessionId: SID, cwd: projectDir })
      expect(imp.ok).toBe(true)
      const summary = (imp.result as { summary: Record<string, unknown> }).summary
      expect(summary).toMatchObject({ claudeSessionId: SID, origin: 'imported', cwd: projectDir })

      // discovery now marks the session as managed
      const rediscover = await rpc(ws, 'd2', 'sessions.discover', { cwd: projectDir })
      const managed = ((rediscover.result as { sessions: Array<Record<string, unknown>> }).sessions)[0]
      expect(managed).toMatchObject({ managed: true, ccGoSessionId: summary.id })

      // a null/blank cwd falls back to the first registered+available project
      // (the daemon's own cwd is NOT registered in this fixture)
      const created = await rpc(ws, 'c9', 'session.create', {})
      expect(created.ok).toBe(true)
      expect((created.result as { summary: { cwd: string } }).summary.cwd).toBe(projectDir)
      await rpc(ws, 'c10', 'session.delete', { sessionId: (created.result as { summary: { id: string } }).summary.id })
    } finally {
      ws.close()
    }
  })
})
