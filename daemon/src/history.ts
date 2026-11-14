/**
 * history.ts — reads Claude Code's own session transcripts
 * (`$CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/<sessionId>.jsonl`) and turns
 * them into the same Item model the live session stream uses, so the phone
 * renders history with zero new logic (multi-project-history D3/D4).
 *
 * Everything here is READ-ONLY: cc-go never writes to these files. Parsing is
 * deliberately lenient — the JSONL layout is a Claude Code internal format
 * with no stability promise, so unknown line types and malformed lines are
 * skipped instead of failing the whole replay (only a first line that is not
 * JSON at all marks the file as unparseable).
 *
 * Reference: happy-cli's sessionScanner / sessionProtocolMapper (MIT).
 */

import { createReadStream, existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import type {
  AssistantItem,
  Attachment,
  DiscoveredSession,
  Item,
  SessionHistoryResult,
  ToolItem,
  ToolResultImage,
  UserItem,
} from './protocol.js'
import { ImageMimeType } from './protocol.js'

// ---------------------------------------------------------------------------
// Errors (mapped to RpcError codes by server.ts)
// ---------------------------------------------------------------------------

export class HistoryError extends Error {
  constructor(
    readonly code: 'not_found' | 'unparseable' | 'bad_request',
    message: string,
  ) {
    super(message)
  }
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/** Claude Code encodes a cwd into a directory name by replacing every
 *  non [alphanumeric|-] character with '-' ("/home/x/ai" → "-home-x-ai"). */
export function encodeCwd(cwd: string): string {
  return resolve(cwd).replace(/[^a-zA-Z0-9-]/g, '-')
}

export function claudeConfigDir(): string {
  return process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude')
}

export function claudeProjectsDir(): string {
  return join(claudeConfigDir(), 'projects')
}

/** Claude session ids are uuid filename stems; anything else (path
 *  separators, dots, arbitrary words) is rejected before it ever reaches
 *  the filesystem. */
const SESSION_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function transcriptPath(claudeSessionId: string, cwd: string): string {
  if (!SESSION_ID_RE.test(claudeSessionId)) {
    throw new HistoryError('bad_request', `invalid session id: ${claudeSessionId}`)
  }
  return join(claudeProjectsDir(), encodeCwd(cwd), `${claudeSessionId}.jsonl`)
}

/** Newest transcript file in a project directory — how the history tailer
 *  notices a terminal `--resume` forking the conversation into a new file. */
export function newestTranscriptIn(cwd: string): { claudeSessionId: string; file: string; mtimeMs: number } | null {
  const dir = join(claudeProjectsDir(), encodeCwd(cwd))
  if (!existsSync(dir)) return null
  let best: { claudeSessionId: string; file: string; mtimeMs: number } | null = null
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith('.jsonl')) continue
    const sid = entry.slice(0, -'.jsonl'.length)
    if (!SESSION_ID_RE.test(sid)) continue
    const file = join(dir, entry)
    const mtimeMs = statSync(file).mtimeMs
    if (best === null || mtimeMs > best.mtimeMs) best = { claudeSessionId: sid, file, mtimeMs }
  }
  return best
}

// ---------------------------------------------------------------------------
// Transcript → Items (the single mapper)
// ---------------------------------------------------------------------------

export interface LineItem {
  /** 1-based line number in the source JSONL (pagination cursor). */
  line: number
  item: Item
}

interface RawLine {
  type?: string
  uuid?: string
  timestamp?: string
  isMeta?: boolean
  isCompactSummary?: boolean
  isSidechain?: boolean
  message?: { content?: unknown }
}

interface ContentBlock {
  type?: string
  text?: string
  thinking?: string
  id?: string
  name?: string
  input?: unknown
  tool_use_id?: string
  content?: unknown
  is_error?: boolean
  /** image block (user attachments & tool results) */
  source?: { type?: string; media_type?: string; data?: string }
}

/**
 * Incremental JSONL-line → Item mapper. One instance per (re)parse so
 * tool_use/tool_result pairs can close across lines — and, for the history
 * tailer, across polls. Only `user` and `assistant` lines produce items;
 * every other line type (Claude Code internals: file-history-snapshot,
 * queue-operation, mode, cost-state, …) is skipped silently. `isMeta` /
 * `isCompactSummary` / sidechain lines and thinking blocks are skipped for
 * now — the Item model has no rendering for them yet (see design Open
 * Questions). Item ids embed the source line uuid (`hist-<sid>-<uuid>`),
 * which is what lets the tailer dedupe a forked transcript's copied history.
 */
export class TranscriptMapper {
  private readonly prefix: string
  private readonly pendingTools = new Map<string, ToolItem>()
  private counter = 0

  constructor(claudeSessionId: string) {
    this.prefix = `hist-${claudeSessionId}`
  }

  /** Feed one raw JSONL line; returns the items it produced (possibly none).
   *  Malformed lines are skipped (the layout is an internal Claude Code
   *  format — parse errors must never kill a replay or a tail). */
  processLine(raw: string): Item[] {
    const trimmed = raw.trim()
    if (trimmed === '') return []
    let entry: RawLine
    try {
      entry = JSON.parse(trimmed) as RawLine
    } catch {
      return []
    }
    if (entry.isSidechain || entry.isMeta || entry.isCompactSummary) return []
    const createdAt = tsOf(entry)
    const produced: Item[] = []
    const idFor = (uuid: string | undefined, fallbackKind: string): string =>
      `${this.prefix}-${uuid ?? `${fallbackKind}-${this.counter++}`}`

    if (entry.type === 'user') {
      const content = entry.message?.content
      if (typeof content === 'string') {
        if (content.trim() !== '') {
          produced.push({
            kind: 'user',
            id: idFor(entry.uuid, 'u'),
            text: content,
            source: 'daemon',
            createdAt,
          })
        }
      } else if (Array.isArray(content)) {
        const texts: string[] = []
        const attachments: Attachment[] = []
        for (const block of content as ContentBlock[]) {
          if (block?.type === 'text' && typeof block.text === 'string' && block.text.trim() !== '') {
            texts.push(block.text)
          } else if (block?.type === 'tool_result' && typeof block.tool_use_id === 'string') {
            const tool = this.pendingTools.get(block.tool_use_id)
            if (tool) {
              tool.status = block.is_error ? 'error' : 'done'
              tool.summary = summarizeResult(block.content)
              Object.assign(tool, extractToolResult(block.content))
              this.pendingTools.delete(block.tool_use_id)
            }
          } else if (block?.type === 'image' && block.source?.type === 'base64') {
            // 用户随消息发的图片（或回放里的等价块）→ 附件回显。mime 需
            // 落在协议枚举内（Messages API 接受的子集），其他照旧跳过。
            const mime = ImageMimeType.safeParse(block.source.media_type)
            if (
              mime.success &&
              typeof block.source.data === 'string' &&
              block.source.data.length <= TOOL_RESULT_IMAGE_BYTES &&
              attachments.length < 4
            ) {
              attachments.push({ name: 'image', mimeType: mime.data, dataBase64: block.source.data })
            }
          }
        }
        if (texts.length > 0 || attachments.length > 0) {
          const userItem: UserItem = {
            kind: 'user',
            id: idFor(entry.uuid, 'u'),
            text: texts.join(''),
            source: 'daemon',
            createdAt,
          }
          if (attachments.length > 0) userItem.attachments = attachments
          produced.push(userItem)
        }
      }
    } else if (entry.type === 'assistant') {
      const content = entry.message?.content
      if (Array.isArray(content)) {
        // Blocks render in content order: consecutive text blocks merge into
        // one item, a tool_use flushes the text buffered so far. Thinking
        // blocks are skipped (no rendering in the Item model yet).
        let texts: string[] = []
        const flushTexts = (): void => {
          if (texts.length === 0) return
          produced.push({
            kind: 'assistant',
            id: idFor(entry.uuid, 'a'),
            text: texts.join(''),
            thinking: '',
            status: 'done',
            createdAt,
          })
          texts = []
        }
        for (const block of content as ContentBlock[]) {
          if (block?.type === 'text' && typeof block.text === 'string' && block.text.trim() !== '') {
            texts.push(block.text)
          } else if (block?.type === 'tool_use' && typeof block.id === 'string' && typeof block.name === 'string') {
            flushTexts()
            const tool: ToolItem = {
              kind: 'tool',
              id: `${this.prefix}-${block.id}`,
              claudeCallId: block.id,
              name: block.name,
              input: isRecord(block.input) ? block.input : {},
              status: 'running',
              createdAt,
            }
            this.pendingTools.set(block.id, tool)
            produced.push(tool)
          }
        }
        flushTexts()
      }
    }
    return produced
  }

  /** Close tool_use blocks whose result never arrived (interrupted turn).
   *  Only for complete parses — the tailer keeps pairs pending across polls. */
  closeUnpaired(): void {
    for (const tool of this.pendingTools.values()) tool.status = 'done'
  }
}

function tsOf(entry: RawLine): number {
  const t = entry.timestamp ? Date.parse(entry.timestamp) : NaN
  return Number.isFinite(t) ? t : 0
}

/**
 * Parse a transcript into items tagged with their source line. A first line
 * that is not JSON at all marks the file as unparseable; later malformed
 * lines are skipped (the JSONL layout is a Claude Code internal format with
 * no stability promise).
 */
/**
 * Parse a transcript into items tagged with their source line. A first line
 * that is not JSON at all marks the file as unparseable; later malformed
 * lines are skipped (the JSONL layout is a Claude Code internal format with
 * no stability promise).
 *
 * Results are cached by (mtime, size) — replay pages and discovery hit the
 * same file repeatedly, and re-parsing a large transcript per "load older"
 * click or per discovery refresh is pure waste. Returns a fresh array (the
 * item objects are shared read-only).
 */
const PARSE_CACHE_LIMIT = 32
const parseCache = new Map<string, { mtimeMs: number; size: number; items: LineItem[] }>()

export async function parseTranscriptItems(claudeSessionId: string, file: string): Promise<LineItem[]> {
  const st = statSync(file)
  const cached = parseCache.get(file)
  if (cached && cached.mtimeMs === st.mtimeMs && cached.size === st.size) return [...cached.items]

  const out: LineItem[] = []
  const mapper = new TranscriptMapper(claudeSessionId)
  const stream = createReadStream(file, { encoding: 'utf8' })
  const rl = createInterface({ crlfDelay: Infinity, input: stream })
  let line = 0
  for await (const raw of rl) {
    line++
    if (line === 1) {
      const trimmed = raw.trim()
      if (trimmed !== '') {
        try {
          JSON.parse(trimmed)
        } catch {
          parseCache.delete(file)
          throw new HistoryError('unparseable', 'transcript is not valid JSONL')
        }
      }
    }
    for (const item of mapper.processLine(raw)) out.push({ line, item })
  }
  mapper.closeUnpaired()

  parseCache.delete(file)
  parseCache.set(file, { mtimeMs: st.mtimeMs, size: st.size, items: out })
  if (parseCache.size > PARSE_CACHE_LIMIT) {
    const oldest = parseCache.keys().next().value
    if (oldest !== undefined) parseCache.delete(oldest)
  }
  return [...out]
}

/**
 * Does this transcript look like a fork/copy of content we already show? A
 * `--resume` fork copies the whole history, so its early user/assistant line
 * uuids must recur in the known set. Used to gate the history tailer's
 * newest-file follow: without it, an unrelated terminal conversation in the
 * same project would hijack the session (wrong resume id persisted).
 */
export function transcriptSharesLineage(file: string, knownKeys: ReadonlySet<string>): boolean {
  try {
    const lines = readFileSync(file, 'utf8').split('\n')
    let conversationLines = 0
    for (const raw of lines.slice(0, 500)) {
      const trimmed = raw.trim()
      if (trimmed === '') continue
      let entry: RawLine
      try {
        entry = JSON.parse(trimmed) as RawLine
      } catch {
        continue
      }
      if (entry.type !== 'user' && entry.type !== 'assistant') continue
      if (entry.isSidechain || entry.isMeta || entry.isCompactSummary) continue
      conversationLines++
      if (typeof entry.uuid === 'string' && knownKeys.has(`${entry.type}:${entry.uuid}`)) return true
      if (conversationLines >= 20) break
    }
    return false
  } catch {
    return false
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function summarizeResult(content: unknown, max = 200): string | undefined {
  return summarizeToolContent(content, max)
}

// ---- tool raw result extraction (transcript-data-protocol D2) ---------------

export const TOOL_RESULT_TEXT_CAP = 20_000
export const TOOL_RESULT_IMAGE_MAX = 2
export const TOOL_RESULT_IMAGE_BYTES = 1_000_000

export interface ExtractedToolResult {
  resultText?: string
  resultTruncated?: boolean
  resultImages?: ToolResultImage[]
}

/**
 * Extract the raw result of a tool call (full text with newlines + bounded
 * images) from a tool_result block's content. Shared by the live SDK stream
 * (session.ts) and history replay so both transcript surfaces carry the same
 * fields. Content shapes vary (string | block array); anything unrecognized
 * yields no fields — callers fall back to the summary.
 */
export function extractToolResult(content: unknown): ExtractedToolResult {
  if (typeof content === 'string') {
    return textResult(content)
  }
  if (!Array.isArray(content)) return {}
  const blocks = content as ContentBlock[]
  const texts = blocks
    .filter((b) => b?.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text as string)
  const images: ToolResultImage[] = []
  for (const block of blocks) {
    if (block?.type !== 'image') continue
    const source = block.source
    if (source?.type !== 'base64') continue
    if (typeof source.media_type !== 'string' || typeof source.data !== 'string') continue
    if (source.data.length > TOOL_RESULT_IMAGE_BYTES) continue
    images.push({ mimeType: source.media_type, dataBase64: source.data })
    if (images.length >= TOOL_RESULT_IMAGE_MAX) break
  }
  const result: ExtractedToolResult = {}
  if (texts.length > 0) Object.assign(result, textResult(texts.join('\n')))
  if (images.length > 0) result.resultImages = images
  return result
}

function textResult(text: string): ExtractedToolResult {
  if (text === '') return {}
  if (text.length <= TOOL_RESULT_TEXT_CAP) return { resultText: text }
  return { resultText: text.slice(0, TOOL_RESULT_TEXT_CAP), resultTruncated: true }
}

/** Shared tool-result summarizer — the live SDK stream (session.ts) and the
 *  history replay must clip identically so the same content reads the same
 *  in both transcript surfaces. */
export function summarizeToolContent(content: unknown, max = 200): string | undefined {
  let text: string
  if (typeof content === 'string') text = content
  else if (Array.isArray(content)) {
    text = (content as ContentBlock[])
      .map((b) => (b?.type === 'text' && typeof b.text === 'string' ? b.text : ''))
      .join('')
  } else return undefined
  const collapsed = text.replace(/\s+/g, ' ').trim()
  if (collapsed === '') return undefined
  return collapsed.length > max ? `${collapsed.slice(0, max)}…` : collapsed
}

// ---------------------------------------------------------------------------
// Replay (paged newest → older)
// ---------------------------------------------------------------------------

export async function replayHistory(
  claudeSessionId: string,
  cwd: string,
  beforeLine?: number,
  limit = 100,
): Promise<SessionHistoryResult> {
  const file = transcriptPath(claudeSessionId, cwd)
  if (!existsSync(file)) throw new HistoryError('not_found', `no transcript for session ${claudeSessionId}`)
  const lineItems = await parseTranscriptItems(claudeSessionId, file)
  const eligible = beforeLine === undefined ? lineItems : lineItems.filter((li) => li.line < beforeLine)
  const page = eligible.slice(-limit)
  const nextBeforeLine = eligible.length > page.length && page.length > 0 ? page[0]!.line : null
  return { items: page.map((li) => li.item), nextBeforeLine }
}

// ---------------------------------------------------------------------------
// Full-history collection (import prefill / rehydrate reseed)
// ---------------------------------------------------------------------------

/** Pull every replay page, oldest first (multi-project-history D5). */
export async function collectHistory(claudeSessionId: string, cwd: string): Promise<Item[]> {
  const first = await replayHistory(claudeSessionId, cwd, undefined, 500)
  const items = [...first.items]
  let cursor = first.nextBeforeLine
  while (cursor !== null) {
    const page = await replayHistory(claudeSessionId, cwd, cursor, 500)
    items.unshift(...page.items)
    cursor = page.nextBeforeLine
  }
  return items
}

/** Session title derived from the first user message, or null when none. */
export function titleFromHistory(items: Item[]): string | null {
  const firstUser = items.find((i) => i.kind === 'user')
  return firstUser !== undefined && firstUser.kind === 'user' ? truncateTitle(firstUser.text) : null
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/**
 * List the Claude Code sessions belonging to a project directory, newest
 * activity first. `managed` maps claudeSessionId → cc-go session id for
 * sessions the daemon already tracks (created here or imported).
 */
export async function discoverSessions(
  cwd: string,
  managed: ReadonlyMap<string, string>,
): Promise<DiscoveredSession[]> {
  const dir = join(claudeProjectsDir(), encodeCwd(cwd))
  if (!existsSync(dir)) return []
  const sessions: DiscoveredSession[] = []
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith('.jsonl')) continue
    const claudeSessionId = entry.slice(0, -'.jsonl'.length)
    if (!SESSION_ID_RE.test(claudeSessionId)) continue
    const file = join(dir, entry)
    let lineItems: LineItem[]
    try {
      lineItems = await parseTranscriptItems(claudeSessionId, file)
    } catch {
      continue // unparseable/garbage file — hide it rather than fail discovery
    }
    const lastActiveAt = statSync(file).mtimeMs
    const firstUser = lineItems.find((li) => li.item.kind === 'user')
    const title =
      firstUser && firstUser.item.kind === 'user' && firstUser.item.text.trim() !== ''
        ? truncateTitle(firstUser.item.text)
        : new Date(lastActiveAt).toISOString().replace('T', ' ').slice(0, 16)
    const messageCount = lineItems.filter(
      (li) => li.item.kind === 'user' || li.item.kind === 'assistant',
    ).length
    const ccGoSessionId = managed.get(claudeSessionId) ?? null
    sessions.push({
      claudeSessionId,
      title,
      lastActiveAt,
      messageCount,
      managed: ccGoSessionId !== null,
      ccGoSessionId,
    })
  }
  sessions.sort((a, b) => b.lastActiveAt - a.lastActiveAt)
  return sessions
}

function truncateTitle(text: string, max = 80): string {
  const collapsed = text.replace(/\s+/g, ' ').trim()
  return collapsed.length > max ? `${collapsed.slice(0, max)}…` : collapsed
}
