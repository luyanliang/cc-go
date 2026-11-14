import { mkdtempSync, rmSync, symlinkSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { Store } from '../src/store.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-store-test-'))
  dirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

describe('project registry', () => {
  it('persists projects and round-trips them across Store instances', () => {
    const home = tempDir()
    const project = tempDir()

    const store = new Store(home)
    store.addProject(project)
    const reopened = new Store(home)

    expect(reopened.listProjects()).toEqual([store.canonicalProjectPath(project)])
  })

  it('defaults to an empty registry when loading a legacy store.json without projects', () => {
    const home = tempDir()
    writeFileSync(
      join(home, 'store.json'),
      JSON.stringify({ daemonId: 'd', daemonName: 'n', devices: [], sessions: [] }),
    )

    expect(new Store(home).listProjects()).toEqual([])
  })

  it('dedupes registrations that canonicalize to the same path (symlink alias)', () => {
    const home = tempDir()
    const project = tempDir()
    const alias = join(home, 'alias')
    symlinkSync(project, alias, 'dir')

    const store = new Store(home)
    store.addProject(project)
    store.addProject(alias)

    expect(store.listProjects()).toHaveLength(1)
  })

  it('matches whitelist checks through `..` segments and symlinks', () => {
    const home = tempDir()
    const project = tempDir()
    const alias = join(home, 'alias')
    symlinkSync(project, alias, 'dir')

    const store = new Store(home)
    store.addProject(project)

    const dotdot = `${join(project, 'sub', '..')}/.`
    expect(store.hasProject(dotdot)).toBe(true)
    expect(store.hasProject(alias)).toBe(true)
    expect(store.hasProject('/tmp')).toBe(false)
  })

  it('removes a registered project by any of its canonical aliases', () => {
    const home = tempDir()
    const project = tempDir()
    const alias = join(home, 'alias')
    symlinkSync(project, alias, 'dir')

    const store = new Store(home)
    store.addProject(alias)
    store.removeProject(project)

    expect(store.listProjects()).toEqual([])
    expect(readFileSync(join(home, 'store.json'), 'utf8')).toContain('"projects": []')
  })
})
