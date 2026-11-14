import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { Store } from '../src/store.js'
import { SessionManager } from '../src/agent/manager.js'
import { encodeCwd } from '../src/history.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-import-test-'))
  dirs.push(dir)
  return dir
}

const SID = 'aaaaaaaa-bbbb-4ccc-8ddd-111111111111'

let configDir: string
let projectDir: string
let transcriptFile: string

/** Each test gets an isolated store dir so persisted sessions can't leak
 *  between tests (the registry/store is shared state by design). */
function newManager(): { manager: SessionManager; store: Store } {
  const store = new Store(tempDir())
  return { manager: new SessionManager(store), store }
}

function writeFixture(): void {
  const dir = join(configDir, 'projects', encodeCwd(projectDir))
  mkdirSync(dir, { recursive: true })
  transcriptFile = join(dir, `${SID}.jsonl`)
  writeFileSync(
    transcriptFile,
    [
      JSON.stringify({ type: 'user', uuid: 'u1', timestamp: '2026-11-14T01:00:00.000Z', message: { role: 'user', content: '修复登录页的 bug' } }),
      JSON.stringify({
        type: 'assistant',
        uuid: 'a1',
        timestamp: '2026-11-14T01:00:02.000Z',
        message: { role: 'assistant', content: [{ type: 'text', text: '我来看一下相关代码。' }] },
      }),
    ].join('\n') + '\n',
  )
}

function sha(file: string): string {
  return createHash('sha256').update(readFileSync(file)).digest('hex')
}

beforeAll(() => {
  configDir = tempDir()
  projectDir = tempDir()
  process.env.CLAUDE_CONFIG_DIR = configDir
  writeFixture()
})

afterAll(() => {
  delete process.env.CLAUDE_CONFIG_DIR
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

describe('SessionManager.importSession', () => {
  it('imports with pre-filled history, derived title and resume link', async () => {
    const { manager, store } = newManager()
    const before = sha(transcriptFile)

    const session = await manager.importSession(SID, projectDir)

    expect(session.claudeSessionId).toBe(SID)
    expect(session.origin).toBe('imported')
    expect(session.title).toBe('修复登录页的 bug')
    const snapshot = session.snapshot()
    expect(snapshot.items.map((i) => i.kind)).toEqual(['user', 'assistant'])
    // persisted summary keeps the resume link so restarts reseed history
    const persisted = store.listSessions().find((s) => s.id === session.id)
    expect(persisted).toMatchObject({ claudeSessionId: SID, origin: 'imported', cwd: projectDir })
    // the original transcript is never modified
    expect(sha(transcriptFile)).toBe(before)
  })

  it('is idempotent per claudeSessionId', async () => {
    const { manager } = newManager()
    const first = await manager.importSession(SID, projectDir)
    const second = await manager.importSession(SID, projectDir)
    expect(second.id).toBe(first.id)
    expect(manager.list().filter((s) => s.claudeSessionId === SID)).toHaveLength(1)
  })

  it('stays idempotent after Claude forks the session id (originClaudeSessionId)', async () => {
    const { manager } = newManager()
    const first = await manager.importSession(SID, projectDir)
    expect(first.originClaudeSessionId).toBe(SID)

    // simulate the SDK resume fork: trackClaudeSession rewrote the live id
    first.claudeSessionId = '99999999-9999-4999-8999-111111111111'
    first.configure({})

    const again = await manager.importSession(SID, projectDir)
    expect(again.id).toBe(first.id)
    expect(manager.list()).toHaveLength(1)
    // discovery's managed map keys off the origin id too (server-side)
    const persisted = manager.list().find((s) => s.id === first.id)
    expect(persisted?.originClaudeSessionId).toBe(SID)
  })

  it('rejects an unknown session before creating anything', async () => {
    const { manager } = newManager()
    await expect(
      manager.importSession('99999999-9999-4999-8999-999999999999', projectDir),
    ).rejects.toMatchObject({ code: 'not_found' })
    expect(manager.list()).toHaveLength(0)
  })

  it('reseeds history when an imported session is rehydrated after restart', async () => {
    const { manager: managerA, store } = newManager()
    const imported = await managerA.importSession(SID, projectDir)
    const summary = imported.summary()
    managerA.disposeAll()

    const managerB = new SessionManager(new Store(store.dir))
    const rehydrated = managerB.ensureLive(summary.id)
    expect(rehydrated).toBeDefined()

    // reseed is async (file replay) — poll until the items land
    const deadline = Date.now() + 2000
    while (Date.now() < deadline) {
      if (rehydrated!.snapshot().items.length >= 2) break
      await new Promise((r) => setTimeout(r, 25))
    }
    const items = rehydrated!.snapshot().items
    expect(items.map((i) => i.kind)).toEqual(['user', 'assistant'])
    expect(items[0]).toMatchObject({ id: `hist-${SID}-u1` })
    // no cold-start notice for imported sessions
    expect(items.some((i) => i.kind === 'notice')).toBe(false)
  })
})
