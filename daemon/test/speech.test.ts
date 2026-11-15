import { describe, expect, it } from 'vitest'
import {
  SpeechErrorCode,
  parseSpeechArgs,
  speechCatalog,
  speechTranscribe,
} from '../src/speech.js'

const CONFIG = {
  provider: 'openai' as const,
  model: 'whisper-1',
  apiKey: 'sk-test',
  baseUrl: 'https://example.invalid/v1',
  language: 'zh',
}

/** A minimal valid 16kHz mono PCM16 WAV: 44-byte header + 0.5s of silence. */
function makeWav(seconds = 0.5): Buffer {
  const samples = Math.floor(16000 * seconds)
  const dataSize = samples * 2
  const buf = Buffer.alloc(44 + dataSize)
  buf.write('RIFF', 0, 'ascii')
  buf.writeUInt32LE(36 + dataSize, 4)
  buf.write('WAVE', 8, 'ascii')
  buf.write('fmt ', 12, 'ascii')
  buf.writeUInt32LE(16, 16)
  buf.writeUInt16LE(1, 20) // PCM
  buf.writeUInt16LE(1, 22) // mono
  buf.writeUInt32LE(16000, 24)
  buf.writeUInt32LE(32000, 28)
  buf.writeUInt16LE(2, 32)
  buf.writeUInt16LE(16, 34)
  buf.write('data', 36, 'ascii')
  buf.writeUInt32LE(dataSize, 40)
  return buf
}

describe('parseSpeechArgs', () => {
  it('未配置 → undefined（catalog 空、transcribe 报未配置）', () => {
    expect(parseSpeechArgs({})).toBeUndefined()
  })

  it('缺少 model 或 key 文件 → 报错退出', () => {
    const originalExit = process.exit
    let exited = false
    process.exit = (() => {
      exited = true
      throw new Error('exit')
    }) as never
    try {
      expect(() => parseSpeechArgs({ speechProvider: 'openai' })).toThrow('exit')
      expect(exited).toBe(true)
    } finally {
      process.exit = originalExit
    }
  })

  it('完整参数 → 配置（key 从文件读取并 trim）', () => {
    const { writeFileSync, rmSync, mkdtempSync } = require('node:fs') as typeof import('node:fs')
    const { join } = require('node:path') as typeof import('node:path')
    const { tmpdir } = require('node:os') as typeof import('node:os')
    const dir = mkdtempSync(join(tmpdir(), 'ccgo-speech-'))
    const keyFile = join(dir, 'key.txt')
    writeFileSync(keyFile, 'sk-secret\n')
    const cfg = parseSpeechArgs({
      speechProvider: 'openai',
      speechModel: 'whisper-1',
      speechApiKeyFile: keyFile,
      speechBaseUrl: 'https://api.example/v1',
      speechLanguage: 'zh',
    })
    rmSync(dir, { recursive: true })
    expect(cfg).toEqual({
      provider: 'openai',
      model: 'whisper-1',
      apiKey: 'sk-secret',
      baseUrl: 'https://api.example/v1',
      language: 'zh',
    })
  })
})

describe('speechCatalog', () => {
  it('未配置 → 空 providers，但上限照常声明', () => {
    const catalog = speechCatalog(undefined)
    expect(catalog.providers).toEqual([])
    expect(catalog.providerId).toBeNull()
    expect(catalog.maxAudioBytes).toBeGreaterThan(0)
    expect(catalog.maxDurationSeconds).toBeLessThanOrEqual(600)
  })

  it('已配置 → 一个 usable 的 host-local provider', () => {
    const catalog = speechCatalog(CONFIG)
    expect(catalog.providers).toHaveLength(1)
    expect(catalog.providers[0]).toMatchObject({
      id: 'openai:whisper-1',
      location: 'host-local',
      usable: true,
    })
    expect(catalog.providerId).toBe('openai:whisper-1')
  })
})

describe('speechTranscribe', () => {
  it('未配置 → speech_not_configured', async () => {
    await expect(speechTranscribe(undefined, 'x')).rejects.toMatchObject({
      code: 'speech_not_configured',
    })
  })

  it('音频超限 → speech_audio_too_large，不调用上游', async () => {
    let called = 0
    const big = Buffer.alloc(11 * 1024 * 1024).toString('base64')
    await expect(
      speechTranscribe(CONFIG, big, { fetchImpl: async () => (called++, {} as Response) }),
    ).rejects.toMatchObject({ code: 'speech_audio_too_large' })
    expect(called).toBe(0)
  })

  it('非法 WAV（RIFF 缺失/过短）→ speech_transcribe_failed，不调用上游', async () => {
    let called = 0
    const notWav = Buffer.alloc(100, 1).toString('base64')
    await expect(
      speechTranscribe(CONFIG, notWav, { fetchImpl: async () => (called++, {} as Response) }),
    ).rejects.toMatchObject({ code: 'speech_transcribe_failed' })
    expect(called).toBe(0)
  })

  it('上游不可达 → speech_provider_unavailable', async () => {
    await expect(
      speechTranscribe(CONFIG, makeWav().toString('base64'), {
        fetchImpl: async () => {
          throw new Error('connection refused')
        },
      }),
    ).rejects.toMatchObject({ code: 'speech_provider_unavailable' })
  })

  it('上游非 2xx → speech_transcribe_failed（带状态码）', async () => {
    await expect(
      speechTranscribe(CONFIG, makeWav().toString('base64'), {
        fetchImpl: async () =>
          ({ ok: false, status: 401, text: async () => 'unauthorized' }) as unknown as Response,
      }),
    ).rejects.toMatchObject({ code: 'speech_transcribe_failed' })
  })

  it('成功 → 返回 trim 后文本', async () => {
    const text = await speechTranscribe(CONFIG, makeWav().toString('base64'), {
      language: 'zh',
      fetchImpl: async () =>
        ({
          ok: true,
          status: 200,
          json: async () => ({ text: '  你好世界  ' }),
        }) as unknown as Response,
    })
    expect(text).toBe('你好世界')
  })

  it('空文本结果原样返回（空判定归调用方/App）', async () => {
    const text = await speechTranscribe(CONFIG, makeWav().toString('base64'), {
      fetchImpl: async () =>
        ({ ok: true, status: 200, json: async () => ({ text: '' }) }) as unknown as Response,
    })
    expect(text).toBe('')
  })

  it('错误码表齐全（spec 列出的四个稳定码）', () => {
    expect(SpeechErrorCode.NOT_CONFIGURED).toBe('speech_not_configured')
    expect(SpeechErrorCode.AUDIO_TOO_LARGE).toBe('speech_audio_too_large')
    expect(SpeechErrorCode.PROVIDER_UNAVAILABLE).toBe('speech_provider_unavailable')
    expect(SpeechErrorCode.TRANSCRIBE_FAILED).toBe('speech_transcribe_failed')
  })
})
