import { describe, expect, it } from 'vitest'
import { Bonjour } from 'bonjour-service'
import { startDiscovery } from '../src/discovery.js'

// In-process multicast round trip: publish `_ccgo._tcp` and browse it back
// with the TXT fingerprint. mDNS on the loopback interface is normally
// available on dev machines; if the network stack swallows multicast the
// browse times out and the test fails loudly (the advert itself is still
// exercised).
describe('startDiscovery', () => {
  it('advertises _ccgo._tcp with the cert fingerprint in TXT', async () => {
    const handle = startDiscovery({
      name: 'ccgo-test-host',
      port: 8747,
      fingerprint: 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
    })

    try {
      const found = await new Promise<Record<string, any>>((resolve, reject) => {
        const browser = new Bonjour().find({ type: 'ccgo' }, (service: any) => {
          if (service.name !== 'ccgo-test-host') return
          ;(browser as any)?.stop?.()
          resolve(service)
        })
        setTimeout(() => reject(new Error('mDNS browse timed out')), 8000)
      })
      expect(found.port).toBe(8747)
      expect(found.txt?.fp).toContain('AA:BB:CC')
    } finally {
      handle.stop()
    }
  }, 15_000)

  it('stop is idempotent', () => {
    const handle = startDiscovery({ name: 'ccgo-stop-twice', port: 1, fingerprint: 'FF' })
    handle.stop()
    expect(() => handle.stop()).not.toThrow()
  })
})
