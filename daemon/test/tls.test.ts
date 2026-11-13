import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { X509Certificate } from 'node:crypto'
import { ensureTlsMaterial, fingerprintOf } from '../src/tls.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-tls-test-'))
  dirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

describe('ensureTlsMaterial', () => {
  it('generates on first run and reuses the same cert afterwards', async () => {
    const dir = tempDir()
    const first = await ensureTlsMaterial(dir)
    const second = await ensureTlsMaterial(dir)

    expect(existsSync(join(dir, 'tls-cert.pem'))).toBe(true)
    expect(existsSync(join(dir, 'tls-key.pem'))).toBe(true)
    expect(second.cert).toBe(first.cert)
    expect(second.key).toBe(first.key)
    expect(second.fingerprint).toBe(first.fingerprint)
  })

  it('regenerates when the certificate file is missing', async () => {
    const dir = tempDir()
    const first = await ensureTlsMaterial(dir)
    unlinkSync(join(dir, 'tls-cert.pem'))
    const second = await ensureTlsMaterial(dir)

    expect(second.fingerprint).not.toBe(first.fingerprint)
  })

  it('fingerprint is openssl-style sha256 colon hex of the cert', async () => {
    const dir = tempDir()
    const material = await ensureTlsMaterial(dir)

    expect(material.fingerprint).toMatch(/^[0-9A-F]{2}(:[0-9A-F]{2}){31}$/)
    const cert = new X509Certificate(readFileSync(join(dir, 'tls-cert.pem'), 'utf8'))
    expect(cert.fingerprint256).toBe(material.fingerprint)
    expect(cert.validTo).toBeTruthy()
  })

  it('fingerprintOf derives the same value from a bare PEM', async () => {
    const dir = tempDir()
    const material = await ensureTlsMaterial(dir)
    writeFileSync(join(dir, 'copy.pem'), material.cert)
    expect(fingerprintOf(readFileSync(join(dir, 'copy.pem'), 'utf8'))).toBe(material.fingerprint)
  })
})
