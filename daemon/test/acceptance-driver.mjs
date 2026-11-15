#!/usr/bin/env node
/**
 * 真机验收驱动：用 daemon store 里已配对的 device token 连上 WS，
 * 在电脑侧造聊天场景（建会话/发任务/应答权限/读转录）。
 *
 * Usage:
 *   node test/acceptance-driver.mjs create                # 建会话，打印 id
 *   node test/acceptance-driver.mjs send <sessionId> <text>
 *   node test/acceptance-driver.mjs items <sessionId>     # 打印转录条目
 *   node test/acceptance-driver.mjs respond <sessionId> <itemId> <allow|deny>
 */
import { readFileSync } from 'node:fs'
import tls from 'node:tls'
import WebSocket from 'ws'

const [, , cmd, sessionId, ...rest] = process.argv
const store = JSON.parse(readFileSync('/Users/luke/.cc-go/store.json', 'utf8'))

function fingerprint() {
  return new Promise((resolve, reject) => {
    const s = tls.connect({ host: '127.0.0.1', port: 8747, rejectUnauthorized: false, servername: undefined }, () => {
      const c = s.getPeerCertificate(); s.end()
      resolve(c.fingerprint256.replace(/:/g, '').toLowerCase())
    })
    s.on('error', reject)
  })
}

const fp = await fingerprint()
const ws = new WebSocket(`wss://127.0.0.1:8747/ws`, { rejectUnauthorized: false })
let nextId = 1
const pending = new Map()

function call(method, params) {
  const id = String(nextId++)
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject })
    ws.send(JSON.stringify({ id, method, params }))
    setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout: ${method}`)) }
    }, 30000)
  })
}

const itemsBySession = new Map()
ws.on('message', (data) => {
  const msg = JSON.parse(data.toString())
  if (msg.id && pending.has(msg.id)) {
    const p = pending.get(msg.id)
    pending.delete(msg.id)
    if (msg.ok) p.resolve(msg.result)
    else p.reject(new Error(msg.error ?? 'rpc error'))
    return
  }
  if (msg.type === 'event') {
    const ev = msg.event
    if (ev.type === 'transcript') {
      const list = itemsBySession.get(ev.sessionId) ?? []
      const idx = list.findIndex((x) => x.id === ev.item.id)
      if (idx >= 0) list[idx] = ev.item
      else list.push(ev.item)
      itemsBySession.set(ev.sessionId, list)
      if (ev.item.kind === 'tool' && ev.item.status === 'awaiting-permission') {
        console.log(`PERMISSION ${ev.sessionId} ${ev.item.id}`)
      }
    } else if (ev.type === 'sessionChanged' || ev.type === 'sessions.changed') {
      // list-level; ignore
    }
  }
})

ws.on('close', (code, reason) => console.error('WS-CLOSE', code, String(reason)))

ws.on('open', async () => {
  try {
    // 逐个尝试已配对 token（拿到的第一个成功的即用）。
    let ok = false
    for (const device of store.devices) {
      try {
        await call('hello', { token: device.token })
        console.error('AUTH-OK device', device.id)
        ok = true
        break
      } catch { /* try next */ }
    }
    if (!ok) throw new Error('no valid device token')
    if (cmd === 'create') {
      const r = await call('session.create', {})
      console.log(JSON.stringify(r.summary))
    } else if (cmd === 'send' && sessionId) {
      await call('session.watch', { sessionId })
      await call('session.prompt', { sessionId, text: rest.join(' ') })
      // 等流式事件到齐（Ctrl+C 提前退出）
      setTimeout(() => process.exit(0), 120000)
    } else if (cmd === 'items' && sessionId) {
      await call('session.watch', { sessionId })
      setTimeout(() => {
        for (const item of itemsBySession.get(sessionId) ?? []) {
          console.log(`${item.kind}/${item.status} ${item.id} ${JSON.stringify((item.text ?? item.summary ?? '').slice(0, 80))}`)
        }
        process.exit(0)
      }, 2000)
    } else if (cmd === 'respond' && sessionId && rest[0]) {
      await call('permission.respond', {
        sessionId, itemId: rest[0], allow: rest[1] !== 'deny', allowToolForSession: false,
      })
      console.log('responded')
      process.exit(0)
    } else {
      console.log('usage: create | send <sid> <text> | items <sid> | respond <sid> <itemId> <allow|deny>')
      process.exit(1)
    }
  } catch (e) {
    console.error('DRIVER-ERROR', e.message)
    process.exit(1)
  }
})
ws.on('error', (e) => { console.error('WS-ERROR', e.message); process.exit(1) })
