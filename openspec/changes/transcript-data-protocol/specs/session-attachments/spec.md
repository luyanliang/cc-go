# Spec Delta

## Purpose

让手机把图片作为附件随消息发给 Claude Code：选择、预览、发送、入模与转录回显全链路，附件数据与文本同帧送达且在转录中可追溯。

## ADDED Requirements

### Requirement: 附件选择与发送
App SHALL 支持在输入区添加图片附件（相册选择与拍照），发送前显示附件预览、可逐个移除；带附件的消息发送时，附件 MUST 随文本一并提交。过大的图片 SHALL 在发送前缩放压缩至限定体积以内。

#### Scenario: 相册选图并发送
- **WHEN** 用户从相册选择一张图片、输入文本并点发送
- **THEN** 消息与附件一起提交，转录中出现带附件标记的用户消息

#### Scenario: 发送前移除附件
- **WHEN** 用户在预览区移除某张附件后发送
- **THEN** 该附件不随消息提交，其余附件正常发送

#### Scenario: 超大图片自动压缩
- **WHEN** 用户选择的图片超过限定体积
- **THEN** 发送前自动缩放压缩，发送的是压缩后的数据

### Requirement: 附件入模
daemon SHALL 把随消息提交的图片附件组装为 Messages API image block，与文本同一条 user 消息送入 Claude Code；附件 MUST NOT 改变消息排队的既有语义（空闲即发、运行中排队）。

#### Scenario: 附件随消息入模
- **WHEN** daemon 收到带附件的 session.prompt
- **THEN** SDK 收到的 user 消息 content 同时包含文本块与图片块

#### Scenario: 运行中带附件排队
- **WHEN** 会话运行中用户发送带附件的消息
- **THEN** 消息连同附件排队，当前轮结束后一并送出

### Requirement: 附件回显
带附件的用户消息 SHALL 在转录中回显附件（可查看图片）；快照与实时合并 MUST 保持既有幂等语义。

#### Scenario: 转录回显附件
- **WHEN** 一条带附件的用户消息出现在转录中
- **THEN** 消息气泡展示附件缩略图，点开可查看原图

#### Scenario: 快照包含附件
- **WHEN** 用户重新进入该会话加载快照
- **THEN** 历史消息的附件照常回显
