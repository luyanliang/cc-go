# 聊天界面高保真复刻规格（对齐 dsh-Go）

> 目标：把 cc-go 的聊天界面（`app/lib/ui/chat/` + `app/lib/theme/`）复刻到参考项目 dsh-Go（`reference/dsh-Go-main/app/lib/`）的视觉与交互水准。本文档是**数值级规格 + 验收清单**：每一条都带目标数值，实现时逐条打勾，防止"复刻不全"。
>
> 来源：2026-11 对两个代码库的多 Agent 逐文件盘点。本文只记"目标值 vs 现状"，机制性内容（滚动锚定、流式合并等）已在 `docs/ARCHITECTURE.md`，不重复。
>
> 路径约定：下文 `dsh/…` 指 `reference/dsh-Go-main/app/lib/`，`cc/…` 指 `app/lib/`。

## 实施进度

- **2026-11-15：composer 胶囊化 + 滚动升级 + 小件完成（复刻主体收尾）**：
  - **Composer 玻璃胶囊化**（§16 主体）：输入条 = chrome 玻璃（radius 28）+ **36 圆键端盖**（主键主色实心 ↑20、次键 onSurface@0.06 淡底、禁用 0.12/0.38、Pressable 按压缩放）；文字 15/1.45、borderless、1–6 行；斜杠面板玻璃化（card 级 + md14）；外层 padding 对齐 dsh（12/0/12/8）。运行中仍保留打断键 + 发送键（队列语义，不照搬 dsh 的 busy 单键）。
  - **滚动升级**（§15）：**FollowPhysics**（`widgets/follow_physics.dart`）—— 贴底且无手势时**同一次布局内**追到新末尾（替换帧后 postFrame 的一帧延迟）；`TranscriptListView` 开 `keyboardDismissBehavior.onDrag`。
  - **回底键**（§15）：44 chrome 玻璃圆钮（blur:false，不每帧重采样）、icon 22、**双阈值迟滞 160/24**、显隐 `AnimatedScale 0.6→1 + quick` 淡入、**离开期间新内容 9px 主色角标**（圆心在 45° 边上 top/right 2）；权限/活动胶囊保留在输入条上方（dsh 的胶囊变体职责由它们承担）。
  - **小件**（§10/§9）：复制按钮图标**原地交叉淡变 160ms、保持 1200ms**；**链接白名单**（只放行 http/https/mailto，tel:/intent:/javascript: 封禁）；**行内 markdown 图片**（data: URI 解码 / http(s) 网络图，inline 限高 **480** 等比缩、squircle md14 裁切、失败占位块）。
  - **空状态鲸尾**（§18）：dsh 精灵图资产（assets/whale/，312K）+ `whale_tail.dart` 整体移植（四档游速/交叉淡变/速度缓动，空态用 still 帧、whaleColorFor 明暗两色）。
  - 剩余未做（记录在案，后续按需）：_ChatLayout 六 slot 重排 + overlap 6.0 + BackdropVeil 同帧联动（现 Stack+scrim 方案已实现"内容穿玻璃之下"，视觉近似）；header 三件套结构（≡/标题胶囊/新对话钮）；流式 glide（灵动档专属，FollowPhysics 已覆盖非灵动路径）；prepend 同帧偏移校正；composer 单↔双行 RenderBox 插值、Ctrl+Enter、双 Esc、长按发送三选 sheet；`@` mention、dock 条、产物预览、trajectory/usage sheet（§20 声明的后置项）。

- **2026-11-15：思考窗口 + 工具状态条 + 详情代码井完成**（§12/§13）：
  - **思考标签扫光**：`widgets/thinking_ticker.dart` ThinkingLabel —— lead 600ms / sweep 1s / period 4s，ShaderMask 三色 `[muted, bright, muted]` 从左外走到右外，**同屏只扫一条**（静态 `_owner` 在计时器里接手）。
  - **思考实时窗口**：ThinkingTicker 恒高 **3 行**、写满一行 **linear 匀速**上移（AnimatedContainer + translation），尾部最多 2000 字参与排版、去 `**`、压空行；不足三行贴顶。
  - `_ThinkingSection` 重排：扫光标签（流式）/ 首行预览（收起，去 `**`）+ 流式窗口常驻 + `ExpandReveal` 展开全文；**一轮结束强制收回手动展开**；流式图形块走主色。原 120 高贴底滚区保留为展开全文容器。
  - **工具行状态条**（§13）：running → 14px spinner（strokeWidth 1.8）、error → ✕16、denied/awaiting → 小字标签、**done → 安静（无行尾）**。
  - **ProcessDetail 代码井化**：CodeWell 底 + squircle md14 + 0.5px 边（随明暗）+ StreamThread 细线 rail。
  - 测试适配：thinking_section（收起预览/流式窗口语义）、tool_views（done 安静）、permission_card（运行中 = spinner）。

- **2026-11-15：行组件（气泡几何 + 间距阶梯 + Markdown 主题）完成**：
  - **用户气泡**（§8）：右对齐最大宽 **82%**、padding `h16 v8`、squircle **lg20**、primaryContainer 底；**附件移到气泡上方**右对齐（不塞进气泡）；排队气泡同几何。
  - **助手正文**：无框全宽裸排（原 12/48 缩进移除），垂直节奏归阶梯、水平 gutter 16。
  - **行间距阶梯**（§4）：换轮 **24** / 同轮 8 / 相邻过程行 **0** / 卡片 **12** / 脚注 **4**，在 TranscriptListView 按 prev/cur 行型计算 `_gapBefore`；过程行/权限卡的水平 margin 统一 16（gutter）。
  - **Markdown 主题**（§9）：`GptMarkdownThemeData` 挂 dsh 规格 —— 标题阶 h1 20→h6 15 全 w600、hr 0.5px/上下 12、行内代码 JetBrainsMono ×0.875 + 0.5px 边框 + radius 6、blockquote bar 3px 圆角 2、bullet 5px、表格 0.5px 方角 + cellPadding h12v8 + `TableOverflow.scroll` + 表头浅底、**GitHub alert 五档**（note=info/tip=success/important=暮紫/warning/caution=danger，radius 10，padding fromSTEB(12,10,14,10)，titleGap 4）、`<mark>` 警示底、链接色主色（gpt_markdown lock 已在 1.4.1，走 `GptMarkdownTheme` InheritedWidget + 静态双主题实例）。
  - 未含（后续）：思考恒高 3 行窗口 + 扫光、工具详情代码井化、composer 胶囊化、_ChatLayout overlap 6.0 + veil、_FollowPhysics/glide、行内 markdown 图片（限高 480）、链接白名单、回合脚注样式对齐。

- **2026-11-15：B 级自包含件 + 渲染层完成**：
  - 新增自包含件（`ui/widgets/`）：smooth_size / bleed / edge_fade（HorizontalEdgeFade + EdgeFadeScrollBehavior）/ overscroll_forwarder / expand_reveal / streaming_cursor / typing_indicator / pressable；`ui/chat/widgets/`：stream_row（24+8 解剖、minHeight 32、Bleed 8、StreamThread 细线 rail、StreamChevron）/ stream_motion（StreamPress 0.97 + StreamFadeIn 错峰 30ms rise 8）。
  - 过程行解剖切换：`process_rows.dart` 的 ProcessLine/ProcessDetail 改走 StreamRow/StreamThread（细线 rail x=12），水平 padding 12→16（gutter）。
  - 代码块：github-dark → **Mist 主题**（明暗两套，`theme/highlight_theme.dart`）；代码井随明暗（CodeWell）；squircle md14 + 0.5px 边框 + 36 标题条 + AppMono.label 语言标签 + HorizontalEdgeFade + OverscrollForwarder；**流式 250ms 节流高亮**（冷却期新增尾部纯等宽拼接）。
  - 流式三件套：① 同文字复用 GptMarkdown 实例；② `▍` → sentinel `` + inlinePatterns → RepaintBoundary StreamingCursor（2.5px/1000ms 呼吸）；③ 正文 bodyMedium → **bodyLarge 16/1.65**（gpt_markdown lock 已是 1.4.1）。
  - 测试适配：光标断言改 `StreamingCursor`；6 处流式态 pumpAndSettle 改多帧 pump（pacer 首帧只放积压上限 + 光标无限呼吸永不落定）。
  - 未含（后续阶段）：reveal 渐显模式（灵动档 GptMarkdownAnimation，与现有 pacer 二选一待定）、GitHub alert/表格 260px/details 折叠/链接白名单/行内 markdown 图片（markdown_body 深度改造）、思考恒高 3 行窗口、工具详情代码井化、_FollowPhysics/glide、composer 胶囊化。

- **2026-11-15：A 级完成**（§1–§6 主体）：`theme/` 新增 squircle/motion/spacing/typography，palette 与 tokens 重写为 dsh 数值（页面渐变、五档面色、四级文字、带蓝阴影基色、语义/diff 色、玻璃三级 chrome18/1.3·sheet24/1.4·card 不模糊、0.5px 发丝 + 45% rim、even-odd 外阴影、BackdropGroup、blurEnabled）；`ui/widgets/glass.dart` 重写为 dsh 玻璃解剖（新增 pressable.dart）；JetBrainsMono 四字重打包并接入五档等宽（app_style.dart）；main.dart 挂 BackdropGroup + AppMotionScope；圆角全部换 `RoundedSuperellipseBorder`。
  - 未含（后续阶段）：ANSI 16 色表、toolContainers/identity 色、输入框聚焦描边/dialog maxWidth 组件主题、用户字号缩放、行间距阶梯落位、StreamFadeIn/StreamPress 行动画、SlidingGlass。
  - `AppColors` 静态入口暂为亮色值，暗色走 `context.tokens.semantic`，调用点在阶段 3–4 迁移后退役。
  - 测试更新：shared_visuals_test（Stadium/RoundedSuperellipseBorder）、widget_test（waiting 色）对齐新视觉契约。

## 0. 搬运策略（先读）

三个来源层级，对应三种做法：

| 层级 | 内容 | 做法 |
|---|---|---|
| A. 视觉规格 | dsh/`ui/theme/` 全部 token（调色/字体/形状/间距/动效/玻璃/高亮主题） | **数值搬运**：灌进 cc-go 现有 token 层（`cc/theme/`），不引入 dsh 的 ThemeExtension 体系，避免与 `CcTokens` / `theme_tokens_test` 双轨并存 |
| B. 自包含组件 | dsh 的 streaming_cursor、typing_indicator、expand_reveal、smooth_size、bleed、edge_fade、overscroll_forwarder、stream_motion、stream_row 等 | **文件搬运 + 小改**：换 import、l10n 字符串中文化 |
| C. 深度耦合 | dsh/`chat_list.dart`(1739 行)、`chat_screen.dart`(2536 行)、`dsh_ui/`(约 1 万行)、tool_view 派生 | **只搬机制**（`_FollowPhysics`、`_JumpToBottom`、`_ChatLayout`、`_ChatTextScale`），业务接线按 cc-go 的 `deriveChatRows` / `ChatController` 重写；`dsh_ui/` 整体跳过 |

搬运策略已确认（2026-11-15）：**dsh-Go 代码可直接复制，无需 LICENSE 检查**；复刻先放宽约束、后续再优化调整。

搬运适配注意（每个 B 级文件都适用）：

- [ ] cc-go 全项目从 `material_ui` 包 import Material，不是官方 `material` —— 搬运文件批量替换 import
- [ ] dsh 走 l10n，cc-go 中文硬编码 —— 字符串就地中文化
- [ ] dsh 用 `RoundedSuperellipseBorder`（自写 squircle，随 theme 层一起搬）；cc-go 现有 `ContinuousRectangleBorder` 全部替换

---

## 1. 主题 / 调色

现状：cc/go 用 OKLCH(255°) 程序推导（`cc/theme/palette.dart`）；目标是 dsh 的手工色板 + OKLCH 推导并存的体系。

- [ ] **页面背景竖向渐变**：浅色 `#EBF1FE → #F6F7FC`（top→bottom）；深色 `#1D222C → #1B1C23`（dsh/`palette.dart:35-38, 72-74`）
- [ ] **面色五档**（浅色）：`mistLowest #FBFCFF / mistLow #F6F9FE / mistContainer #EEF1F9 / mistHigh #E7EBF4 / mistHighest #DFE4EE`；深色五档 `#14171E / #232730 / #272C36 / #2D323C / #343944`（dsh/`palette.dart:44-48, 74-79`）
- [ ] **文字四级**（浅色）：ink `#1E232E` / inkMuted `#4F5562` / inkFaint `#646974` / inkGhost `#A1A5AC`；深色 paper `#E6E9F0` / paperMuted `#B6BBC5` / paperFaint `#9A9EA9` / paperGhost `#656971`（dsh/`palette.dart:51-60, 82-85`）
- [ ] **细线**：`ruleLight #DCE0E8` / `ruleDark #343841`；`outlineLight #7E838D`（dsh/`palette.dart:63-66`）
- [ ] **阴影基色带蓝**：浅 `#0B152D`、深 `#03060D`，全部投影用这个基色，不用纯黑（dsh/`palette.dart:69, 87-88`）
- [ ] **语义色**（不随明暗翻转到过深）：success `#337250`(浅)/`#8BCCA6`(深)、warning `#936123`/`#E6BD7C`、info `#2971A7`/`#8CBDE8`；danger 砖玫红 `#A54743` 系；暮紫 tertiary `#6B578F` 系（dsh/`semantic_colors.dart:43` 起、`palette.dart:101-120`）
  - 现状：cc/`app_style.dart` 用 `Colors.green/blue/amber/...` —— 替换
- [ ] **diff 四色**：浅 addBg `#DCF4E3`/addFg `#1F613C`/delBg `#FFE4E2`/delFg `#923A37`；深 `#1C3424/#98D5AC/#422423/#F2A7A1`（dsh/`semantic_colors.dart:199-203, 289-293`）
- [ ] **16 色 ANSI 表**明暗两套（dsh/`semantic_colors.dart:210-227, 300-317`）；现状：cc/`render/ansi.dart` 16 色取模近似 —— 换表
- [ ] **工具类别色 toolContainers 8 组**（terminal/read/edit/search/web/agent/plan/neutral，按 `ToolTone`）（dsh/`semantic_colors.dart:249-268`）；现状：cc 只有语义状态色
- [ ] **身份色 identity 8 组** + FNV-1a 稳定索引（dsh/`semantic_colors.dart:171, 228-247`）
- [ ] **品牌/主色**：dsh 默认 mist（DeepSeek 蓝 `#4D6BFE` = OKLCH(0.59, 0.22, 270) 压彩度到 0.125）；cc-go 保留自己的雾蓝 primary 即可，但**思考图形块、发送实心键、光晕**等强调位要用同一主色（现状已大致如此，验收对色）
- [ ] **M3 铁律**：层次靠材质不靠阴影 —— 所有组件 elevation 0、`surfaceTint` 透明；细线 0.5–1px 是骨架；连续圆角全走 squircle（dsh/`app_theme.dart:82-88`）
- [ ] 组件主题细节：卡片 = 半透明白玻璃 + 0.5px 细线 + 零阴影；输入框聚焦描边 1.6 主色；FilledButton 最小 `64×50`；dialog maxWidth 560；bottomSheet dragHandle `36×4`；开关 iOS 式浅色圆钮；tooltip waitDuration 400ms；`textSelection` selectionColor `primary @ 0.24(浅)/0.28(深)`（dsh/`app_theme.dart:154-213, 315, 335, 455-491`）

## 2. 字体（typography）

现状：cc/`app_style.dart` 系统等宽三档（12/12/13），正文 `bodyMedium`。

- [ ] **打包 JetBrainsMono**（Regular / Italic / Medium w500 / Bold w700），`monoFamily = 'JetBrainsMono'`（dsh/`typography.dart:40` + pubspec fonts）
- [ ] **禁连字**：等宽样式一律 `[FontFeature.disable('calt'), disable('liga')]`（dsh/`typography.dart:44`）
- [ ] 等宽 fallback `['monospace', 'Noto Sans Mono CJK SC', 'Noto Sans CJK SC']`（dsh/`typography.dart:47`）
- [ ] **等宽五档**：正文代码 `13/1.55`；monoSmall 工具输出 `12/1.5`；monoLabel 标签 `12/1.35`；工具摘要 `12.5`；行内代码 = 正文 × **0.875**（dsh/`typography.dart:76-93`、`markdown_body.dart`）
- [ ] **聊天正文 16/1.65**（bodyLarge），流式→完成不跳字号；思考全文 = 0.9× 字号 + onSurfaceVariant（dsh/`typography.dart:100`、`assistant_message.dart`）
- [ ] **字重只用 400/600 两档**（国产 ROM 只带 Regular）（dsh/`typography.dart:17-21`）
- [ ] 每个样式 `withGlyphLocale` 钉 locale（英文界面也传 `zh_CN`）+ `leadingDistribution: even`（dsh/`typography.dart:51-73, 141-191`）
- [ ] M3 字阶表照搬：displaySmall 28/1.25 w300、headlineMedium 22/1.3 w600、titleLarge 18/1.4、titleMedium 16/1.45、titleSmall 14/1.45、bodyLarge 16/1.65、bodyMedium 14/1.55、bodySmall 12/1.5、labelLarge 14 w600、labelMedium 12 w600、labelSmall 11；display 28/w300、eyebrow 12/w600/letterSpacing 0.8、tabular 等宽数字（dsh/`typography.dart:106-137`）
- [ ] 用户字号缩放：只对聊天内容包 `MediaQuery(textScaler)` 乘用户系数（dsh/`chat_screen.dart:2501-2536`）

## 3. 形状 / 圆角

现状：cc/`tokens.dart` 用 `ContinuousRectangleBorder` + 散点圆角。

- [ ] **搬运 dsh/`theme/squircle.dart`** 的 `RoundedSuperellipseBorder`，替换全部 `ContinuousRectangleBorder`
- [ ] **五档圆角**：xs **6**（行内代码/角标）、sm **10**（Chip/工具图标块/菜单项）、md **14**（卡片/代码井/输入框/菜单）、lg **20**（用户气泡/审批卡）、xl **28**（composer/底部弹层/对话框）+ pill = Stadium（dsh/`shapes.dart`）
- [ ] `AppShape.bubble = SquircleBorder(radiusLg)`、`AppShape.sheet = 顶部 xl`、`outlined(color, {radius md, width 1})`

## 4. 间距阶梯

现状：cc 无统一阶梯，过程行 `fromLTRB(12,2,12,2)`。

- [ ] **AppSpace**：xxs 2 / xs 4 / sm 8 / md 12 / lg 16 / xl 20 / xxl 24 / xxxl 32；`gutter 16`（页面水平留白）；`inTurn 8`（同轮内工具行↔正文）；`betweenTurns 24`（换轮）；`readingWidth 720`（正文最大阅读宽度，平板居中）；`floatInset 12`；`floatingWidth = 696`（dsh/`shapes.dart:60-88`）
- [ ] **行间距阶梯**（`_gapBefore` 规则，dsh/`chat_list.dart:1086`）：换轮 **24** / 同轮 **8** / 相邻过程行 **0** / 卡片 **12** / 脚注 **4**
- [ ] 每行外层 padding `EdgeInsets.fromLTRB(16, gap, 16, 0)`（dsh/`chat_list.dart:1043`）

## 5. 玻璃效果

现状：cc/`glass.dart` + `tokens.dart` GlassSpec 已有三级（chrome blur18 / sheet blur24 / card 不模糊），缺以下细节。

- [ ] chrome：浅色 fill `white @ 0.70`（fallback `mistLowest @ 0.96`）、hairline `shadowInk @ 0.08`、rim `white @ 0.85`、**blurSigma 18 + saturation 1.3**、阴影 `[ink@0.08 blur24 offset(0,8), ink@0.05 blur3 offset(0,1)]`；深色 fill `smoke #292E39 @ 0.72`、saturation 1.2、阴影 `black@0.35 blur24`（dsh/`surfaces.dart:174-236`）
- [ ] sheet：blurSigma **24 + saturation 1.4**、阴影 `ink@0.10 blur32 offset(0,8)`（dsh/`surfaces.dart:185-193`）
- [ ] card / pill 不模糊：浅 `white@0.62 / white@0.55`，深 `white@0.05/0.06`
- [ ] **发丝描边 0.5px**；顶边高光改为 **45% 渐隐的 `_GlassEdgePainter` 渐变**（rim stops `[0, 0.45]`），不是整条 1px 线（dsh/`glass.dart`）
- [ ] **投影用 even-odd painter 只画在形状外部**（`_GlassShadowPainter`，dsh/`glass.dart:254` 附近）
- [ ] **同屏真模糊 ≤3**；同层互不重叠的玻璃用 `BackdropGroup` 共享一次采样（dsh/`glass.dart`）
- [ ] **`blurEnabled` 总开关**：系统"减少透明效果"或低端机 → 近乎不透明 fallbackFill（dsh/`surfaces.dart`）
- [ ] **`settled` 机制**：弹层运动中不模糊，停稳后 120ms 内半透明填充渐变为玻璃（dsh/`glass.dart`）

## 6. 动效

现状：cc/`tokens.dart` MotionTokens 三档（150/280/2400ms，easeOutCubic）。

- [ ] 时长表：press **90**、quick **160**、standard **240**、collapse **280**、emphasized **340**、sheetIn **380**/sheetOut **260**、glassIn **120**、slow **480**、breath **2400**、page/push **300**、pushFluid **360**、stagger **30**（≤8 项错峰）、rise **8.0**、pressScale **0.97**（dsh/`motion.dart:16-163`）
- [ ] 曲线：std = `Easing.standard`；enter = emphasizedDecelerate；exit = emphasizedAccelerate；collapse = easeInOutCubic；**glide = `Cubic(0.32, 0.72, 0.0, 1.0)`**；sheetRise = `Cubic(0.2, 0.9, 0.25, 1.0)`（dsh/`motion.dart:45-166`）
- [ ] **弹簧体系**（`SpringDescription.withDurationAndBounce`）：press 150/b0、layout 350/b0、sheet 500/b0、fling 500/b0.15、release 320/b0.45、pop 380/b0.2、thumb 320/b0.15、**rise 420/b0.18**（刚发出的气泡从输入框升起）；`SpringCurve` 把弹簧转曲线；`settle` 带速度落位；`rubberBand` 橡皮筋（dsh/`motion.dart:97-203`）
- [ ] **`AppMotionScope` 灵动档分级**（InheritedWidget）+ "减少动画"适配（返回 Duration.zero）（dsh/`motion.dart:189` 起）
- [ ] 行入场动画：`StreamFadeIn` 淡入 + 上移 **rise 8.0** + 错峰 stagger 30ms；`StreamPress` 按压缩放 **0.97**（dsh/`widgets/stream_motion.dart`）
- [ ] 玻璃规格随主题切换一次性跳变，不逐帧插值（cc 已有，保留）

## 7. 布局骨架

现状：cc/`chat_screen.dart` Stack 全高内容 + 悬浮 chrome + scrim 渐变。

- [ ] `_ChatLayout`（MultiChildLayoutDelegate）六 slot：body / pluginOverlay / veil / header / palette / composer（dsh/`chat_screen.dart:2445`）
- [ ] **列表 overlap 6.0**：列表伸到输入条下面 6px，遮罩处已实心；`veilHeight = composer.height − 6` 写给 `BackdropVeil` **同帧生效**（无帧后 setState）（dsh/`chat_screen.dart`，"列表与输入条之间永远无缝"的关键）
- [ ] composer 外层 padding `fromLTRB(12, 0, 12, 8)`，SafeArea bottom 最少 8；宽屏限 `floatingWidth 696` 居中（dsh/`chat_screen.dart:1936`）
- [ ] 输入条上方胶囊堆（间距均 8，自上而下）：错误/通知横幅 → 余额横幅 → 安全模式 → 权限/生成模式胶囊 → dock（todo/goal/activity strip）→ 原生胶囊条；每个用 `SmoothSize` 平滑变高
- [ ] **横屏 + 键盘**：header 和 dock 折走（heightFactor + Opacity `(t−0.4)/0.6`），只留输入条；composer 最大行数按可用高度算（`可用×0.4/行高` clamp 2–6）（dsh/`composer.dart:160`、`chat_screen.dart`）

## 8. 气泡与行几何

- [ ] **用户气泡**：右对齐，最大宽 `constraints.maxWidth * 0.82`，padding `EdgeInsets.symmetric(horizontal: 16, vertical: 8)`，底色 `surfaces.userBubble`（**不是 primaryContainer**）+ squircle lg20；附件在气泡**上方**右对齐（不塞进气泡）；乐观气泡 Opacity 0.72（dsh/`user_bubble.dart:118-125`）
  - 现状：cc margin 48/padding 14,10/primaryContainer —— 全改
- [ ] **助手消息**：无框、无头像、全宽裸排，列宽受 `readingWidth 720` 约束（dsh/`assistant_message.dart:31`、`chat_list.dart:1054`）；现状：cc padding(12,4,48,4) 无阅读列宽
- [ ] **过程行解剖**（思考/工具/通知共用）：24 图形列 + 8 间距 + 文字列，最小高 **32**，展开内容左边 **1px 细线画在 x=12**（`_RailPainter`）（dsh/`widgets/stream_row.dart:19-44, 121`）；现状：cc `ProcessLine` 24+8 已同构，补细线 rail 与最小高 32
- [ ] 过程行高亮 Bleed 8；行头上下 padding 4（dsh/`tool_row.dart:62` 附近）

## 9. Markdown 渲染

两边都用 gpt_markdown；差异在封装深度。

- [ ] 升级 gpt_markdown 到 **^1.4.0**（cc 现 ^1.3.4；1.4 才有 reveal 动画 / InlinePattern / HtmlTag 钩子）
- [ ] 自定义 `GptMarkdownThemeData`：h1 20/1.4、h2 18/1.4、h3 16.5、h4 16、h5/h6 15（均 w600）；hr 0.5px `outlineVariant` 上下 12；行内代码 JetBrainsMono ×0.875、border 0.5、radius xs6、padding `h4 v1`；blockquote bar 3px 圆角 2；列表 bullet 5px；表格 borderWidth **0.5**、`Radius.zero`（上游方角 bug）、cellPadding `h12 v8`、单列上限 **260px**、`TableOverflow.scroll`（dsh/`markdown_body.dart:115-216`）
- [ ] **GitHub alert 五档**（note=info / tip=success / important=ansi[5] / warning / caution=danger），radius sm、padding `fromSTEB(12,10,14,10)`、titleGap 4；`<mark>` = warningContainer 底（dsh/`markdown_body.dart`）
- [ ] **HTML 只拦截 `details`/`summary`** 换成 `MarkdownDisclosure` 折叠块，其余交包默认（dsh/`markdown_body.dart:38-41`）
- [ ] **任务清单复选框**（`TaskBox` size 18/gap 4）与**自绘列表几何**（悬挂缩进，`MarkdownLists`）（dsh/`render/markdown_blocks.dart`）
  - 现状：cc 用自定义 ordered/unordered listBuilder 两列 gutter —— 换成 dsh 的悬挂缩进实现
- [ ] **链接安全白名单**：只放行 http/https/mailto；裸域名推断（文件后缀/网站后缀两套白名单）；`tel:`/`intent:` 封禁（dsh/`markdown_body.dart:309-436`）；现状：cc 无条件 `launchUrl`
- [ ] 表格预处理：表格前补空行、表头加粗（dsh/`render/table_syntax.dart`）
- [ ] 数学：`normalizeMath` 半截公式归一化；公式渲染回退引擎 `val_latex_flutter`（dsh/`markdown_math.dart`、`math_syntax.dart`）；现状：cc 有 math_guard（`$` 歧义守卫），保留并对照补 normalize
- [ ] **可选中文本**：`selectable: true`；代码块的 `SelectionArea` 套在横向滚动**外层**（避免 Android 吃掉横向拖动）（dsh/`code_block.dart:499`）
- [ ] **回复内图片**（markdown `![]()`）：工作区文件 / 网页 / data: URI / SVG；inline 限高 **480** 等比变窄；下载上限 20MiB；按显示尺寸 `ResizeImage(fit)` 解码；点击进全屏 viewer；占位/错误块 radiusMd（dsh/`render/markdown_image.dart`）—— cc 目前仅工具 resultImages 有图，此项为新增

## 10. 代码块

现状：cc/`code_block.dart` github-dark + 语言标签 + 复制 + 横滚。

- [ ] **自调 "Mist" 高亮主题**（明暗两套，配 mist 色板）：keyword 紫 `#6A499B`/`#C4ACF2`、string 绿 `#336F43`/`#97D2A2`、number 琥珀 `#90561A`/`#F2BB8A`、comment 斜体灰蓝、function 蓝 `#2C5CA3`/`#95BDF8`、type 青 `#006E77`/`#85CFD8`、attr 玫 `#97464F`/`#ECA4A9`、meta 土 `#726042`/`#BFAF95`（dsh/`theme/highlight_theme.dart`）—— 替换 github-dark
- [ ] 语言注册 **55 种 + 约 60 条别名**（dsh/`code_block.dart:79-205`）；现状：cc 31 种 + 5 条别名 —— 照搬表
- [ ] 代码井外观：底 `codeWellBg`、squircle md14 + **0.5px `codeWellBorder` 描边**；标题条高 `max(36, 字高+8)`：左语言名 monoLabel 12，右「自动换行」开关 + 复制键；正文 padding `LTRB(16,12,16,12)`（dense/行号时左 12）（dsh/`code_block.dart:346` 起）
  - 现状：cc 圆角 8、深色固定底 `#161B22` —— 圆角换 md14、底色换 codeWell 体系（浅色也要有浅色井）
- [ ] **行号列**：右对齐 tabular 等宽、`SelectionContainer.disabled`（dsh/`code_block.dart`）
- [ ] **「自动换行」开关**；不换行时横滚 + `HorizontalEdgeFade` 两端淡出（dsh/`render/edge_fade.dart`）
- [ ] diff 围栏**整行着色** + hunk 头浅底（dsh/`code_block.dart:658`）
- [ ] 复制成功：图标**原地交叉淡变为对勾 1200ms**（cc 现为 2s 换图标，改交叉淡变）
- [ ] **分块缓存**：长代码按 ≤200 行/8000 字切块，块缓存 LRU 64（dsh/`code_block.dart:252-270`）
- [ ] `maxHeight` 时包 `OverscrollForwarder`：代码井纵滚到头让路给外层列表（dsh/`code_block.dart:522-528`）
- [ ] mermaid：标题条带图标 + 「预览」→ 全屏页（cc 已有 MermaidPreview，保留；补标题条图标）

## 11. 流式渲染（最易复刻不全）

现状：cc 有 StreamPacer(600字/s) + stream_repair + 静态光标 `▍` + 流式跳过高亮。

- [ ] **列表层每 32ms 重建但同文字复用同一 Markdown widget 实例**（缓存 `_body/_bodyText/_bodyStreaming`，避免每帧重解析）（dsh/`assistant_message.dart:131-141`）
- [ ] **reveal 渐显**（灵动档）：`charactersPerSecond 120`、`revealFadeSeconds 0.24`、`GptMarkdownAnimation.fade`（dsh/`markdown_body.dart:542-546, 664-668`）；cc 的 StreamPacer 保留给非灵动档
- [ ] **光标 sentinel 化**：正文末拼私用区 ``，`InlinePattern` 换成 `StreamingCursor` —— **2.5px 宽、行高 66%、透明度 1.0↔0.25 周期 1000ms 呼吸**，RepaintBoundary 单独一层只重绘 2.5px；sentinel 不落进表格新 cell、closing fence 单独成行（dsh/`common/streaming_cursor.dart`、`markdown_body.dart:572-583`）—— 替换静态 `▍`
- [ ] **流式代码高亮节流 250ms**（`_highlightEvery`，冷却期新增部分以纯文本拼接）（dsh/`code_block.dart:400`）—— 替换"流式完全不高亮、完成后一次性"
- [ ] **等待三点 `TypingIndicator`**：相位缩放 0.55–1.0、周期 1200ms、点距 5、点径 8（dsh/`common/typing_indicator.dart`）
- [ ] 三点 → 内容 **`_HandOff` 交接动画**：out 90ms / in 160ms、curve `Cubic(0.23,1,0.32,1)`、上移 3.0（dsh/`assistant_message.dart:23-26`）
- [ ] 思考后第一段正文 `_FirstTextIn`：淡入 200ms + heightFactor 展开（dsh/`assistant_message.dart:326-350`）
- [ ] **流停滞 `_StallDot`**：900ms 无新字 → 文字下方 5px 呼吸点（breath/2）（dsh/`assistant_message.dart:379-452`）
- [ ] **中断标记**：danger 色小字一行（icon 16 + 文案）（dsh/`assistant_message.dart:353-374`）；现状：cc 中断以 notice 呈现，补正文内标记
- [ ] 流式期间助手正文 `Opacity 0.85`（cc 已有，保留）

## 12. 思考折叠（thinking）

现状：cc/`_ThinkingSection` pill + 120 高滚区贴底 jump。

- [ ] **恒高 3 行实时窗口**（`ThinkingTicker.rows = 3`）：写满一行 `AnimatedContainer` **linear 匀速**上移一行（不用缓动，避免一顿一顿）；尾部最多 2000 字参与排版（dsh/`thinking_pill.dart:371-441`）
- [ ] 灵动档 `_FluidTicker`：StreamPacer + 底边对齐 + 顶部 `ShaderMask` 软边（dsh/`thinking_pill.dart:470`）
- [ ] **标签扫光**：lead 600ms / sweep 1s / period 4s，`ShaderMask` 三色渐变 `[muted, bright, muted]`，**同屏只扫一条**（静态 `_owner` 抢占）（dsh/`thinking_pill.dart:235-283`）
- [ ] 图形块用主色（dsh 为 `#4D6BFE`，深色提亮 `lerp(blue, white, 0.3)`，底 alpha 深 0.18/浅 0.10），圆角 `Squircle.border(lead*0.32)`（dsh/`thinking_pill.dart:49`）
- [ ] 收起预览 = 全文第一行去 `**`；一轮结束**强制收回手动展开**（dsh/`thinking_pill.dart:81, 115`）
- [ ] 展开全文 = 次级 MarkdownBody；`SelectionArea` 套在收起手势**外层**（dsh/`thinking_pill.dart:342-363`）
- [ ] 结构改用 `StreamRow`（24 图形块 + 标签 + 预览 + chevron）+ `ExpandReveal` 展开

## 13. 工具行 / 工具组

现状：cc `ProcessLine` 解剖同构、≥3 收组、状态六表已对齐。

- [ ] 图标块 **24**、按 `ToolTone`（terminal/read/edit/search/web/agent/plan/neutral）上色（现状按工具名单色 glyph —— 加 ToolTone 色体系）
- [ ] 动词 label 14/1.3 次级色；摘要：命令/路径类用 **mono 12.5**（dsh/`tool_row.dart`）
- [ ] 行尾状态条 `_StatusTrail`：运行中 14px spinner（strokeWidth 1.8 primary）、失败 ✕ 16 danger、已拒绝/取消小字、**成功默认安静**、diff 显示 `+n −n`（dsh/`tool_row.dart:359`）
  - 现状：cc 状态 = 图标 + 文字常显 —— 改为成功安静、运行转 spinner
- [ ] 详情铺在**代码井**里（`codeWellBg` + md14 + 0.5px 边），**分节**：eyebrow 11/letterSpacing 0.4，节间 0.5px divider；bash 命令带 `$ ` prompt；文件路径 + 行号范围；参数 JSON；diff（DiffView）；read 代码（行号 + dense）；write 新文件；ANSI 输出（`LongTextWell` 超长只排头尾 + 查看全部）；结果图片（dsh/`tool_row.dart:401` 起）
  - 现状：cc `tool_views.dart` 内容已基本齐（ANSI 2000 字符头尾、LCS diff、Todo 三态）—— 主要补"代码井容器 + 分节 eyebrow"的外观
- [ ] `_kDetailMaxHeight = 280`（cc 现 320，改 280）（dsh/`tool_row.dart:29`）
- [ ] **工具组摘要**：≥3 次收一行（「执行 2 条命令 · 读了 3 个文件」），失败数红色计数；**正在运行/待确认的行始终露在摘要下**（`_liveKeys`）；展开后全部挂在 `StreamThread` 细线下（dsh/`tool_row.dart:610`）
  - 现状：cc `_ToolGroupTile` 已收组但无 live 行露出、无细线 thread

## 14. 审批 / 提问卡

现状：cc `PermissionCard`（waiting 边框 + checkbox + 拒绝/允许）功能齐。

- [ ] 外观对齐 dsh/`approval_card.dart`：squircle **lg20**、玻璃 card 材质（white@0.62，不模糊）
- [ ] dsh 的审批卡挂在**对应工具行下**（内联），游离审批单独成行（cc 已内联，保留）

## 15. 滚动 / 列表

现状：cc 居中锚定已同构，贴底跟随为帧后 postFrame + 阈值 120。

- [ ] **`_FollowPhysics`**：贴底且无手指时在**同一次布局内**跳到新末尾（dsh/`chat_list.dart:1630`）—— 替换 postFrame 方案
- [ ] **流式 glide**（灵动档）：gap ≤240px 时 Ticker 指数逼近，时间常数 **0.07s**（≈150ms 一行）（dsh/`chat_list.dart:245`）
- [ ] 手指优先机制：`_fingers` 计数、`_held`（点开工具/思考后行自身长高不追底）、用户下拖立即 `_pinned = false`（dsh/`chat_list.dart:545-549`）
- [ ] 非灵动档远距离：帧后 `jumpTo(maxScrollExtent)` 最多追 4 帧（`_follow()`）
- [ ] **回底按钮**：44 圆钮 chrome 玻璃（blur: false）、icon 22；**双阈值显隐：未显示时 160、显示后 24**；显隐动画 `AnimatedScale(0.6→1, popCurve)` + `Opacity(quick)`（dsh/`chat_list.dart:1509-568`）
  - 现状：cc GlassPill + 200ms —— 改尺寸与双阈值
- [ ] **未读新内容角标**：离开底部期间新内容加 **9px 主色角标（圆心在 45° 边上，top/right 2）**（dsh/`chat_list.dart` `_JumpToBottom`）
- [ ] **有待审批/提问时回底键变 44 高胶囊**（icon 18 + 计数）（dsh/`chat_list.dart`）—— cc 已有权限胶囊，合并进回底键
- [ ] **加载更早**：`pixels − minScrollExtent ≤ 800` 触发；prepend 用渲染锚点行做**同帧偏移校正**（`_prependCorrection`，在 `applyContentDimensions` 里 `correctBy` 后重试布局）（dsh/`chat_list.dart:574, 870`）
- [ ] 键盘：`ScrollViewKeyboardDismissBehavior.manual`，只有本列表的拖动才收键盘（dsh/`chat_list.dart:535`）
- [ ] 顶部/底部留白 `topInset + 8` / `bottomInset + 8 + petHeadroom`；`anchor` = 输入条上沿在视口的比例（dsh/`chat_list.dart:924`）
  - cc 现状：顶部 scrim 渐显方案 —— 视 overlap 6.0 + veil 方案落地后二选一，倾向 veil

## 16. Composer

现状：cc `OutlineInputBorder(radius: 24)` 传统框 + 三态右键。

- [ ] **形态**：`GlassSurface(chrome, radiusXl 28)` 胶囊；两颗 **36 圆键**做端盖（键距 **6**）；单行胶囊高 **48**（圆角 28 = 键半径 20 + 8）；文字 **15/1.45**，40 高内垂直居中（`contentPadding vertical = max(4, (36−line)/2)`）（dsh/`composer.dart:36-807`）
- [ ] **1–6 行自动增高**；手机上打字时开成两行（footer = 模型胶囊）：自定义 RenderBox `_ComposerRows` 在单行/两行间**逐帧插值**（`_open` 0→1，宽度 lerp、圆角 28→20 lerp）（dsh/`composer.dart:648`）
- [ ] 键盘下滑仍聚焦时识别为"收键盘"（`_keyboardMoved` 峰值一半以下）（dsh/`composer.dart:215`）
- [ ] **右键四态** `_KeyMode`：send（↑ 20px 主色实心）/ stopRun（■ 18px）/ mic（onSurface@0.06 淡底）/ stopVoice；禁用底 `onSurface@0.12`、前景 `@0.38`；按下缩 **0.9（press 90ms）**；busy 时 11px padding 内转圈；灵动档图标切换 `_FluidKeySwap`（旧图标飞出右上 16px + 新图标 spring 弹入）（dsh/`composer.dart:807`）
- [ ] 键盘发送：Ctrl/⌘+Enter（可选裸 Enter，**IME 组词中绝不发送**）；**500ms 内双 Esc 停止**（dsh/`composer.dart:254-291`）
- [ ] **长按发送** → 插话 / 打断并发送 / 排队 三选 sheet（dsh/`chat_screen.dart:868`）
- [ ] 发送条件：`connected && sessionReady && !busy && (!empty || hasAttachments || sendWhenEmpty)`；失败 `_giveBack` 原样还字/附件/引用（cc 已有，保留）
- [ ] 斜杠面板：输入条上方 **6px**，`AnimatedSwitcher 160ms` fade + bottomCenter scale 0.96→1；Esc 或点外部关闭；键盘收起自动收（dsh/`chat_screen.dart:1898-1909`）；cc 现为 maxHeight 200 列表 —— 补动画与关闭交互
- [ ] 引用胶囊 QuoteChip：输入框上方胶囊 + 气泡内引文条 `BubbleQuote`（dsh/`widgets/quote_chip.dart`；cc 已有 QuoteChip，对齐样式）
- [ ] 键盘贴图 `contentInsertionConfiguration`：允许 png/jpeg/gif/webp（dsh/`composer.dart:472-477`）

## 17. Header

现状：cc/`chat_header.dart` 玻璃胶囊 + 宽度协商（full→hideUsage→shrinkModel）。

- [ ] 结构对齐 dsh/`chat_header.dart`：浮动玻璃件顶栏（**无整条色带**）：≡ 圆钮 **44** + 标题胶囊（含状态行）+ 模型胶囊 + 新对话圆钮；`barHeight = 56.0`、胶囊 minHeight **44**（dsh/`chat_header.dart:49`）
- [ ] `_HeaderRow`/`_PillContent` 自定义 RenderBox（纯布局，可搬）测量分配
- [ ] 状态行 `HeaderStatus`（连接/运行状态文案）进标题胶囊（cc 现在状态在别处）

## 18. 空状态

现状：cc/`empty_state.dart` 时段问候 + 4 张建议卡（填入不发送）。

- [ ] 对齐 dsh/`empty_state.dart` + `empty_actions.dart`：鲸尾图形 + 时段问候 + 副标题 + **工作区胶囊** + **2×2 建议卡** + 小技巧行（TipLine）；建议卡为 `EmptyPrimaryPill` / `QuietChip` 体系（鲸尾 `whale_tail.dart` 328 行可搬或重绘）

## 19. 消息菜单 / 操作

现状：cc/`message_menu.dart` 三项（复制/选择文字/引用）+ `_TurnEndActions`。

- [ ] 菜单结构对齐 dsh/`message_menu.dart`：底部弹层（`HapticFeedback.mediumImpact`）= **3 行预览**（去 markdown 记号）→ 第一组（复制/选择文字/引用/分享）→ 第二组 fork 类（重新回答/从这里分叉/编辑后重发，带 hint 副标题）→ 插件组；`isScrollControlled: true` 按内容高
- [ ] `ReplyActionRow`：36 圆钮 / 20 图标；复制成功对勾 **1400ms**；分叉/重答进行中原地 16px 转圈；右端挂**回合脚注**（dsh/`widgets/message_actions.dart`）
- [ ] 「重新回答」实现 = 在原 prompt 前分叉出新会话 → 切过去 → 重发；toast 带「返回原对话」（dsh/`chat_list.dart:1254 _regenerate`）
- [ ] 乐观气泡（排队）操作：立即发送 / 改为插话 / 撤回（失败时「编辑后重发」）（cc 现为编辑/撤回，补"改为插话"）

## 20. 缺失模块（cc 完全没有，需新增）

- [ ] **回合脚注** `TurnFootnote`：`47 秒 · 12 步 · ¥0.03 · tokens ›`，放不下逐级省略（dsh/`widgets/turn_footnote.dart`，122 行）
- [ ] **回合折叠展开容器** `TurnProcessRow`（官方 foldCompletedTurns 语义；cc 的 `TurnFoldRow` 判定已有，补展开容器 `turn_process.dart` 241 行）
- [ ] **改动卡** `ChangeCardRow`：`+18 −4` 摘要卡（dsh/`change_card.dart`，173 行）
- [ ] **产物卡 / 产物预览** `ArtifactCardRow` / `artifact_preview.dart`（582/1826 行 —— 可后置）
- [ ] **错误横幅**：输入条上方 `ErrorBanner`（notice_row.dart:208）
- [ ] **todo / goal dock 条**（输入条上方，`dock/` 目录）—— 依赖 Claude 会话的 todo 数据，按 daemon 协议后置
- [ ] **`@` mention**（`mention/` 目录 5 个文件）—— 后置
- [ ] **余额横幅 / usage sheet**（dsh/`usage_sheet.dart` 588 行；cc 有 UsageChip，sheet 后置）
- [ ] **回合轨迹 sheet** `trajectory_sheet.dart`（1017 行）—— 后置
- [ ] **长文本井** `LongTextWell`：超长文本"头尾 + 查看全部"（dsh/`render/long_text.dart`，309 行；cc 的 ANSI 头尾裁剪已有，抽出通用件）
- [ ] **通知行升级**：`NoticeRow` + `ErrorBanner`，回合结束说明（错误/停止/重试/上限）（dsh/`widgets/notice_row.dart`；cc 的 `_NoticeBand` + 错误码映射已有，对齐外观）

## 21. 关键遗漏点清单（数值速查，验收时逐条核对）

1. 用户气泡 **82%** 宽、`symmetric(h16, v8)`、色取 userBubble 而非 primaryContainer
2. 间距阶梯：换轮 **24** / 同轮 **8** / 过程行间 **0** / 卡片 **12** / 脚注 **4**；行外层 `fromLTRB(16, gap, 16, 0)`
3. 玻璃四件套：blurSigma **18/24**、saturation **1.3/1.4**、hairline **0.5px**、rim 顶边 45% 渐隐、even-odd 外阴影；同屏 ≤3 真模糊 + BackdropGroup
4. 阴影基色 **#0B152D（浅）/ #03060D（深）**，不是纯黑
5. mono 体系：正文代码 **13/1.55**、工具输出 **12/1.5**、标签 **12/1.35**、工具摘要 **12.5**、行内代码 **×0.875**；全部禁连字；聊天正文 **16/1.65**
6. composer 数字组 **36 / 6 / 28 / 48 / 40**（键径 / 键距 / 圆角 / 胶囊高 / 文字行高）互为约束
7. `_ChatLayout.overlap = 6.0` 与 `BackdropVeil` 同帧联动
8. 流式三件套：**32ms 重建但复用 markdown 实例**、sentinel 光标 + RepaintBoundary、**代码高亮 250ms 节流**
9. 思考窗口**恒高 3 行 + linear 匀速上移**（不用缓动）
10. 回底按钮 **44px**、显隐双阈值 **160/24**、角标 **9px** 在 45° 边上（top/right 2）
11. 工具详情 `_kDetailMaxHeight = 280`；高亮阈值 `_kHighlightMaxChars = 20000`；代码分块 ≤200 行/8000 字、LRU 64
12. pressScale **0.97**、press **90ms**、stagger **30ms**、rise **8.0**、glide 时间常数 **0.07s**、typing 点 **1200ms/点径 8/点距 5**、光标 **2.5px/66%/1000ms**、停滞点 **900ms 后 5px**
13. 单元格表格列上限 **260px**、markdown 图片限高 **480**、附件托盘/预览（cc 72×72、dsh 为托盘块 + ✕ 角标 —— 对齐 dsh 形态）

## 22. 实施顺序建议

1. **A 级**：theme 数值灌入（§1–§6：调色/字体/形状/间距/玻璃/动效）—— 一次到位，后面所有组件直接受益
2. **B 级自包含件**：squircle、streaming_cursor、typing_indicator、expand_reveal、smooth_size、bleed、edge_fade、overscroll_forwarder、stream_motion、stream_row、stream_pacer(对齐)、GlassSurface(对齐)
3. 渲染层：markdown_body（含光标/reveal/alert/表格）→ code_block（Mist 主题/行号/分块）→ 流式三件套
4. 行组件：气泡几何 → 思考窗口 → 工具行/组 → notice/脚注 → 审批卡
5. 骨架：_ChatLayout 六 slot + overlap 6.0 + veil → composer 胶囊化 → header → 空状态
6. 滚动：_FollowPhysics → glide → 回底键/角标 → prepend 校正
7. 后置：产物预览 / dock / mention / trajectory / usage sheet

每完成一条勾掉对应 checkbox。`theme_tokens_test` 的守卫（theme 层不得依赖 UI 屏幕）**先放宽**（按搬运需要调整/跳过），后续再收紧优化。
