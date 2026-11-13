/**
 * cc-go daemon entrypoint.
 *
 * Usage:
 *   cc-go [--port 8747] [--localhost] [--name <name>] [--code <code>] [--no-tls]
 *
 *   --port       WebSocket port (default 8747)
 *   --localhost  bind 127.0.0.1 only — pair over an SSH tunnel instead of LAN
 *   --name       host name shown on the phone
 *   --code       fixed 6-digit pairing code (default: generated at startup)
 *   --no-tls     PLAINTEXT dev mode — loopback only, for local debugging
 */

import { randomInt } from 'node:crypto'
import { Store } from './store.js'
import { SessionManager } from './agent/manager.js'
import { startDaemon } from './server.js'
import { ensureTlsMaterial } from './tls.js'

const VERSION = '0.1.0'

function parseArgs(argv: string[]): { port: number; localhost: boolean; noTls: boolean; name?: string; code?: string } {
  const args: { port: number; localhost: boolean; noTls: boolean; name?: string; code?: string } = {
    port: 8747,
    localhost: false,
    noTls: false,
  }
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i]
    const next = argv[i + 1]
    if (arg === '--port' || arg === '-p') {
      args.port = Number(next)
      i++
    } else if (arg === '--localhost' || arg === '-l') {
      args.localhost = true
    } else if (arg === '--no-tls') {
      args.noTls = true
    } else if (arg === '--name' || arg === '-n') {
      args.name = next
      i++
    } else if (arg === '--code' || arg === '-c') {
      args.code = next
      i++
    } else if (arg === '--help' || arg === '-h') {
      console.log('cc-go daemon — remote-control Claude Code from your phone\n')
      console.log('  --port, -p <n>     WebSocket port (default 8747)')
      console.log('  --localhost, -l    bind 127.0.0.1 only (SSH-tunnel mode)')
      console.log('  --name, -n <s>     host name shown on the phone')
      console.log('  --code, -c <s>     fixed pairing code (default: random 6 digits)')
      console.log('  --no-tls           plaintext dev mode (forces loopback binding)')
      process.exit(0)
    } else {
      console.error(`unknown argument: ${arg}`)
      process.exit(1)
    }
  }
  return args
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv)
  const store = new Store()
  if (args.name) store.setDaemonName(args.name)

  const manager = new SessionManager(store)
  const pairingCode = args.code ?? String(randomInt(100_000, 1_000_000))

  // TLS is the default; plaintext survives only as an explicit loopback-only dev mode.
  const tls = args.noTls ? undefined : await ensureTlsMaterial(store.dir)

  const server = startDaemon(manager, store, {
    port: args.port,
    bindLan: !args.localhost && !args.noTls,
    pairingCode,
    version: VERSION,
    tls,
  })

  const shutdown = (): void => {
    manager.disposeAll()
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 1500).unref()
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}

void main()
