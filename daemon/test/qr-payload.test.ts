import { describe, expect, it } from 'vitest'
import { pairingQrPayload } from '../src/server.js'

describe('pairingQrPayload', () => {
  it('carries host, port, code and fingerprint in the ccgo://pair shape', () => {
    const payload = pairingQrPayload({
      host: '192.168.1.10',
      port: 8747,
      pairingCode: '654321',
      fingerprint: 'AA:BB:CC',
    })
    expect(payload).toBe('ccgo://pair?host=192.168.1.10&port=8747&code=654321&fingerprint=AA%3ABB%3ACC')
    const url = new URL(payload)
    expect(url.host).toBe('pair')
    expect(url.searchParams.get('host')).toBe('192.168.1.10')
    expect(url.searchParams.get('port')).toBe('8747')
    expect(url.searchParams.get('code')).toBe('654321')
    expect(url.searchParams.get('fingerprint')).toBe('AA:BB:CC')
  })

  it('omits fingerprint in plaintext dev mode', () => {
    const url = new URL(pairingQrPayload({ host: '127.0.0.1', port: 8747, pairingCode: '123456' }))
    expect(url.searchParams.has('fingerprint')).toBe(false)
  })
})
