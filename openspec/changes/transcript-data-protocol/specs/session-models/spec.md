# Spec Delta

## Purpose

手机端可见并可选切换 Claude Code 的模型：daemon 从 Agent SDK 收集可用模型目录下发，App 按会话选择，旧环境降级为自由输入。

## ADDED Requirements

### Requirement: 模型目录下发
daemon SHALL 从 SDK（init 消息与 supportedModels）缓存可用模型目录并提供查询；当前无会话初始化信息时 SHALL 允许触发一次探测获取目录。目录 MUST 至少含模型标识与显示名。

#### Scenario: 查询模型目录
- **WHEN** App 请求模型目录
- **THEN** 返回模型列表（标识 + 显示名），含会话当前使用的模型

#### Scenario: 旧 CLI 降级
- **WHEN** daemon 所连 CLI 不支持模型目录
- **THEN** 返回空目录而非报错，App 侧降级为自由输入

### Requirement: 按会话切换模型
App SHALL 在聊天页提供模型选择入口，展示当前模型并从目录中选择；选择后经既有 session.configure 生效，会话摘要中的模型 MUST 反映切换结果。目录为空时 SHALL 提供自由输入。

#### Scenario: 切换模型
- **WHEN** 用户在模型面板选择另一个模型
- **THEN** 后续回合使用新模型，聊天页头部显示的模型随之更新

#### Scenario: 空目录自由输入
- **WHEN** 模型目录为空且用户输入模型标识确认
- **THEN** 该标识经 configure 生效，摘要回显
