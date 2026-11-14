// task 1.2：init 捕获（模型/指令目录/终端过滤）与 result 用量提取的单元
// 测试，含旧 CLI 缺字段降级。SDK 消息走 ingest() 测试缝，不启动 CLI。
import { describe, expect, it } from 'vitest'
import type { SDKMessage } from '@anthropic-ai/claude-agent-sdk'
import { Session } from '../src/agent/session.js'

function newSession(): Session {
  return new Session({ onEvent: () => {}, onSummary: () => {} }, { cwd: '/tmp/ccgo-test' })
}

function initMessage(fields: Record<string, unknown>): SDKMessage {
  return {
    type: 'system',
    subtype: 'init',
    session_id: 'sid-1',
    ...fields,
  } as unknown as SDKMessage
}

function resultMessage(fields: Record<string, unknown>): SDKMessage {
  return {
    type: 'result',
    subtype: 'success',
    ...fields,
  } as unknown as SDKMessage
}

describe('init 捕获', () => {
  it('记录实际模型并过滤终端专属指令', () => {
    const session = newSession()
    session.ingest(
      initMessage({
        model: 'claude-sonnet-5',
        slash_commands: ['/compact', 'clear', '/exit', 'resume'],
        terminal_slash_commands: ['/exit'],
      }),
    )
    expect(session.model).toBe('claude-sonnet-5')
    expect(session.slashCommands.map((c) => c.name)).toEqual(['compact', 'clear', 'resume'])
  })

  it('旧 CLI 缺字段：模型保持原值、指令目录为空', () => {
    const session = newSession()
    session.ingest(initMessage({}))
    expect(session.model).toBeNull()
    expect(session.slashCommands).toEqual([])
  })

  it('summary 随捕获更新模型', () => {
    const session = newSession()
    session.ingest(initMessage({ model: 'claude-opus-5' }))
    expect(session.summary().model).toBe('claude-opus-5')
  })
})

describe('result 用量提取', () => {
  it('成功结果填充 usage（含 contextTokens 计算）', () => {
    const session = newSession()
    session.ingest(
      resultMessage({
        usage: {
          input_tokens: 100,
          output_tokens: 40,
          cache_creation_input_tokens: 10,
          cache_read_input_tokens: 900,
        },
        total_cost_usd: 0.25,
      }),
    )
    expect(session.summary().usage).toEqual({
      inputTokens: 100,
      outputTokens: 40,
      cacheReadTokens: 900,
      cacheCreationTokens: 10,
      contextTokens: 1010,
      costUsd: 0.25,
    })
  })

  it('出错结果不更新 usage；无回合时 summary 无 usage 字段', () => {
    const session = newSession()
    session.ingest({ type: 'result', subtype: 'error_during_execution' } as unknown as SDKMessage)
    expect(session.usage).toBeNull()
    expect(session.summary().usage).toBeUndefined()
  })

  it('成功结果缺 usage 对象不抛错（旧 CLI 降级，评审回归）', () => {
    const session = newSession()
    expect(() =>
      session.ingest(resultMessage({ total_cost_usd: 0 })),
    ).not.toThrow()
    expect(session.usage).toEqual({
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
      contextTokens: 0,
      costUsd: 0,
    })
  })
})
