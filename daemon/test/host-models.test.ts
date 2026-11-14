// task 4.1：host.models 三级降级链 —— init 缓存命中 → 活会话直取 →
// 短命探测 → 空目录（旧 CLI）。探测会话工厂注入假实现，不启动 CLI。
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { Store } from '../src/store.js'
import { SessionManager } from '../src/agent/manager.js'
import { Session } from '../src/agent/session.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-models-test-'))
  dirs.push(dir)
  return dir
}

function newManager(): SessionManager {
  return new SessionManager(new Store(tempDir()))
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

const catalogA = { models: [{ id: 'claude-opus-5', displayName: 'Opus 5' }], current: 'claude-opus-5' }

/** 只实现 hostModels 路径用到的两个方法的假 Session。 */
function fakeSession(overrides: Partial<Pick<Session, 'tryLiveModels' | 'probeModels'>>): Session {
  return overrides as unknown as Session
}

describe('host.models 降级链', () => {
  it('第一级：缓存命中直接返回，不做探测', async () => {
    const manager = newManager()
    // 先经活会话路径填缓存（headless 下 init 的 supportedModels 不会触发，
    // currentQuery 为 null；真实环境里 init 即此来源）。
    const session = manager.create({ cwd: tempDir() })
    ;(session as unknown as { tryLiveModels: () => Promise<typeof catalogA | null> }).tryLiveModels =
      async () => catalogA
    await manager.hostModels()
    manager.dispose(session.id)

    let probed = false
    manager.probeSessionFactory = () => {
      probed = true
      return fakeSession({ probeModels: async () => catalogA })
    }
    const result = await manager.hostModels()
    expect(result).toEqual(catalogA)
    expect(probed).toBe(false, '缓存命中不应触发探测')
  })

  it('第二级：活会话直取（tryLiveModels）', async () => {
    const manager = newManager()
    const session = manager.create({ cwd: tempDir() })
    ;(session as unknown as { tryLiveModels: () => Promise<typeof catalogA | null> }).tryLiveModels =
      async () => catalogA
    const result = await manager.hostModels()
    expect(result).toEqual(catalogA)
    expect(manager.models).toEqual(catalogA, '结果回填缓存')
  })

  it('第三级：无缓存无活会话 → 短命探测', async () => {
    const manager = newManager()
    manager.probeSessionFactory = () => fakeSession({ probeModels: async () => catalogA })
    const result = await manager.hostModels()
    expect(result).toEqual(catalogA)
  })

  it('旧 CLI 降级：探测返回空目录', async () => {
    const manager = newManager()
    manager.probeSessionFactory = () =>
      fakeSession({ probeModels: async () => ({ models: [], current: 'claude-sonnet-5' }) })
    const result = await manager.hostModels()
    expect(result.models).toEqual([])
    expect(result.current).toBe('claude-sonnet-5')
    // 空目录不进缓存：后续请求仍可探测恢复。
    expect(manager.models).toBeNull()
  })

  it('活会话返回空目录不钉缓存，落到探测（评审回归）', async () => {
    const manager = newManager()
    const session = manager.create({ cwd: tempDir() })
    ;(session as unknown as { tryLiveModels: () => Promise<{ models: never[]; current: string }> }).tryLiveModels =
      async () => ({ models: [], current: 'claude-sonnet-5' })
    manager.probeSessionFactory = () => fakeSession({ probeModels: async () => catalogA })
    const result = await manager.hostModels()
    expect(result).toEqual(catalogA, '空 live 结果视为未命中，探测兜底')
    expect(manager.models).toEqual(catalogA)
  })

  it('活会话卡死在限时内放行，落到探测（评审回归）', async () => {
    const manager = newManager()
    const session = manager.create({ cwd: tempDir() })
    ;(session as unknown as { tryLiveModels: () => Promise<never> }).tryLiveModels =
      () => new Promise(() => {}) // 永不 settle
    manager.probeSessionFactory = () => fakeSession({ probeModels: async () => catalogA })
    const result = await manager.hostModels()
    expect(result).toEqual(catalogA)
  })

  it('探测超时/失败：空目录且 current 为 null', async () => {
    const manager = newManager()
    manager.probeSessionFactory = () => fakeSession({ probeModels: async () => null })
    const result = await manager.hostModels()
    expect(result).toEqual({ models: [], current: null })
  })
})
