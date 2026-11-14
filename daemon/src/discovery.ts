/**
 * LAN discovery: advertise the daemon over mDNS as `_ccgo._tcp` so the phone
 * app can offer one-tap pairing (host/port/fingerprint pre-filled from TXT).
 *
 * Only used in LAN-bound TLS mode — `--localhost` (SSH-tunnel mode) and
 * `--no-tls` (plaintext dev mode) must never advertise (see the
 * host-discovery spec), so callers gate on `bindLan && tls`.
 */

import { Bonjour } from 'bonjour-service'

export interface DiscoveryOptions {
  /** Daemon name shown in the phone's discovery list. */
  name: string
  port: number
  /** SHA-256 certificate fingerprint (openssl-style colon hex). */
  fingerprint: string
}

export interface DiscoveryHandle {
  /** Stop advertising; safe to call more than once. */
  stop(): void
}

export function startDiscovery(opts: DiscoveryOptions): DiscoveryHandle {
  const bonjour = new Bonjour()
  const service = bonjour.publish({
    name: opts.name,
    type: 'ccgo',
    port: opts.port,
    txt: { fp: opts.fingerprint },
  })
  let stopped = false
  return {
    stop(): void {
      if (stopped) return
      stopped = true
      service.stop(() => bonjour.destroy())
    },
  }
}
