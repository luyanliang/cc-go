import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { once } from 'node:events'
import type { Server } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import { Store } from '../src/store.js'
import { SessionManager } from '../src/agent/manager.js'
import { startDaemon } from '../src/server.js'

type Frame = Record<string, any>

function client(url: string) {
  const socket = new WebSocket(url)
  const frames: Frame[] = []
  const waiters: Array<{ match: (frame: Frame) => boolean; resolve: (frame: Frame) => void }> = []
  socket.on('message', (raw) => {
    const frame = JSON.parse(String(raw)) as Frame
    const index = waiters.findIndex((waiter) => waiter.match(frame))
    if (index === -1) frames.push(frame)
    else waiters.splice(index, 1)[0]!.resolve(frame)
  })
  const next = (match: (frame: Frame) => boolean): Promise<Frame> => {
    const index = frames.findIndex(match)
    if (index !== -1) return Promise.resolve(frames.splice(index, 1)[0]!)
    return new Promise((resolve, reject) => {
      const waiter = { match, resolve: (frame: Frame) => { clearTimeout(timer); resolve(frame) } }
      const timer = setTimeout(() => {
        const pending = waiters.indexOf(waiter)
        if (pending !== -1) waiters.splice(pending, 1)
        reject(new Error('timed out waiting for daemon frame'))
      }, 2000)
      waiters.push(waiter)
    })
  }
  return { socket, next }
}

describe('daemon HTTP/WebSocket boundary', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-server-test-'))
  const store = new Store(dir)
  const manager = new SessionManager(store)
  let server: Server
  let base: string
  const sockets: WebSocket[] = []

  beforeAll(async () => {
    server = startDaemon(manager, store, {
      port: 0,
      bindLan: false,
      pairingCode: '654321',
      version: 'test',
    })
    await once(server, 'listening')
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('missing server address')
    base = `http://127.0.0.1:${address.port}`
  })

  afterAll(async () => {
    for (const socket of sockets) socket.terminate()
    manager.disposeAll()
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
    rmSync(dir, { recursive: true, force: true })
  })

  it('requires a valid pairing code and device token', async () => {
    expect((await fetch(`${base}/health`).then((r) => r.json())).ok).toBe(true)
    const wrong = await fetch(`${base}/pair`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code: '000000', name: 'test phone' }),
    })
    expect(wrong.status).toBe(403)

    const unpaired = client(base.replace('http:', 'ws:') + '/ws')
    sockets.push(unpaired.socket)
    await once(unpaired.socket, 'open')
    unpaired.socket.send(JSON.stringify({ id: 'hello', method: 'hello', params: { token: 'invalid' } }))
    const [code] = await once(unpaired.socket, 'close')
    expect(code).toBe(4003)
  })

  it('pairs, authenticates, creates a session, and returns its watch snapshot', async () => {
    const paired = await fetch(`${base}/pair`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code: '654321', name: 'test phone' }),
    })
    expect(paired.status).toBe(200)
    const { token } = await paired.json() as { token: string }
    expect(store.findDeviceByToken(token)).toBeDefined()

    const link = client(base.replace('http:', 'ws:') + '/ws')
    sockets.push(link.socket)
    await once(link.socket, 'open')
    link.socket.send(JSON.stringify({ id: 'hello', method: 'hello', params: { token } }))
    expect((await link.next((f) => f.id === 'hello')).ok).toBe(true)

    link.socket.send(JSON.stringify({ id: 'create', method: 'session.create', params: { title: 'test' } }))
    const created = await link.next((f) => f.id === 'create')
    expect(created.ok).toBe(true)
    const sessionId = created.result.summary.id as string
    expect(created.result.summary.title).toBe('test')
    expect((await link.next((f) => f.type === 'event' && f.event?.type === 'sessions.changed')).type).toBe('event')

    link.socket.send(JSON.stringify({ id: 'watch', method: 'session.watch', params: { sessionId } }))
    const watched = await link.next((f) => f.id === 'watch')
    expect(watched.result.summary.id).toBe(sessionId)
    expect(watched.result.snapshot.items).toEqual([])

    link.socket.send(JSON.stringify({ id: 'invalid', method: 'session.prompt', params: { sessionId, text: '' } }))
    const invalid = await link.next((f) => f.id === 'invalid')
    expect(invalid.ok).toBe(false)
    expect(invalid.error.code).toBe('bad_request')
  })
})
