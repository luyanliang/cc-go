/**
 * cc-go daemon entrypoint.
 *
 * Usage:
 *   cc-go [--port 8747] [--localhost] [--name <name>] [--code <code>] [--no-tls]
 *         [--project <dir> ...]
 *
 *   --port       WebSocket port (default 8747)
 *   --localhost  bind 127.0.0.1 only — pair over an SSH tunnel instead of LAN
 *   --name       host name shown on the phone
 *   --code       fixed 6-digit pairing code (default: generated at startup)
 *   --no-tls     PLAINTEXT dev mode — loopback only, for local debugging
 *   --project    register a project directory (repeatable). Directories are a
 *                whitelist: sessions may only be created / discovered /
 *                imported inside registered projects. When none is registered,
 *                the startup directory becomes the default project.
 */

import { existsSync, statSync } from 'node:fs'
import { randomInt } from 'node:crypto'
import { Store } from './store.js'
import { SessionManager } from './agent/manager.js'
import { startDaemon } from './server.js'
import { ensureTlsMaterial } from './tls.js'
import { parseSpeechArgs } from './speech.js'

const VERSION = '0.1.0'

function parseArgs(argv: string[]): {
  port: number
  localhost: boolean
  noTls: boolean
  name?: string
  code?: string
  projects: string[]
  speech: Parameters<typeof parseSpeechArgs>[0]
} {
  const args: {
    port: number
    localhost: boolean
    noTls: boolean
    name?: string
    code?: string
    projects: string[]
    speech: Parameters<typeof parseSpeechArgs>[0]
  } = {
    port: 8747,
    localhost: false,
    noTls: false,
    projects: [],
    speech: {},
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
    } else if (arg === '--project') {
      if (!next || next.startsWith('--')) {
        console.error('--project requires a directory argument')
        process.exit(1)
      }
      args.projects.push(next)
      i++
    } else if (arg === '--speech-provider') {
      args.speech.speechProvider = next
      i++
    } else if (arg === '--speech-model') {
      args.speech.speechModel = next
      i++
    } else if (arg === '--speech-api-key-file') {
      args.speech.speechApiKeyFile = next
      i++
    } else if (arg === '--speech-base-url') {
      args.speech.speechBaseUrl = next
      i++
    } else if (arg === '--speech-language') {
      args.speech.speechLanguage = next
      i++
    } else if (arg === '--help' || arg === '-h') {
      console.log('cc-go daemon — remote-control Claude Code from your phone\n')
      console.log('  --port, -p <n>     WebSocket port (default 8747)')
      console.log('  --localhost, -l    bind 127.0.0.1 only (SSH-tunnel mode)')
      console.log('  --name, -n <s>     host name shown on the phone')
      console.log('  --code, -c <s>     fixed pairing code (default: random 6 digits)')
      console.log('  --no-tls           plaintext dev mode (forces loopback binding)')
      console.log('  --project <dir>    register a project directory (repeatable);')
      console.log('                     with none registered, the startup dir is used')
      console.log('  --speech-provider <openai>')
      console.log('                     enable phone voice dictation via a daemon-side')
      console.log('                     transcription provider (OpenAI-compatible);')
      console.log('                     off by default — audio never leaves this machine')
      console.log('                     unless configured')
      console.log('  --speech-model <id>        transcription model (e.g. whisper-1)')
      console.log('  --speech-api-key-file <f>  file holding the provider API key')
      console.log('  --speech-base-url <url>    provider base URL (default OpenAI)')
      console.log('  --speech-language <bcp47>  recognition hint (default: zh)')
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

  for (const dir of args.projects) {
    if (!existsSync(dir) || !statSync(dir).isDirectory()) {
      console.error(`--project expects an existing directory: ${dir}`)
      process.exit(1)
    }
    store.addProject(dir)
  }
  if (store.listProjects().length === 0) {
    store.addProject(process.cwd())
  }

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
    speech: parseSpeechArgs(args.speech),
  })

  const shutdown = (sig: NodeJS.Signals): void => {
    console.error(`[cc-go] shutting down on ${sig}`)
    manager.disposeAll()
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 1500).unref()
  }
  process.on('SIGINT', (s) => shutdown(s))
  process.on('SIGTERM', (s) => shutdown(s))
}

void main()
