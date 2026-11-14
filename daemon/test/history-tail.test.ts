/**
 * History-tail behavior (multi-project-history D6): external writes to a
 * session's transcript merge into the item list with uuid/callId dedupe and
 * echo suppression; partial lines wait for their newline; a terminal fork
 * (new transcript file) is followed without duplicating copied history.
 */

import { appendFileSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { Session } from '../src/agent/session.js'
import { collectHistory, encodeCwd } from '../src/history.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-tail-test-'))
  dirs.push(dir)
  return dir
}

const SID = '12345678-abcd-4abc-8abc-aaaaaaaaaaaa'
const SID2 = '12345678-abcd-4abc-8abc-bbbbbbbbbbbb'

let configDir: string
let projectDir: string
let transcriptDir: string

const line = (obj: unknown) => `${JSON.stringify(obj)}\n`
const userLine = (uuid: string, text: string) =>
  line({ type: 'user', uuid, timestamp: new Date().toISOString(), message: { role: 'user', content: text } })
const assistantLine = (uuid: string, text: string) =>
  line({
    type: 'assistant',
    uuid,
    timestamp: new Date().toISOString(),
    message: { role: 'assistant', content: [{ type: 'text', text }] },
  })

function newSession(sid: string): Session {
  const session = new Session({ onEvent: () => {}, onSummary: () => {} }, { cwd: projectDir })
  session.claudeSessionId = sid
  return session
}

async function waitFor(predicate: () => boolean, timeoutMs = 8000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 200))
  }
}

beforeAll(() => {
  configDir = tempDir()
  projectDir = tempDir()
  process.env.CLAUDE_CONFIG_DIR = configDir
  transcriptDir = join(configDir, 'projects', encodeCwd(projectDir))
  mkdirSync(transcriptDir, { recursive: true })
})

afterAll(() => {
  delete process.env.CLAUDE_CONFIG_DIR
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

describe('history tail', () => {
  it('merges external writes, suppresses echoes, buffers partial lines', async () => {
    const file = join(transcriptDir, `${SID}.jsonl`)
    writeFileSync(file, userLine('u1', '先前的外部问题') + assistantLine('a1', '先前的回复'))

    const session = newSession(SID)
    session.seedHistoryItems(await collectHistory(SID, projectDir))
    // simulate what the phone already sent/received through the daemon
    session.seedHistoryItems([
      { kind: 'user', id: 'live-u1', text: '手机发的话', source: 'phone', createdAt: Date.now() },
      { kind: 'assistant', id: 'live-a1', text: '流式回答', thinking: '', status: 'done', createdAt: Date.now() },
    ])
    session.startHistoryTail()
    try {
      // external writes: our echo + genuine terminal traffic + a tool pair
      appendFileSync(
        file,
        userLine('u2', '手机发的话') + // echo of the phone prompt → suppressed
          assistantLine('a2', '流式回答') + // SDK already streamed this → suppressed
          userLine('u3', '终端里新说的话') +
          assistantLine('a3', '终端里的回答'),
      )
      // half a line: no trailing newline yet → must wait
      appendFileSync(file, JSON.stringify({ type: 'user', uuid: 'u4' }).slice(0, 20))

      await waitFor(() => session.snapshot().items.some((i) => i.kind === 'user' && i.text === '终端里新说的话'))
      const texts = session.snapshot().items.filter((i) => i.kind === 'user' || i.kind === 'assistant')
      expect(texts.filter((i) => i.text === '手机发的话')).toHaveLength(1) // echo suppressed
      expect(texts.filter((i) => i.text === '流式回答')).toHaveLength(1) // duplicate suppressed
      expect(texts.some((i) => i.text === '终端里新的回答' || i.text === '终端里的回答')).toBe(true)
      expect(texts.some((i) => i.kind === 'assistant' && i.text === '终端里的回答')).toBe(true)

      // complete the partial line → it merges on a later poll
      appendFileSync(file, `${JSON.stringify({ type: 'user', uuid: 'u4', timestamp: new Date().toISOString(), message: { role: 'user', content: '补全的半行' } }).slice(20)}\n`)
      await waitFor(() => session.snapshot().items.some((i) => i.kind === 'user' && i.text === '补全的半行'))
    } finally {
      session.dispose()
    }
  }, 15_000)

  it('follows a terminal fork without duplicating copied history', async () => {
    const file = join(transcriptDir, `${SID}.jsonl`)
    writeFileSync(file, userLine('f1', '原始对话') + assistantLine('f2', '原始回答'))

    const session = newSession(SID)
    session.seedHistoryItems(await collectHistory(SID, projectDir))
    session.startHistoryTail()
    try {
      // startHistoryTail's first poll runs synchronously, so the current
      // file's size is already recorded — the fork gate is armed.

      // terminal --resume forks under a new id; the copy keeps the same uuids
      const fork = join(transcriptDir, `${SID2}.jsonl`)
      writeFileSync(fork, userLine('f1', '原始对话') + assistantLine('f2', '原始回答') + userLine('f3', 'fork 后的新消息'))
      const newer = Date.now() / 1000 + 60
      utimesSync(fork, newer, newer)

      await waitFor(() => session.claudeSessionId === SID2, 10_000)
      await waitFor(() => session.snapshot().items.some((i) => i.kind === 'user' && i.text === 'fork 后的新消息'))

      const users = session.snapshot().items.filter((i) => i.kind === 'user')
      expect(users.filter((i) => i.text === '原始对话')).toHaveLength(1) // copied line deduped by uuid
      expect(users.some((i) => i.text === 'fork 后的新消息')).toBe(true)
    } finally {
      session.dispose()
    }
  }, 15_000)
})
