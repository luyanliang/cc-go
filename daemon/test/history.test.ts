import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  HistoryError,
  discoverSessions,
  encodeCwd,
  parseTranscriptItems,
  replayHistory,
} from '../src/history.js'

const dirs: string[] = []
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ccgo-history-test-'))
  dirs.push(dir)
  return dir
}

let configDir: string
let projectDir: string

const SID = '01234567-abcd-4ef0-9a12-111111111111'
const SID2 = '01234567-abcd-4ef0-9a12-222222222222'

function writeTranscript(name: string, lines: unknown[]): string {
  const dir = join(configDir, 'projects', encodeCwd(projectDir))
  mkdirSync(dir, { recursive: true })
  const file = join(dir, name)
  // plain strings pass through raw so tests can inject genuinely malformed lines
  writeFileSync(file, lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n') + '\n')
  return file
}

/** A realistic mixed transcript: conversation + tool pairing + internal lines. */
const mixedTranscript = [
  { type: 'mode', sessionId: SID },
  { type: 'file-history-snapshot', some: 'internal' },
  {
    type: 'user',
    uuid: 'u1',
    timestamp: '2026-11-14T01:00:00.000Z',
    message: { role: 'user', content: '帮我看看这个仓库' },
  },
  {
    type: 'user',
    uuid: 'u2',
    timestamp: '2026-11-14T01:00:01.000Z',
    isMeta: true,
    message: { role: 'user', content: '<command-name>/compact</command-name>' },
  },
  {
    type: 'assistant',
    uuid: 'a1',
    timestamp: '2026-11-14T01:00:02.000Z',
    message: {
      role: 'assistant',
      content: [
        { type: 'thinking', thinking: 'internal reasoning' },
        { type: 'text', text: '我先查一下目录。' },
        { type: 'tool_use', id: 'toolu_01', name: 'Grep', input: { pattern: 'foo' } },
      ],
    },
  },
  {
    type: 'user',
    uuid: 'u3',
    timestamp: '2026-11-14T01:00:03.000Z',
    isSidechain: true,
    message: { role: 'user', content: 'subagent input' },
  },
  {
    type: 'user',
    uuid: 'u4',
    timestamp: '2026-11-14T01:00:04.000Z',
    message: {
      role: 'user',
      content: [{ type: 'tool_result', tool_use_id: 'toolu_01', content: [{ type: 'text', text: 'src/foo.ts:1:foo' }] }],
    },
  },
  { type: 'cost-state', tokens: 42 },
  {
    type: 'assistant',
    uuid: 'a2',
    timestamp: '2026-11-14T01:00:05.000Z',
    message: { role: 'assistant', content: [{ type: 'text', text: '找到了一处。' }] },
  },
]

beforeAll(() => {
  configDir = tempDir()
  projectDir = tempDir()
  process.env.CLAUDE_CONFIG_DIR = configDir
})

afterAll(() => {
  delete process.env.CLAUDE_CONFIG_DIR
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

describe('encodeCwd', () => {
  it('encodes a cwd the same way Claude Code does', () => {
    expect(encodeCwd('/home/luke/ai/cc-go')).toBe('-home-luke-ai-cc-go')
    // dots are replaced like every other non-[alphanumeric|-] char, so a
    // dot-directory yields a double hyphen (matches real ~/.claude/projects)
    expect(encodeCwd('/home/luke/.dev/worktree/x')).toBe('-home-luke--dev-worktree-x')
  })
})

describe('parseTranscriptItems (mapper)', () => {
  it('maps conversation lines and pairs tool_use with tool_result', async () => {
    const file = writeTranscript(`${SID}.jsonl`, mixedTranscript)
    const lineItems = await parseTranscriptItems(SID, file)

    expect(lineItems.map((li) => li.item.kind)).toEqual(['user', 'assistant', 'tool', 'assistant'])

    const [user, assistant, tool, assistant2] = lineItems.map((li) => li.item)
    expect(user).toMatchObject({ text: '帮我看看这个仓库', source: 'daemon' })
    expect(assistant).toMatchObject({ kind: 'assistant', text: '我先查一下目录。', status: 'done' })
    expect(tool).toMatchObject({
      kind: 'tool',
      name: 'Grep',
      input: { pattern: 'foo' },
      status: 'done',
      summary: 'src/foo.ts:1:foo',
    })
    expect(assistant2).toMatchObject({ kind: 'assistant', text: '找到了一处。' })
    expect(tool.id).toBe(`hist-${SID}-toolu_01`)
    expect(user.id).toBe(`hist-${SID}-u1`)
  })

  it('skips malformed lines in mid-file but keeps parsing', async () => {
    const file = writeTranscript(`${SID}.jsonl`, [
      ...mixedTranscript.slice(0, 2),
      'this is { not json',
      ...mixedTranscript.slice(2),
    ])
    const lineItems = await parseTranscriptItems(SID, file)
    expect(lineItems.length).toBe(4)
  })

  it('closes an unpaired tool_use as done', async () => {
    const file = writeTranscript(`${SID}.jsonl`, [
      {
        type: 'assistant',
        uuid: 'a1',
        timestamp: '2026-11-14T01:00:02.000Z',
        message: { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_02', name: 'Bash', input: { cmd: 'ls' } }] },
      },
    ])
    const [tool] = (await parseTranscriptItems(SID, file)).map((li) => li.item)
    expect(tool).toMatchObject({ kind: 'tool', status: 'done' })
    expect(tool).not.toHaveProperty('summary')
  })

  it('rejects a file whose first line is not JSON', async () => {
    const file = join(configDir, 'projects', encodeCwd(projectDir), `${SID}.jsonl`)
    writeFileSync(file, 'garbage from line one\n{"type":"user"}\n')
    await expect(parseTranscriptItems(SID, file)).rejects.toMatchObject({ code: 'unparseable' })
  })
})

describe('replayHistory (pagination)', () => {
  it('pages newest → older with a line cursor', async () => {
    writeTranscript(`${SID}.jsonl`, mixedTranscript) // items at lines 3, 5, 5, 9

    const first = await replayHistory(SID, projectDir, undefined, 2)
    // line5 carries assistant text + tool_use (both items share the line);
    // last 2 items = [tool(line5), assistant(line9)].
    expect(first.items.map((i) => i.kind)).toEqual(['tool', 'assistant'])
    expect(first.nextBeforeLine).toBe(5)

    const second = await replayHistory(SID, projectDir, first.nextBeforeLine!, 2)
    // both line-5 items are excluded by the cursor, so only the user line remains
    expect(second.items.map((i) => i.kind)).toEqual(['user'])
    expect(second.nextBeforeLine).toBe(null)
  })

  it('returns the whole transcript when it fits one page', async () => {
    const all = await replayHistory(SID, projectDir, undefined, 100)
    expect(all.items).toHaveLength(4)
    expect(all.nextBeforeLine).toBe(null)
  })

  it('errors for a missing session and rejects traversal ids', async () => {
    await expect(replayHistory('99999999-abcd-4ef0-9a12-333333333333', projectDir)).rejects.toMatchObject({ code: 'not_found' })
    await expect(replayHistory('../../etc/passwd', projectDir)).rejects.toMatchObject({ code: 'bad_request' })
  })
})

describe('discoverSessions', () => {
  it('lists sessions newest-first with titles, counts and managed flags', async () => {
    writeTranscript(`${SID}.jsonl`, mixedTranscript)
    writeTranscript(`${SID2}.jsonl`, [
      { type: 'file-history-snapshot', x: 1 }, // no user message → time-fallback title
    ])

    // make SID clearly newer than SID2
    const newer = Date.now() / 1000 + 100
    utimesSync(join(configDir, 'projects', encodeCwd(projectDir), `${SID}.jsonl`), newer, newer)

    const sessions = await discoverSessions(projectDir, new Map([[SID, 'ccgo-session-1']]))

    expect(sessions).toHaveLength(2)
    expect(sessions[0]).toMatchObject({
      claudeSessionId: SID,
      title: '帮我看看这个仓库',
      managed: true,
      ccGoSessionId: 'ccgo-session-1',
      messageCount: 3, // user + assistant + assistant (tools not counted)
    })
    expect(sessions[1]).toMatchObject({ claudeSessionId: SID2, managed: false, ccGoSessionId: null })
    expect(sessions[1]!.title).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/) // time fallback
  })

  it('hides garbage files instead of failing discovery', async () => {
    writeTranscript('not-a-session.jsonl', [])
    const dir = join(configDir, 'projects', encodeCwd(projectDir))
    writeFileSync(join(dir, '99999999-abcd-4ef0-9a12-444444444444.jsonl'), 'not jsonl at all\n')
    const sessions = await discoverSessions(projectDir, new Map())
    expect(sessions.every((s) => s.claudeSessionId !== 'not-a-session')).toBe(true)
    expect(sessions.every((s) => s.claudeSessionId !== '99999999-abcd-4ef0-9a12-444444444444')).toBe(true)
  })
})
