/**
 * server.ts — the daemon's network face.
 *
 * HTTP(S):
 *   GET  /health              liveness probe
 *   GET  /info                public host info (no auth) — lets the phone
 *                             show "cc-go on <name>" before pairing
 *   POST /pair {code, name}   exchange the 6-digit pairing code shown in the
 *                             daemon terminal for a long-lived device token
 *
 * WebSocket (/ws): JSON frames.
 *   First message must be `hello {token}`; afterwards the connection accepts
 *   `{id, method, params}` requests and receives `{type:"event", ...}` pushes.
 *   Session transcript events go only to connections watching that session;
 *   `sessions.changed` and `permission.request` go to everyone (the phone
 *   needs the latter for notifications even without an open chat screen).
 *
 * All endpoints are served over TLS by default (self-signed cert pinned by
 * clients via TOFU — see tls.ts). Plain HTTP survives only behind the
 * explicit --no-tls dev flag, which forces loopback binding.
 */

import { createServer as createHttpServer, type IncomingMessage } from 'node:http'
import { createServer as createHttpsServer } from 'node:https'
import type { Server as NetServer } from 'node:net'
import { timingSafeEqual } from 'node:crypto'
import { networkInterfaces } from 'node:os'
import { basename } from 'node:path'
import { existsSync, statSync } from 'node:fs'
import { WebSocket, WebSocketServer } from 'ws'
import qrcode from 'qrcode-terminal'
import {
  ClientRequest,
  ErrorCodes,
  HelloParams,
  PairRequest,
  PermissionRespondParams,
  ProjectsRegisterParams,
  SessionConfigureParams,
  SessionCreateParams,
  SessionHistoryParams,
  SessionImportParams,
  SessionPromptParams,
  SessionsDiscoverParams,
  type DaemonEvent,
  type HostInfo,
  type ProjectInfo,
} from './protocol.js'
import { HistoryError, discoverSessions, replayHistory } from './history.js'
import type { Store } from './store.js'
import type { SessionManager } from './agent/manager.js'

interface AuthedConnection {
  socket: WebSocket
  deviceId: string
  watching: Set<string>
}

export interface DaemonOptions {
  port: number
  /** Bind 0.0.0.0 for LAN pairing, or 127.0.0.1 for SSH-tunnel-only mode. */
  bindLan: boolean
  pairingCode: string
  version: string
  /** TLS material; omit only with the explicit --no-tls dev flag (loopback only). */
  tls?: { cert: string; key: string; fingerprint: string }
}

const PAIRING_ATTEMPT_LIMIT = 10
const PAIRING_WINDOW_MS = 5 * 60_000

export function startDaemon(manager: SessionManager, store: Store, opts: DaemonOptions): NetServer {
  const hostInfo = (): HostInfo => ({
    name: store.daemonName,
    version: opts.version,
    daemonId: store.daemonId,
    defaultCwd: process.cwd(),
    claudeVersion: null,
  })

  const connections = new Set<AuthedConnection>()
  const pairingAttempts = new Map<string, { count: number; windowStart: number }>()

  const requestHandler = (req: IncomingMessage, res: import('node:http').ServerResponse): void => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    if (req.method === 'GET' && url.pathname === '/health') {
      json(res, 200, { ok: true })
      return
    }
    if (req.method === 'GET' && url.pathname === '/info') {
      json(res, 200, { ...hostInfo(), requiresPairing: true })
      return
    }
    if (req.method === 'POST' && url.pathname === '/pair') {
      handlePair(req, res)
      return
    }
    json(res, 404, { error: 'not found' })
  }

  const server = opts.tls
    ? createHttpsServer({ cert: opts.tls.cert, key: opts.tls.key }, requestHandler)
    : createHttpServer(requestHandler)

  function handlePair(req: IncomingMessage, res: import('node:http').ServerResponse): void {
    readBody(req)
      .then((body) => {
        const ip = req.socket.remoteAddress ?? 'unknown'
        const now = Date.now()
        const attempts = pairingAttempts.get(ip)
        if (attempts && now - attempts.windowStart < PAIRING_WINDOW_MS) {
          if (attempts.count >= PAIRING_ATTEMPT_LIMIT) {
            json(res, 429, { error: 'too many pairing attempts, try again later' })
            return
          }
          attempts.count++
        } else {
          pairingAttempts.set(ip, { count: 1, windowStart: now })
        }

        const parsed = PairRequest.safeParse(body)
        if (!parsed.success) {
          json(res, 400, { error: 'bad request' })
          return
        }
        if (!safeEqual(parsed.data.code.trim(), opts.pairingCode)) {
          json(res, 403, { error: 'wrong pairing code' })
          return
        }
        const device = store.addDevice(String(body.name ?? 'phone'))
        json(res, 200, { token: device.token, deviceId: device.id, host: hostInfo() })
      })
      .catch(() => json(res, 400, { error: 'bad request' }))
  }

  const wss = new WebSocketServer({ server, path: '/ws' })

  wss.on('connection', (socket) => {
    let authed: AuthedConnection | null = null
    let helloTimeout: NodeJS.Timeout | undefined
    const failTimer = setTimeout(() => {
      if (!authed) socket.close(4001, 'hello timeout')
    }, 10_000)

    socket.on('message', (data) => {
      let parsed: unknown
      try {
        parsed = JSON.parse(String(data))
      } catch {
        sendError(socket, '0', ErrorCodes.BAD_REQUEST, 'invalid JSON')
        return
      }
      if (!authed) {
        const hello = HelloParams.safeParse((parsed as { params?: unknown }).params ?? parsed)
        if (!hello.success) {
          socket.close(4003, 'unauthorized')
          return
        }
        const device = store.findDeviceByToken(hello.data.token)
        if (!device) {
          socket.close(4003, 'unauthorized')
          return
        }
        authed = { socket, deviceId: device.id, watching: new Set() }
        connections.add(authed)
        clearTimeout(failTimer)
        send(socket, { id: (parsed as { id?: string }).id ?? 'hello', ok: true, result: { host: hostInfo() } })
        return
      }
      void dispatch(authed, parsed)
    })

    socket.on('close', () => {
      clearTimeout(failTimer)
      clearTimeout(helloTimeout)
      if (authed) connections.delete(authed)
    })
  })

  async function dispatch(conn: AuthedConnection, raw: unknown): Promise<void> {
    const parsed = ClientRequest.safeParse(raw)
    if (!parsed.success) {
      sendError(conn.socket, '0', ErrorCodes.BAD_REQUEST, 'invalid request frame')
      return
    }
    const { id, method, params } = parsed.data
    try {
      const result = await handleMethod(conn, method, params)
      send(conn.socket, { id, ok: true, result })
    } catch (err) {
      const failure = err as RpcError
      send(conn.socket, {
        id,
        ok: false,
        error: { code: failure.code ?? ErrorCodes.INTERNAL, message: failure.message },
      })
    }
  }

  function requireSession(sessionId: unknown) {
    const session = typeof sessionId === 'string' ? manager.ensureLive(sessionId) : undefined
    if (!session) throw new RpcError(ErrorCodes.NOT_FOUND, 'session not found')
    return session
  }

  /** Whitelist gate (multi-project-history D2): canonicalize and require the
   *  directory to be registered. Returns the canonical path so downstream
   *  cwd→transcript-dir encoding always matches Claude Code's own. */
  function requireProjectDir(raw: string): string {
    const canonical = store.canonicalProjectPath(raw)
    if (!store.hasProject(raw)) {
      throw new RpcError(ErrorCodes.BAD_REQUEST, `directory not registered: ${canonical}`)
    }
    return canonical
  }

  function projectInfo(path: string): ProjectInfo {
    let available = false
    try {
      available = statSync(path).isDirectory()
    } catch {
      available = false
    }
    return {
      path,
      name: basename(path) || path,
      available,
      sessionCount: manager.list().filter((s) => s.cwd === path).length,
    }
  }

  function historyRpcError(err: unknown): RpcError {
    if (err instanceof HistoryError) {
      const code =
        err.code === 'not_found' ? ErrorCodes.NOT_FOUND : ErrorCodes.BAD_REQUEST
      return new RpcError(code, err.message)
    }
    return new RpcError(ErrorCodes.INTERNAL, err instanceof Error ? err.message : String(err))
  }

  async function handleMethod(conn: AuthedConnection, method: string, params: Record<string, unknown>): Promise<unknown> {
    switch (method) {
      case 'host.info':
        return { host: hostInfo(), sessions: manager.list() }

      case 'session.create': {
        const parsed = SessionCreateParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        // No cwd given (or a blank one): fall back to the first registered
        // AND existing project — the daemon's own cwd is only registered when
        // the store was empty at startup, so it cannot be the fallback.
        let rawCwd = parsed.data.cwd && parsed.data.cwd.trim() !== '' ? parsed.data.cwd : undefined
        if (rawCwd === undefined) {
          const available = store.listProjects().filter((p) => {
            try {
              return statSync(p).isDirectory()
            } catch {
              return false
            }
          })
          if (available.length === 0) {
            throw new RpcError(ErrorCodes.BAD_REQUEST, 'no registered project directory is available')
          }
          rawCwd = available[0]!
        }
        if (!existsSync(rawCwd) || !statSync(rawCwd).isDirectory()) {
          throw new RpcError(ErrorCodes.BAD_REQUEST, `not a directory: ${rawCwd}`)
        }
        const cwd = requireProjectDir(rawCwd)
        const session = manager.create({
          cwd,
          title: parsed.data.title,
          model: parsed.data.model,
          permissionMode: parsed.data.permissionMode,
        })
        return { summary: session.summary() }
      }

      // ---- projects & session history (multi-project-history) ---------------

      case 'projects.list':
        return { projects: store.listProjects().map((p) => projectInfo(p)) }

      case 'projects.register': {
        const parsed = ProjectsRegisterParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        if (!existsSync(parsed.data.path) || !statSync(parsed.data.path).isDirectory()) {
          throw new RpcError(ErrorCodes.BAD_REQUEST, `not a directory: ${parsed.data.path}`)
        }
        const canonical = store.addProject(parsed.data.path)
        return { project: projectInfo(canonical) }
      }

      case 'sessions.discover': {
        const parsed = SessionsDiscoverParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        const cwd = requireProjectDir(parsed.data.cwd)
        const managed = new Map<string, string>()
        for (const summary of manager.list()) {
          // both ids: after a fork the summary tracks the NEW claude session
          // id, but the imported-from transcript must still show as managed
          if (summary.claudeSessionId) managed.set(summary.claudeSessionId, summary.id)
          if (summary.originClaudeSessionId) managed.set(summary.originClaudeSessionId, summary.id)
        }
        try {
          return { sessions: await discoverSessions(cwd, managed) }
        } catch (err) {
          throw historyRpcError(err)
        }
      }

      case 'session.history': {
        const parsed = SessionHistoryParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        const cwd = requireProjectDir(parsed.data.cwd)
        try {
          return await replayHistory(
            parsed.data.claudeSessionId,
            cwd,
            parsed.data.beforeLine,
            parsed.data.limit,
          )
        } catch (err) {
          throw historyRpcError(err)
        }
      }

      case 'session.import': {
        const parsed = SessionImportParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        const cwd = requireProjectDir(parsed.data.cwd)
        try {
          const session = await manager.importSession(
            parsed.data.claudeSessionId,
            cwd,
            parsed.data.title,
          )
          return { summary: session.summary() }
        } catch (err) {
          throw historyRpcError(err)
        }
      }

      case 'session.watch': {
        const sessionId = params.sessionId
        const session = requireSession(sessionId)
        conn.watching.add(session.id)
        return { snapshot: session.snapshot(), summary: session.summary() }
      }

      case 'session.unwatch': {
        const sessionId = params.sessionId
        if (typeof sessionId === 'string') conn.watching.delete(sessionId)
        return {}
      }

      case 'session.prompt': {
        const parsed = SessionPromptParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        const session = requireSession(parsed.data.sessionId)
        session.prompt(parsed.data.text, parsed.data.mode)
        return {}
      }

      case 'session.cancel': {
        const session = requireSession(params.sessionId)
        session.cancel()
        return {}
      }

      case 'session.configure': {
        const parsed = SessionConfigureParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        const session = requireSession(parsed.data.sessionId)
        session.configure(parsed.data)
        return { summary: session.summary() }
      }

      case 'permission.respond': {
        const parsed = PermissionRespondParams.safeParse(params)
        if (!parsed.success) throw new RpcError(ErrorCodes.BAD_REQUEST, parsed.error.message)
        const session = requireSession(parsed.data.sessionId)
        session.respondPermission(parsed.data.itemId, parsed.data.allow, parsed.data.allowToolForSession)
        return {}
      }

      case 'session.delete': {
        const sessionId = params.sessionId
        if (typeof sessionId !== 'string') throw new RpcError(ErrorCodes.BAD_REQUEST, 'sessionId required')
        const ok = manager.dispose(sessionId)
        if (!ok) throw new RpcError(ErrorCodes.NOT_FOUND, 'session not found')
        return {}
      }

      default:
        throw new RpcError(ErrorCodes.NOT_FOUND, `unknown method: ${method}`)
    }
  }

  // Fan daemon events out to interested connections.
  manager.onEvent((event) => {
    const notifyAll = event.type === 'permission.request' || event.type === 'sessions.changed'
    for (const conn of connections) {
      if (conn.socket.readyState !== WebSocket.OPEN) continue
      const watchingThis = event.type !== 'session' || conn.watching.has(event.sessionId)
      if (notifyAll || watchingThis) send(conn.socket, { type: 'event', event })
    }
  })

  server.listen(opts.port, opts.bindLan ? '0.0.0.0' : '127.0.0.1', () => {
    printBanner(opts, store)
  })

  return server
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class RpcError extends Error {
  code: string | undefined
  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

function send(socket: WebSocket, payload: unknown): void {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload))
}

function sendError(socket: WebSocket, id: string, code: string, message: string): void {
  send(socket, { id, ok: false, error: { code, message } })
}

function json(res: import('node:http').ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

function readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    req.on('data', (c: Buffer) => {
      chunks.push(c)
      if (chunks.reduce((n, b) => n + b.length, 0) > 1_000_000) {
        reject(new Error('body too large'))
        req.destroy()
      }
    })
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'))
      } catch {
        reject(new Error('invalid JSON'))
      }
    })
    req.on('error', reject)
  })
}

function safeEqual(a: string, b: string): boolean {
  const bufA = Buffer.from(a)
  const bufB = Buffer.from(b)
  if (bufA.length !== bufB.length) return false
  return timingSafeEqual(bufA, bufB)
}

function printBanner(opts: DaemonOptions, store: Store): void {
  const scheme = opts.tls ? 'wss' : 'ws'
  const bind = opts.bindLan ? '0.0.0.0 (LAN)' : '127.0.0.1 (local only)'
  const urls = opts.bindLan ? lanAddresses().map((ip) => `${scheme}://${ip}:${opts.port}`) : [`${scheme}://127.0.0.1:${opts.port}`]
  console.log(`
  cc-go daemon ${opts.version} — ${store.daemonName}
  listening  ${bind}  port ${opts.port}${opts.tls ? '' : '  (PLAINTEXT dev mode)'}
  pairing   code ${opts.pairingCode}  (expires with the daemon process)
`)
  if (opts.tls) {
    console.log(`  cert fpr  ${opts.tls.fingerprint}`)
    console.log('            (verify once on first pairing — clients pin it automatically)\n')
  }
  const primary = urls[0] ?? ''
  const qrPayload = `ccgo://${primary.replace(`${scheme}://`, '')}?code=${opts.pairingCode}`
  qrcode.generate(qrPayload, { small: true }, (code) => console.log(code))
  console.log(`  scan QR or enter in the app:  ${primary}  code ${opts.pairingCode}\n`)
}

function lanAddresses(): string[] {
  const results: string[] = []
  for (const infos of Object.values(networkInterfaces())) {
    for (const info of infos ?? []) {
      if (info.family === 'IPv4' && !info.internal) results.push(info.address)
    }
  }
  return results
}
