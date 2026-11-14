// task 1.3：回放填充 —— tool_result 的原始输出（多行文本 + 图片）与
// user 消息 image block 还原为附件；与实时侧共用 extractToolResult。
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { encodeCwd, parseTranscriptItems } from '../src/history.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-history-detail-'))
  dirs.push(dir)
  return dir
}

let configDir: string
let projectDir: string
const SID = '01234567-abcd-4ef0-9a12-333333333333'

function writeTranscript(lines: unknown[]): void {
  const dir = join(configDir, 'projects', encodeCwd(projectDir))
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, `${SID}.jsonl`), lines.map((l) => JSON.stringify(l)).join('\n') + '\n')
}

beforeAll(() => {
  configDir = tempDir()
  projectDir = tempDir()
  process.env.CLAUDE_CONFIG_DIR = configDir
})

afterAll(() => {
  delete process.env.CLAUDE_CONFIG_DIR
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

describe('回放填充原始输出', () => {
  it('tool_result 还原多行文本与图片', async () => {
    writeTranscript([
      { type: 'user', uuid: 'u1', timestamp: '2026-11-14T01:00:00.000Z', message: { role: 'user', content: '看看' } },
      {
        type: 'assistant',
        uuid: 'a1',
        timestamp: '2026-11-14T01:00:01.000Z',
        message: {
          role: 'assistant',
          content: [{ type: 'tool_use', id: 'call-1', name: 'Bash', input: { command: 'ls -la' } }],
        },
      },
      {
        type: 'user',
        uuid: 'u2',
        timestamp: '2026-11-14T01:00:02.000Z',
        message: {
          role: 'user',
          content: [
            {
              type: 'tool_result',
              tool_use_id: 'call-1',
              content: [
                { type: 'text', text: 'total 0\ndrwxr-xr-x  2 luke luke 4096 .\n-rw-r--r--  1 luke luke   42 a.txt' },
                { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'aW1nMQ==' } },
              ],
            },
          ],
        },
      },
    ])

    const lines = await parseTranscriptItems(SID, join(configDir, 'projects', encodeCwd(projectDir), `${SID}.jsonl`))
    const tool = lines.map((l) => l.item).find((it) => it.kind === 'tool') as Extract<import('../src/protocol.js').Item, { kind: 'tool' }>
    expect(tool.status).toBe('done')
    expect(tool.resultText).toContain('total 0\ndrwxr-xr-x')
    expect(tool.resultTruncated).toBeUndefined()
    expect(tool.resultImages).toEqual([{ mimeType: 'image/png', dataBase64: 'aW1nMQ==' }])
    // 摘要仍在（列表/副标题用）。
    expect(tool.summary).toContain('total 0')
  })

  it('超限文本截断并标记', async () => {
    const long = 'x'.repeat(21000)
    writeTranscript([
      {
        type: 'assistant',
        uuid: 'a1',
        timestamp: '2026-11-14T01:00:00.000Z',
        message: { role: 'assistant', content: [{ type: 'tool_use', id: 'call-1', name: 'Bash', input: {} }] },
      },
      {
        type: 'user',
        uuid: 'u2',
        timestamp: '2026-11-14T01:00:01.000Z',
        message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'call-1', content: long }] },
      },
    ])
    const lines = await parseTranscriptItems(SID, join(configDir, 'projects', encodeCwd(projectDir), `${SID}.jsonl`))
    const tool = lines.map((l) => l.item).find((it) => it.kind === 'tool') as Extract<import('../src/protocol.js').Item, { kind: 'tool' }>
    expect(tool.resultText?.length).toBe(20000)
    expect(tool.resultTruncated).toBe(true)
  })

  it('user 消息的 image block 还原为附件', async () => {
    writeTranscript([
      {
        type: 'user',
        uuid: 'u1',
        timestamp: '2026-11-14T01:00:00.000Z',
        message: {
          role: 'user',
          content: [
            { type: 'text', text: '这张图怎么回事' },
            { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'aW1nMg==' } },
          ],
        },
      },
    ])
    const lines = await parseTranscriptItems(SID, join(configDir, 'projects', encodeCwd(projectDir), `${SID}.jsonl`))
    const user = lines.map((l) => l.item).find((it) => it.kind === 'user') as Extract<import('../src/protocol.js').Item, { kind: 'user' }>
    expect(user.text).toBe('这张图怎么回事')
    expect(user.attachments).toEqual([{ name: 'image', mimeType: 'image/jpeg', dataBase64: 'aW1nMg==' }])
  })

  it('旧数据无新字段照常回放', async () => {
    writeTranscript([
      { type: 'user', uuid: 'u1', timestamp: '2026-11-14T01:00:00.000Z', message: { role: 'user', content: '普通消息' } },
    ])
    const lines = await parseTranscriptItems(SID, join(configDir, 'projects', encodeCwd(projectDir), `${SID}.jsonl`))
    const user = lines.map((l) => l.item).find((it) => it.kind === 'user') as Extract<import('../src/protocol.js').Item, { kind: 'user' }>
    expect(user.attachments).toBeUndefined()
  })
})
