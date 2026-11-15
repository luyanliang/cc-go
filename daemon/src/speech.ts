/**
 * Speech transcription service (voice-dictation).
 *
 * The daemon optionally fronts a transcription provider so the phone can
 * dictate by recording a WAV and uploading it here. Two shapes:
 *
 *  - `speech.catalog`  → what is configured and usable (empty when nothing is,
 *                        so the phone treats voice-engine mode as unavailable
 *                        rather than erroring).
 *  - `speech.transcribe` → one 16kHz mono PCM16 WAV as base64 in, text out.
 *    Whole-recording only: no streaming, no partial results.
 *
 * Providers: `openai` — any OpenAI-compatible `/audio/transcriptions` endpoint
 * (OpenAI Whisper API, or self-hosted compatible servers). Not configured by
 * default: audio never leaves the machine unless the operator opts in.
 */

import { readFileSync } from 'node:fs'

/** Stable error codes surfaced on the `speech.transcribe` error frame. */
export const SpeechErrorCode = {
  NOT_CONFIGURED: 'speech_not_configured',
  AUDIO_TOO_LARGE: 'speech_audio_too_large',
  PROVIDER_UNAVAILABLE: 'speech_provider_unavailable',
  TRANSCRIBE_FAILED: 'speech_transcribe_failed',
} as const

/** Raw (decoded) WAV byte ceiling; catalog declares it to the phone. */
export const MAX_AUDIO_BYTES = 10 * 1024 * 1024
/** Recording length ceiling in seconds; the phone clamps its recorder to this. */
export const MAX_DURATION_SECONDS = 600
/** Upstream call timeout — the phone is holding a UI spinner meanwhile. */
const TRANSCRIBE_TIMEOUT_MS = 30_000

export interface SpeechProviderConfig {
  /** Only `openai` (OpenAI-compatible /audio/transcriptions) today. */
  provider: 'openai'
  /** Transcription model id at the provider (e.g. `whisper-1`). */
  model: string
  apiKey: string
  /** Defaults to the OpenAI endpoint; point at compatible self-hosted servers. */
  baseUrl: string
  /** BCP-47 hint sent to the provider (default `zh`). */
  language: string
}

export interface SpeechCatalogEntry {
  id: string
  name: string
  /** Where transcription happens: this daemon is always `host-local`. */
  location: 'host-local'
  languages: string[]
  usable: boolean
}

export interface SpeechCatalog {
  providers: SpeechCatalogEntry[]
  providerId: string | null
  language: string
  maxAudioBytes: number
  maxDurationSeconds: number
}

/**
 * Parse `--speech-*` CLI flags into a provider config; `undefined` when the
 * operator has not opted in (catalog then reports empty and transcribe
 * answers `speech_not_configured`). `--speech-api-key-file` is read eagerly —
 * the key itself is never a CLI argument.
 */
export function parseSpeechArgs(args: {
  speechProvider?: string
  speechModel?: string
  speechApiKeyFile?: string
  speechBaseUrl?: string
  speechLanguage?: string
}): SpeechProviderConfig | undefined {
  if (!args.speechProvider && !args.speechModel && !args.speechApiKeyFile) return undefined
  if (args.speechProvider !== 'openai') {
    console.error(`--speech-provider must be "openai" (got: ${args.speechProvider ?? 'missing'})`)
    process.exit(1)
  }
  if (!args.speechModel || !args.speechApiKeyFile) {
    console.error('--speech-provider openai requires --speech-model and --speech-api-key-file')
    process.exit(1)
  }
  let apiKey: string
  try {
    apiKey = readFileSync(args.speechApiKeyFile, 'utf8').trim()
  } catch {
    console.error(`--speech-api-key-file is not readable: ${args.speechApiKeyFile}`)
    process.exit(1)
  }
  if (!apiKey) {
    console.error('--speech-api-key-file is empty')
    process.exit(1)
  }
  return {
    provider: 'openai',
    model: args.speechModel,
    apiKey,
    baseUrl: args.speechBaseUrl ?? 'https://api.openai.com/v1',
    language: args.speechLanguage ?? 'zh',
  }
}

/** The catalog the phone sees. Empty providers = voice-engine mode unavailable. */
export function speechCatalog(config: SpeechProviderConfig | undefined): SpeechCatalog {
  if (!config) {
    return {
      providers: [],
      providerId: null,
      language: 'zh',
      maxAudioBytes: MAX_AUDIO_BYTES,
      maxDurationSeconds: MAX_DURATION_SECONDS,
    }
  }
  return {
    providers: [
      {
        id: `${config.provider}:${config.model}`,
        name: `${config.provider} · ${config.model}`,
        location: 'host-local',
        languages: [config.language],
        usable: true,
      },
    ],
    providerId: `${config.provider}:${config.model}`,
    language: config.language,
    maxAudioBytes: MAX_AUDIO_BYTES,
    maxDurationSeconds: MAX_DURATION_SECONDS,
  }
}

export class SpeechError extends Error {
  readonly code: string
  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

/** Minimal WAV container check: RIFF magic + expected 16kHz mono PCM16 fmt. */
function assertWav(buf: Buffer): void {
  if (buf.length < 44 + 9600) {
    throw new SpeechError(
      SpeechErrorCode.TRANSCRIBE_FAILED,
      'audio too short to contain speech',
    )
  }
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new SpeechError(SpeechErrorCode.TRANSCRIBE_FAILED, 'not a WAV payload')
  }
}

/**
 * Transcribe one WAV. `fetchImpl` is injectable for tests; `now` likewise
 * bounds nothing here but keeps the signature future-proof for retries.
 */
export async function speechTranscribe(
  config: SpeechProviderConfig | undefined,
  audioBase64: string,
  opts: {
    providerId?: string
    language?: string
    fetchImpl?: typeof fetch
  } = {},
): Promise<string> {
  if (!config) {
    throw new SpeechError(
      SpeechErrorCode.NOT_CONFIGURED,
      'daemon has no transcription service configured (start with --speech-provider openai ...)',
    )
  }
  let wav: Buffer
  try {
    wav = Buffer.from(audioBase64, 'base64')
  } catch {
    throw new SpeechError(SpeechErrorCode.TRANSCRIBE_FAILED, 'audio is not valid base64')
  }
  if (wav.length > MAX_AUDIO_BYTES) {
    throw new SpeechError(
      SpeechErrorCode.AUDIO_TOO_LARGE,
      `audio exceeds ${MAX_AUDIO_BYTES} bytes`,
    )
  }
  assertWav(wav)

  const fetchImpl = opts.fetchImpl ?? fetch
  const form = new FormData()
  form.append('file', new Blob([new Uint8Array(wav)], { type: 'audio/wav' }), 'audio.wav')
  form.append('model', config.model)
  form.append('language', opts.language ?? config.language)
  form.append('response_format', 'json')

  let res: Response
  try {
    res = await fetchImpl(`${config.baseUrl}/audio/transcriptions`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${config.apiKey}` },
      body: form,
      signal: AbortSignal.timeout(TRANSCRIBE_TIMEOUT_MS),
    })
  } catch {
    throw new SpeechError(
      SpeechErrorCode.PROVIDER_UNAVAILABLE,
      'transcription provider unreachable',
    )
  }
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new SpeechError(
      SpeechErrorCode.TRANSCRIBE_FAILED,
      `provider ${res.status}: ${body.slice(0, 200)}`,
    )
  }
  let text = ''
  try {
    const data = (await res.json()) as { text?: unknown }
    text = typeof data.text === 'string' ? data.text : ''
  } catch {
    throw new SpeechError(SpeechErrorCode.TRANSCRIBE_FAILED, 'provider returned malformed JSON')
  }
  return text.trim()
}
