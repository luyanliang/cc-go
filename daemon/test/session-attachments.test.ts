// task 2.1：附件组装 —— prompt 携带附件落入转录条目、interrupt 路径排队
// 不崩、SDK 回显的混合块（文本+图片）被 echo-guard 吃掉不重复。
import { describe, expect, it } from 'vitest'
import type { SDKMessage } from '@anthropic-ai/claude-agent-sdk'
import { Session } from '../src/agent/session.js'
import type { Attachment } from '../src/protocol.js'

const img: Attachment = { name: 'photo.jpg', mimeType: 'image/jpeg', dataBase64: 'aW1n' }

function newSession(): Session {
  return new Session({ onEvent: () => {}, onSummary: () => {} }, { cwd: '/tmp/ccgo-test' })
}

describe('附件随消息发送', () => {
  it('queue 模式：用户条目携带附件', () => {
    const session = newSession()
    session.prompt('看这张图', 'queue', [img])
    const snapshot = session.snapshot()
    const user = (snapshot as { items: { kind: string; attachments?: Attachment[] }[] })
      .items.find((it) => it.kind === 'user')
    expect(user?.attachments).toEqual([img])
  })

  it('interrupt 模式（运行中）：附件入列且不打断调用崩溃', () => {
    const session = newSession()
    // 助手消息把 phase 推到 running（无真实 query，currentAbort 为 null）。
    session.ingest({
      type: 'assistant',
      parent_tool_use_id: null,
      session_id: 'sid',
      message: { role: 'assistant', content: [{ type: 'text', text: '工作中' }] },
    } as unknown as SDKMessage)
    expect(session.currentPhase).toBe('running')
    session.prompt('插一张图', 'interrupt', [img])
    const snapshot = session.snapshot()
    const user = (snapshot as { items: { kind: string; text: string; attachments?: Attachment[] }[] })
      .items.find((it) => it.kind === 'user' && it.text === '插一张图')
    expect(user?.attachments).toEqual([img])
  })

  it('SDK 回显混合块（文本+图片）不产生重复条目', () => {
    const session = newSession()
    session.prompt('看这张图', 'queue', [img])
    const before = (session.snapshot() as { items: unknown[] }).items.length
    session.ingest({
      type: 'user',
      parent_tool_use_id: null,
      message: {
        role: 'user',
        content: [
          { type: 'text', text: '看这张图' },
          { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'aW1n' } },
        ],
      },
    } as unknown as SDKMessage)
    const after = (session.snapshot() as { items: unknown[] }).items.length
    expect(after).toBe(before) // echo-guard 按文本键命中，丢弃回显
  })

  it('纯文本 prompt 行为不变（无 attachments 字段）', () => {
    const session = newSession()
    session.prompt('普通消息', 'queue')
    const user = (session.snapshot() as { items: { kind: string; attachments?: Attachment[] }[] })
      .items.find((it) => it.kind === 'user')
    expect(user?.attachments).toBeUndefined()
  })
})
