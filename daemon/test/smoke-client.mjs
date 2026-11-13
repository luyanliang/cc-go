#!/usr/bin/env node
/**
 * Smoke-test client that plays the phone: pairs over HTTPS, then drives the
 * daemon over the WebSocket — create session, watch, prompt, and answer a
 * permission request. Prints the event stream so failures are visible.
 *
 * TLS follows the same trust-on-first-use model as the phone app: the
 * certificate fingerprint is learned (or compared against --fingerprint /
 * the known-hosts file) before any token or payload is sent, and every
 * connection then pins that fingerprint. A mismatch exits non-zero.
 *
 * Usage:
 *   node test/smoke-client.mjs [code] [--host 127.0.0.1] [--port 8747]
 *                              [--fingerprint AA:BB:...] [--plain]
 *
 *   --plain        connect plaintext (daemon started with --no-tls, loopback)
 *   --fingerprint  require this exact cert fingerprint (TOFU check)
 *
 * Known fingerprints persist in /tmp/ccgo-smoke-known.json per host:port.
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import https from 'node:https'
import http from 'node:http'
import tls from 'node:tls'
import WebSocket from 'ws'

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : fallback
}
const flagValues = new Set(['--host', '--port', '--fingerprint'].map((f) => flag(f)).filter(Boolean))
const CODE = args.find((a) => /^\d+$/.test(a) && !flagValues.has(a)) ?? '654321'
const HOST = flag('--host', '127.0.0.1')
const PORT = Number(flag('--port', 8747))
const WANT_FINGERPRINT = flag('--fingerprint')
const PLAIN = args.includes('--plain')
const TEST_DIR = '/tmp/ccgo-test'
const KNOWN_HOSTS = '/tmp/ccgo-smoke-known.json'

const log = (...args2) => console.log('[client]', ...args2)
const norm = (fp) => String(fp).replace(/:/g, '').toLowerCase()

// ---------------------------------------------------------------------------
// TOFU: probe the cert, compare against --fingerprint / known hosts, pin it.
// ---------------------------------------------------------------------------

function loadKnown() {
  try {
    return JSON.parse(readFileSync(KNOWN_HOSTS, 'utf8'))
  } catch {
    return {}
  }
}

function saveKnown(known) {
  writeFileSync(KNOWN_HOSTS, JSON.stringify(known, null, 2))
}

function probeCert() {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ host: HOST, port: PORT, rejectUnauthorized: false, servername: undefined }, () => {
      const cert = socket.getPeerCertificate()
      socket.end()
      if (!cert || !cert.raw || !cert.fingerprint256) reject(new Error('server presented no certificate'))
      else resolve({ fingerprint: cert.fingerprint256, certPem: derToPem(cert.raw) })
    })
    socket.on('error', reject)
    socket.setTimeout(5000, () => {
      socket.destroy()
      reject(new Error('TLS probe timed out'))
    })
  })
}

function derToPem(der) {
  const b64 = Buffer.from(der).toString('base64')
  const lines = b64.match(/.{1,64}/g) ?? []
  return `-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n`
}

async function establishTrust() {
  const key = `${HOST}:${PORT}`
  const live = await probeCert()
  const known = loadKnown()
  const expected = WANT_FINGERPRINT ?? known[key]

  if (expected) {
    if (norm(live.fingerprint) !== norm(expected)) {
      console.error(`[client] CERTIFICATE FINGERPRINT MISMATCH for ${key}`)
      console.error(`  expected ${expected}`)
      console.error(`  got      ${live.fingerprint}`)
      console.error('  If the server was reinstalled, clear the entry in ' + KNOWN_HOSTS)
      process.exit(1)
    }
    log(`cert fingerprint verified ✓ (${live.fingerprint})`)
  } else {
    log(`TOFU: learning cert fingerprint ${live.fingerprint}`)
    known[key] = live.fingerprint
    saveKnown(known)
  }
  return live
}

/**
 * Agent that pins the verified certificate on every real connection: the
 * probed cert is installed as the only trusted CA, so chain verification
 * succeeds for exactly this certificate and fails for anything else.
 * Hostname checking is disabled deliberately — the pinned cert IS the
 * identity in the TOFU model (the host is a bare IP anyway).
 */
function pinnedAgent(certPem) {
  return new https.Agent({
    ca: [certPem],
    checkServerIdentity: () => undefined,
  })
}

// ---------------------------------------------------------------------------
// HTTP + WS plumbing
// ---------------------------------------------------------------------------

let agent

function jsonRequest(method, path, body) {
  const mod = PLAIN ? http : https
  const data = body ? JSON.stringify(body) : null
  return new Promise((resolve, reject) => {
    const req = mod.request(
      {
        hostname: HOST,
        port: PORT,
        path,
        method,
        agent,
        headers: data ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } : {},
      },
      (res) => {
        let buf = ''
        res.on('data', (c) => (buf += c))
        res.on('end', () => {
          try {
            resolve({ status: res.statusCode, body: JSON.parse(buf || '{}') })
          } catch {
            reject(new Error(`invalid JSON from ${path}`))
          }
        })
      },
    )
    req.on('error', reject)
    if (data) req.write(data)
    req.end()
  })
}

async function pair() {
  const { status, body } = await jsonRequest('POST', '/pair', { code: CODE, name: 'smoke-test' })
  if (status !== 200) throw new Error(`pair failed: ${status} ${JSON.stringify(body)}`)
  log('paired, device', body.deviceId, 'host', body.host.name)
  return body.token
}

function makeClient(token) {
  const scheme = PLAIN ? 'ws' : 'wss'
  const socket = new WebSocket(`${scheme}://${HOST}:${PORT}/ws`, PLAIN ? undefined : { agent })
  const pending = new Map()
  const handlers = []
  let nextId = 0
  const ready = new Promise((resolve, reject) => {
    socket.on('error', reject)
    socket.on('open', () => {
      const id = 'hello'
      pending.set(id, { resolve, reject })
      socket.send(JSON.stringify({ id, method: 'hello', params: { token } }))
    })
  })
  socket.on('message', (data) => {
    const frame = JSON.parse(String(data))
    if (frame.type === 'event') {
      for (const h of handlers) h(frame.event)
      return
    }
    const cb = pending.get(frame.id)
    if (cb) {
      pending.delete(frame.id)
      if (!frame.ok) cb.reject(new Error(`${frame.error.code}: ${frame.error.message}`))
      else cb.resolve(frame.result)
    }
  })
  return {
    ready,
    onEvent(handler) {
      handlers.push(handler)
    },
    call(method, params) {
      const id = `r${nextId++}`
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject })
        socket.send(JSON.stringify({ id, method, params }))
      })
    },
    close() {
      socket.close()
    },
  }
}

const fmtItem = (item) => {
  if (item.kind === 'user') return `user: ${item.text.slice(0, 60)}`
  if (item.kind === 'assistant') return `assistant(${item.status}): ${item.text.slice(0, 60)}`
  if (item.kind === 'tool') return `tool ${item.name} [${item.status}]`
  return `notice(${item.level}): ${item.text.slice(0, 80)}`
}

async function main() {
  if (!PLAIN) agent = pinnedAgent((await establishTrust()).certPem)
  else log('plaintext dev mode (--plain) — skipping TLS/TOFU')

  const token = await pair()

  // wrong code must fail
  const bad = await jsonRequest('POST', '/pair', { code: '000000' })
  if (bad.status !== 403) throw new Error(`expected 403 for wrong code, got ${bad.status}`)
  log('wrong pairing code rejected ✓')

  const client = makeClient(token)
  await client.ready
  log('ws hello ok ✓')

  const info = await client.call('host.info', {})
  log(`host.info → ${info.host.name}, ${info.sessions.length} sessions`)

  if (!existsSync(TEST_DIR)) throw new Error(`${TEST_DIR} missing — create it first (mkdir -p ${TEST_DIR})`)
  const created = await client.call('session.create', { cwd: TEST_DIR })
  const sessionId = created.summary.id
  log(`session.create → ${sessionId} (cwd ${created.summary.cwd}) ✓`)

  const watched = await client.call('session.watch', { sessionId })
  log(`session.watch → snapshot ${watched.snapshot.items.length} items, phase ${watched.snapshot.phase} ✓`)

  const events = []
  client.onEvent((event) => {
    events.push(event)
    if (event.type === 'session' && event.event.ev === 'item.added') {
      log(`+ ${fmtItem(event.event.item)}`)
    } else if (event.type === 'session' && event.event.ev === 'item.updated') {
      log(`~ ${fmtItem(event.event.item)}`)
    } else if (event.type === 'permission.request') {
      log(`!! permission.request: ${event.name} (${event.itemId})`)
    }
  })

  // --- Test 1: plain Q&A turn ---
  log('prompt 1: simple question')
  await client.call('session.prompt', { sessionId, text: 'Reply with exactly the word PONG and nothing else.', mode: 'queue' })
  await waitFor(events, (e) => {
    const item = e.type === 'session' && e.event.ev === 'item.updated' ? e.event.item : null
    return item?.kind === 'assistant' && item.status === 'done' && item.text.length > 0
  }, 120_000)
  log('assistant reply completed ✓')

  // --- Test 2: permission-gated tool call ---
  log('prompt 2: write a file (expects permission request)')
  events.length = 0
  await client.call('session.prompt', {
    sessionId,
    text: 'Create a file named ping.txt in the current directory containing the text "pong". Then say DONE.',
    mode: 'queue',
  })
  const permEvent = await waitFor(events, (e) => e.type === 'permission.request', 120_000)
  log(`permission arrived: ${permEvent.name} ✓`)
  await client.call('permission.respond', { sessionId, itemId: permEvent.itemId, allow: true, allowToolForSession: false })
  log('allowed from "phone" ✓')
  await waitFor(events, (e) => {
    const item = e.type === 'session' && e.event.ev === 'item.updated' ? e.event.item : null
    return item?.kind === 'assistant' && item.status === 'done'
  }, 180_000)
  const { execSync } = await import('node:child_process')
  const file = execSync(`cat ${TEST_DIR}/ping.txt`).toString().trim()
  if (file !== 'pong') throw new Error(`ping.txt has unexpected content: ${file}`)
  log(`file written through permission flow ✓ (content: ${file})`)

  // --- Test 3: cancel mid-turn ---
  log('prompt 3: long task then cancel')
  events.length = 0
  await client.call('session.prompt', {
    sessionId,
    text: 'Count from 1 to 100 extremely slowly, one number per line, with generous pauses.',
    mode: 'queue',
  })
  await sleep(6000)
  await client.call('session.cancel', { sessionId })
  log('cancel sent ✓')

  const list = await client.call('host.info', {})
  log(`session list after tests: ${list.sessions.map((s) => `${s.title}(${s.phase})`).join(', ')}`)

  client.close()
  log('ALL SMOKE TESTS PASSED ✅')
  process.exit(0)
}

function waitFor(events, predicate, timeoutMs) {
  return new Promise((resolve, reject) => {
    const started = Date.now()
    const timer = setInterval(() => {
      const hit = events.find(predicate)
      if (hit) {
        clearInterval(timer)
        resolve(hit)
      } else if (Date.now() - started > timeoutMs) {
        clearInterval(timer)
        reject(new Error(`waitFor timed out after ${timeoutMs}ms (${events.length} events seen)`))
      }
    }, 200)
  })
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

main().catch((err) => {
  console.error('[client] FAILED:', err.message)
  process.exit(1)
})
