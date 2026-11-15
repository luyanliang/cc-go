# Design

## Context

现状与约束（动机见 proposal.md - Why，行为契约见各 spec delta）：

- `app/lib/ui/chat/` 现为四层：`chat_screen.dart`（Scaffold+AppBar）、`chat_rows.dart`（行装配，`ListView.builder` + StreamBuilder + "距底 120px"启发式贴底）、`composer.dart`、`render/`。行推导在纯 Dart 的 `chat_row_model.dart`。
- 主题现为 M3 默认语义色，无共享 token 层；此前已有一次"语义状态/等宽/徽章收敛为共享层"的提交（`scripts/check.sh` 同款共享件风格），本 change 在其上继续。
- `transcript-data-protocol`（18/19）提供附件、工具原始输出、用量、模型目录、斜杠目录数据；本 change 不动 wire 协议，daemon 零改动。
- `reference/dsh-Go-main` 为 AGPL：只借鉴结构思路与视觉规格（注释中的 ASCII 线框图），不拷贝代码。其关键手法均有明确的实现描述：居中锚定（`chat_list.dart`）、玻璃分级（`glass.dart`/`surfaces.dart`）、OKLCH（`palette.dart`/`oklch.dart`）、pacer（`stream_pacer.dart`）、宽度协商（`chat_header.dart`）、密钥遮罩（`secret_mask.dart`）。
- 项目惯例：纯 Dart 核心无 Flutter 依赖并可测；UI 只在边缘。

## Goals / Non-Goals

**Goals:**

- 视觉 token 层先立：后续每个行形态/交互批次都在它之上工作，而不是各写各的样式。
- 居中锚定是结构性改造，与"内容滚到玻璃下"共用一次列表重构，避免列表被改两遍。
- 纯 Dart 可测的部分（pacer、修复、公式判定、密钥扫描、行推导扩展、宽度协商）全部下沉为无 Flutter 依赖的核心。

**Non-Goals:**

- 不改 daemon 与 wire 协议（proposal 已列"不做"清单）。
- 不做全局换肤：token 层 app 级建立，但本 change 只把聊天窗口迁过去；会话列表/配对页等页面后续单独迁。
- 不做 dsh_ui 插件系统、宠物/鲸尾吉祥物等 DSH 产品特有物。
- 不引入本地语音模型（SenseVoice 级别），只用系统识别引擎。

## Decisions

### D1 主题层：token 扩展 + 手工 ColorScheme 并存

保留 `MaterialApp`，但 `ColorScheme.light/dark` 改为手工构造（OKLCH 推导的固定色值，不用 `fromSeed`）；玻璃表面、动效时长、圆角规格以 `ThemeExtension` 承载，经 `context.tokens` 读取。理由：既有 M3 组件（SnackBar、RadioListTile 等）继续工作；玻璃/动效等 M3 没有的概念有归属。替代方案（完全脱离 M3 自建体系）会迫使人写一遍全部基础组件，放弃。

### D2 玻璃分级渲染：chrome/sheet 真模糊，card 近似

chrome（顶栏/输入条/浮动键）与 sheet（弹层）用 `BackdropFilter` 真模糊；card 级（审批卡、提问卡、气泡内的引用块）用半透明填充 + 发丝描边 + 顶边高光近似，不挂 `BackdropFilter`。理由：Android 上大面积 `BackdropFilter`（每帧对列表区域做模糊）是已知性能坑；dsh-Go 的玻璃解剖本身就是分级规格，card 级近似在视觉上损失很小。

### D3 连续曲率圆角：优先 `ContinuousRectangleBorder`

Flutter 内置 `ContinuousRectangleBorder` 已是连续曲率超椭圆，先用它；不自实现 path、不引第三方 squircle 包。视觉规格（哪些圆角用连续曲率、半径值）进 token 层统一，避免各处随取随用。

### D4 居中锚定：CustomScrollView 双段 sliver + 中心锚点

列表改为 `CustomScrollView`：锚点条目把内容切成 before/after 两段 sliver，`CustomScrollView` 的 `center` 参数天然支持双向增长不移动视点；贴底跟随用自定义滚动物理/后帧修正实现（dsh-Go `_FollowPhysics` 的思路，独立实现）。锚点选择：贴底时锚定为"最后一条"，用户上翻时锚定"视口中心所在条目"（以既有行 `ValueKey` 为键）。行渲染继续复用现装配逻辑。这是本 change 风险最高的一块，任务上独立成批、先行验收。替代方案（继续 ListView + 手动 `jumpTo` 补偿）在历史分页与流式并发下补偿难以做对，放弃。

### D5 Pacer 与修复下沉纯 Dart

- pacer：字符预算器（每帧按已流逝时间发放预算，落后加速，积压超上限直接放行），纯 Dart 类 + 帧驱动接口，核心逻辑无 Flutter 依赖可测。
- stream repair：在现有 `render/stream_repair.dart` 上扩展未闭合粗体/链接/标题的规则，保持"幂等 + 完成后整体替换"语义；纯字符串函数可测。
- LaTeX 判定：`$…$`/`$$…$$` 是否为公式的判定按 remark-math 约定为纯函数（转义/空白/成对检查），gpt_markdown 自带的 math 引擎负责渲染。
- 密钥遮罩：单遍扫描纯函数（模式集：API key 形态、`sk-` 前缀、PEM 片段、URL 内嵌凭据），在行模型层产出"显示片段 + 遮罩区间"，渲染层只按区间画 chip；原文数据不动。
- 宽度协商：给定可用宽度与文案 → 各胶囊让出等级的纯函数 + 一个按等级渲染的 widget，可测。

### D6 mermaid：本地打包渲染引擎

`mermaid.min.js` 打包进 assets，点开时才加载 WebView（`webview_flutter`），离线可用。替代方案（CDN 多源回退）省 APK 体积但手机场景网络不可控、失败率高；本 change 只在用户主动点开时付 WebView 成本，APK 增加 ~1–2MB 可接受。

### D7 语音：系统识别引擎单路径

`speech_to_text`（Android 系统识别，RECORD_AUDIO 运行时权限）单路径；不做本地模型、不做部分结果波形。不可用即回退普通发送键 + 提示。理由：cc-go 的场景是"对着手机描述任务"，系统识别够用；本地模型是 ASR 产品级投入，超范围。

### D8 草稿持久化：复用既有本地存储设施，按 sessionId 键

草稿与引用上下文进既有本地持久化通道（与 host entries 同一套设施即可），键为会话 id；不进安全存储（草稿非敏感，且密钥遮罩另有机制）。发送成功即清除；只读会话不存。

### D9 行推导扩展集中在 `chat_row_model`

脚注行、活动胶囊所需的"当前动作"推导、遮罩区间、宽度协商输入全部在纯 Dart 行推导层产出；widget 层只消费。保持"快照+实时幂等合并"语义不动，新行类型沿用条目 id 键。

## Risks / Trade-offs

- [居中锚定重构回归既有滚动行为（贴底、分组折叠、历史分页）] → 独立成第一批任务，先补当前行为的回归测试再动结构；真机验收流式 + 上翻双场景。
- [BackdropFilter 在低端机掉帧] → D2 分级限制使用面；真机用 flutter run --profile 检查列表滚动帧率。
- [speech_to_text 在各厂商 ROM 表现不一] → 单路径 + 显式降级（spec 已要求可理解原因）；不阻塞文字输入主路径。
- [mermaid WebView 内存与兼容] → 仅点开时创建、退出即销毁；渲染超时兜底为源码展示。
- [视觉重构波及面大，与 in-flight change 冲突] → `transcript-data-protocol` 已 18/19，任务要求以其落地后的基线起步；本 change 不碰 wire 协议避免双向冲突。
- [AGPL 边界] → 对照 dsh-Go 实现时只参照其行为规格与注释图示；代码独立实现，评审时对照"结构思路"而非逐行。

## Migration Plan

按 token 层 → 列表结构 → 行形态 → 交互 → 渲染 → 输入区分批落地，每批过 `bash scripts/check.sh` + 真机验收（`docs/VERIFICATION.md` 追加条目）；token 层第一批先行，后续批次依赖它。任一批次可独立回滚（纯 app 侧改动，无数据迁移；草稿存储新增键随卸载消失）。

## Open Questions

（无——mermaid 打包 vs CDN、语音引擎路径两个候选问题已在 D6/D7 决定并记录理由。）
