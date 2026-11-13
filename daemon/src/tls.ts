/**
 * TLS material for the daemon — a self-signed certificate generated on first
 * run, persisted under the store dir, and reused forever after.
 *
 * Clients (phone app, smoke client) pin the certificate's SHA-256 fingerprint
 * on first connection (trust on first use, the SSH model) and fail closed when
 * it changes. The fingerprint format matches `openssl x509 -fingerprint
 * -sha256`: colon-separated uppercase hex.
 */

import { X509Certificate } from 'node:crypto'
import { chmodSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { generate } from 'selfsigned'

export interface TlsMaterial {
  /** Certificate PEM. */
  cert: string
  /** Private key PEM. */
  key: string
  /** SHA-256 fingerprint of the cert DER, openssl-style colon hex. */
  fingerprint: string
}

const CERT_FILE = 'tls-cert.pem'
const KEY_FILE = 'tls-key.pem'
const VALIDITY_MS = 3650 * 24 * 3600 * 1000 // 10 years — personal cert, pinned by fingerprint

/** Load the persisted cert/key from `dir`, generating and saving on first run. */
export async function ensureTlsMaterial(dir: string): Promise<TlsMaterial> {
  const certPath = join(dir, CERT_FILE)
  const keyPath = join(dir, KEY_FILE)

  if (existsSync(certPath) && existsSync(keyPath)) {
    const cert = readFileSync(certPath, 'utf8')
    const key = readFileSync(keyPath, 'utf8')
    return { cert, key, fingerprint: fingerprintOf(cert) }
  }

  const now = new Date()
  const pems = await generate([{ name: 'commonName', value: 'cc-go' }], {
    keyType: 'ec',
    curve: 'P-256',
    algorithm: 'sha256',
    notBeforeDate: now,
    notAfterDate: new Date(now.getTime() + VALIDITY_MS),
  })
  writeFileSync(certPath, pems.cert, { mode: 0o600 })
  writeFileSync(keyPath, pems.private, { mode: 0o600 })
  chmodSync(certPath, 0o600)
  chmodSync(keyPath, 0o600)
  return { cert: pems.cert, key: pems.private, fingerprint: fingerprintOf(pems.cert) }
}

/** SHA-256 fingerprint of a PEM certificate, `openssl x509 -fingerprint -sha256` style. */
export function fingerprintOf(certPem: string): string {
  return new X509Certificate(certPem).fingerprint256
}
