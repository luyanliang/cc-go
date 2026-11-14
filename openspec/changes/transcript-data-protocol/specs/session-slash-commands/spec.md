# Spec Delta

## Purpose

把 Claude Code 的斜杠指令目录带到手机：daemon 从 init 消息缓存指令清单（过滤终端专属指令）下发，App 输入区按 `/` 前缀弹出指令面板，选中即作为消息文本发送。

## ADDED Requirements

### Requirement: 指令目录下发
daemon SHALL 从 SDK init 消息缓存会话可用的斜杠指令清单，剔除终端专属指令（terminal_slash_commands）后下发；指令清单 MUST 随会话初始化更新。

#### Scenario: 目录随会话下发
- **WHEN** App 打开一个已初始化的会话
- **THEN** 可获取该会话可用的斜杠指令清单

#### Scenario: 终端专属指令被剔除
- **WHEN** SDK 上报的指令包含终端专属指令
- **THEN** 下发目录中不包含这些指令

### Requirement: 斜杠指令面板
输入区文本以 `/` 开头时 SHALL 弹出指令面板：按前缀过滤、点选补全指令名；指令作为普通消息文本发送，发送后 SHALL 出现在转录中。

#### Scenario: 前缀过滤与补全
- **WHEN** 用户输入 `/com` 且目录中有 /compact
- **THEN** 面板过滤显示匹配指令，点选后输入补全为该指令

#### Scenario: 发送指令
- **WHEN** 用户发送 `/compact`
- **THEN** 指令文本作为用户消息发送并出现在转录中

#### Scenario: 无目录不出面板
- **WHEN** 会话没有指令目录（旧 CLI 或未初始化）
- **THEN** 不弹出面板，输入与发送不受影响
