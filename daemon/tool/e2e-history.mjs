#!/usr/bin/env node
/**
 * End-to-end verification for multi-project-history (task 5.1):
 *
 *   temp project dir → register via --project → real `claude -p` creates a
 *   TERMINAL session in it → phone pairs → projects.list → sessions.discover
 *   sees the terminal session → session.history replays it → session.import
 *   takes it over → a prompt sent over the protocol gets an answer that
 *   proves the original context survived (the secret from turn one).
 *
 * Repeatable: fresh temp dir + its own ~/.claude/projects subdirectory each
 * run; nothing from previous runs is reused. Requires the `claude` CLI on
 * PATH and authenticated, and `npm run build` up to date.
 *
 * Usage (from daemon/):
 *   node tool/e2e-history.mjs [--port 8751] [--code 654321]
 */

import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import http from 'node:http'
import WebSocket from 'ws'

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : fallback
}
const PORT = Number(flag('--port', 8751))
const CODE = flag('--code', '654321')
const HOST = '127.0.0.1'
const SECRET = 'pomegranate-42'

const log = (...a) => console.log('[e2e]', ...a)
const fail = (msg) => {
  console.error(`[e2e] FAIL: ${msg}`)
  process.exitCode = 1
  throw new Error(msg)
}
let step = 0
const ok = (msg) => log(`ok ${++step} - ${msg}`)

// ---------------------------------------------------------------------------
// 1. temp project + daemon with --project
// ---------------------------------------------------------------------------

const TMP = mkdtempSync(join(tmpdir(), 'ccgo-e2e-'))
const PROJ = join(TMP, 'proj')
mkdirSync(PROJ, { recursive: true })

const daemon = spawn(process.execPath, ['bin/cc-go.mjs', '--project', PROJ, '--code', CODE, '--no-tls', '--port', String(PORT)], {
  cwd: resolve(import.meta.dirname, '..'),
  stdio: ['ignore', 'pipe', 'pipe'],
  detached: true, // own process group: the claude CLI can signal-kill its
  // subprocess tree on exit, and a shared group would take the daemon down
})
daemon.stdout.on('data', () => {})
daemon.stderr.on('data', (d) => process.stderr.write(`[daemon] ${d}`))
daemon.on('exit', (code, sig) => console.error(`[e2e] daemon exited code=${code} sig=${sig}`))

async function waitForHealth() {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await get(`/health`)
      if (res.includes('"ok":true')) return
    } catch { /* not up yet */ }
    await sleep(500)
  }
  fail('daemon did not become healthy')
}

function get(path) {
  return new Promise((resolvePromise, reject) => {
    const req = http.get({ host: HOST, port: PORT, path }, (res) => {
      let body = ''
      res.on('data', (c) => (body += c))
      res.on('end', () => resolvePromise(body))
    })
    req.on('error', reject)
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Run the claude CLI without execFileSync's event-loop freeze (a frozen
 *  parent once correlated with the daemon child dying to a stray SIGTERM). */
function runClaude(args) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn('claude', args, { cwd: PROJ, stdio: ['ignore', 'pipe', 'pipe'] })
    let out = ''
    child.stdout.on('data', (c) => (out += c))
    child.stderr.on('data', (c) => (out += c))
    child.on('error', rejectPromise)
    child.on('close', (code) => (code === 0 ? resolvePromise(out) : rejectPromise(new Error(`claude exited ${code}: ${out.slice(0, 300)}`))))
    setTimeout(() => { child.kill('SIGTERM'); rejectPromise(new Error('claude timed out')) }, 180_000).unref()
  })
}

// ---------------------------------------------------------------------------
// 2. a REAL terminal session via the claude CLI
// ---------------------------------------------------------------------------

async function makeTerminalSession() {
  await runClaude(['-p', `请记住暗号：${SECRET}。现在只回复 ack。`])
  const encoded = resolve(PROJ).replace(/[^a-zA-Z0-9-]/g, '-')
  const dir = join(process.env.CLAUDE_CONFIG_DIR ?? join(process.env.HOME, '.claude'), 'projects', encoded)
  if (!existsSync(dir)) fail(`no claude projects dir at ${dir}`)
  const jsonls = readdirSync(dir).filter((f) => f.endsWith('.jsonl'))
  if (jsonls.length === 0) fail('no transcript written by claude CLI')
  const newest = jsonls
    .map((f) => ({ f, mtime: statSync(join(dir, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)[0].f
  const sid = newest.replace(/\.jsonl$/, '')
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sid)) {
    fail(`transcript name is not a session id: ${newest}`)
  }
  return sid
}

// ---------------------------------------------------------------------------
// 3. phone: pair + websocket client with a tiny rpc helper
// ---------------------------------------------------------------------------

async function pair() {
  return new Promise((resolvePromise, reject) => {
    const body = JSON.stringify({ code: CODE, name: 'e2e' })
    const req = http.request(
      { host: HOST, port: PORT, path: '/pair', method: 'POST', headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } },
      (res) => {
        let out = ''
        res.on('data', (c) => (out += c))
        res.on('end', () => resolvePromise(JSON.parse(out)))
      },
    )
    req.on('error', reject)
    req.end(body)
  })
}

const items = new Map() // itemId -> item (merged from snapshot + events)

function openSocket(token) {
  return new Promise((resolvePromise, reject) => {
    const ws = new WebSocket(`ws://${HOST}:${PORT}/ws`)
    const pending = new Map()
    ws.on('message', (data) => {
      const frame = JSON.parse(String(data))
      if (frame.id !== undefined && pending.has(frame.id)) {
        pending.get(frame.id)(frame)
        pending.delete(frame.id)
        return
      }
      if (frame.type === 'event' && frame.event?.type === 'session') {
        const ev = frame.event.event
        if (ev.ev === 'snapshot') for (const it of ev.items) items.set(it.id, it)
        if (ev.ev === 'item.added' || ev.ev === 'item.updated') items.set(ev.item.id, ev.item)
      }
    })
    ws.rpc = (method, params = {}) =>
      new Promise((resolveCall, rejectCall) => {
        const id = `r${pending.size + 1}-${method}`
        pending.set(id, resolveCall)
        ws.send(JSON.stringify({ id, method, params }))
        setTimeout(() => {
          if (pending.has(id)) {
            pending.delete(id)
            rejectCall(new Error(`rpc ${method} timed out`))
          }
        }, 60_000).unref()
      })
    ws.on('open', async () => {
      try {
        const hello = await ws.rpc('hello', { token })
        if (!hello.ok) throw new Error('hello rejected')
        resolvePromise(ws)
      } catch (err) { rejectCall(err); reject(err) }
    })
    ws.on('error', reject)
  })
}

// ---------------------------------------------------------------------------
// the scenario
// ---------------------------------------------------------------------------

async function main() {
  await waitForHealth()
  ok('daemon up with --project registered')

  const sid = await makeTerminalSession()
  ok(`terminal session created by claude CLI: ${sid}`)

  const { token } = await pair()
  ok('paired over /pair')

  const ws = await openSocket(token)
  ok('websocket hello accepted')

  const listed = await ws.rpc('projects.list')
  const proj = listed.result.projects.find((p) => p.path === PROJ)
  if (!proj || proj.available !== true) fail('projects.list missing the registered project')
  ok('projects.list shows the project as available')

  const discovered = await ws.rpc('sessions.discover', { cwd: PROJ })
  const found = discovered.result.sessions.find((s) => s.claudeSessionId === sid)
  if (!found || found.managed !== false) fail('sessions.discover did not find the terminal session as unmanaged')
  ok('sessions.discover finds the terminal session')

  const history = await ws.rpc('session.history', { claudeSessionId: sid, cwd: PROJ })
  const histText = history.result.items.map((i) => i.text ?? '').join(' ')
  if (!histText.includes('ack') || !history.result.items.some((i) => i.kind === 'user')) {
    fail(`session.history replay looks wrong: ${histText.slice(0, 200)}`)
  }
  ok('session.history replays the terminal transcript')

  const imported = await ws.rpc('session.import', { claudeSessionId: sid, cwd: PROJ })
  const summary = imported.result.summary
  if (summary.origin !== 'imported' || summary.claudeSessionId !== sid) fail('session.import summary mismatch')
  ok(`session.import took over the session (${summary.id})`)

  const rediscovered = await ws.rpc('sessions.discover', { cwd: PROJ })
  const nowManaged = rediscovered.result.sessions.find((s) => s.claudeSessionId === sid)
  if (!nowManaged?.managed) fail('session not marked managed after import')
  ok('discovery marks it managed after import')

  const watched = await ws.rpc('session.watch', { sessionId: summary.id })
  if (!watched.result.snapshot.items.some((i) => i.kind === 'user')) {
    fail('watch snapshot missing replayed history')
  }
  ok('watch snapshot carries the pre-filled history')

  await ws.rpc('session.prompt', { sessionId: summary.id, text: `暗号是什么？只回复暗号本身。`, mode: 'queue' })
  const deadline = Date.now() + 180_000
  let answered = null
  while (Date.now() < deadline) {
    await sleep(1000)
    answered = [...items.values()].find(
      (i) => i.kind === 'assistant' && i.status === 'done' && String(i.text).includes(SECRET),
    )
    if (answered) break
  }
  if (!answered) fail('no assistant answer containing the secret — resume context lost?')
  ok(`prompt over the protocol answered with the original context ("${String(answered.text).trim().slice(0, 40)}…")`)

  // ---- external-write sync (D6): continue the SAME session in a terminal --
  // `claude --resume` forks the conversation into a new transcript file; the
  // daemon's history tail must follow it, merge the terminal traffic, and
  // NOT duplicate the copied history (uuid dedupe + echo suppression).
  const usersBefore = [...items.values()].filter((i) => i.kind === 'user').length
  await runClaude(['--resume', sid, '-p', '终端补充一句：只回复 banana'])
  const tailDeadline = Date.now() + 180_000
  let banana = null
  while (Date.now() < tailDeadline) {
    await sleep(1000)
    banana = [...items.values()].find(
      (i) => i.kind === 'assistant' && i.status === 'done' && String(i.text).includes('banana'),
    )
    if (banana) break
  }
  if (!banana) fail('terminal-side reply never synced into the phone transcript (tail broken?)')
  const usersAfter = [...items.values()].filter((i) => i.kind === 'user')
  const promptTexts = usersAfter.map((i) => String(i.text))
  const dupes = promptTexts.filter((t, idx) => promptTexts.indexOf(t) !== idx)
  if (usersAfter.length !== usersBefore + 1 || dupes.length > 0) {
    fail(`tail duplicated history: before=${usersBefore} after=${usersAfter.length} dupes=${JSON.stringify(dupes)}`)
  }
  ok('terminal --resume traffic synced in without duplicating history')

  await ws.rpc('session.delete', { sessionId: summary.id })
  ok('cleanup: session deleted')

  ws.close()
  log('ALL PASS')
}

main()
  .catch((err) => {
    console.error('[e2e] unexpected error:', err instanceof Error ? err.stack : err)
    process.exitCode = 1
  })
  .finally(async () => {
    daemon.kill('SIGTERM') // detached ⇒ kills the pid, not our group
    // let the daemon finish its exit-time store writes before cleanup
    await Promise.race([new Promise((r) => daemon.once('exit', r)), sleep(2000)])
    rmSync(TMP, { recursive: true, force: true })
    // the run registered its temp project (and a pairing device) in the real
    // ~/.cc-go store — remove both so repeated runs leave nothing behind
    try {
      const storeFile = join(process.env.HOME, '.cc-go', 'store.json')
      const store = JSON.parse(readFileSync(storeFile, 'utf8'))
      let dirty = false
      if (Array.isArray(store.projects) && store.projects.includes(PROJ)) {
        store.projects = store.projects.filter((p) => p !== PROJ)
        dirty = true
      }
      if (Array.isArray(store.devices)) {
        const kept = store.devices.filter((d) => d?.name !== 'e2e')
        if (kept.length !== store.devices.length) {
          store.devices = kept
          dirty = true
        }
      }
      if (dirty) writeFileSync(storeFile, JSON.stringify(store, null, 2))
    } catch { /* nothing to clean */ }
    setTimeout(() => process.exit(process.exitCode ?? 0), 500)
  })
