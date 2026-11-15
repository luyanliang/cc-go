/// 聊天页四件套（task 6.1）：header（标题+阶段）/list（快照+实时合并）/
/// rows（四种条目）/composer（发送/排队/打断）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/chat_controller.dart';
import '../../state/chat_controller_provider.dart';
import '../../state/draft_store.dart';
import '../../state/session_models.dart';
import '../../state/transcript.dart';
import '../../state/sessions.dart';
import '../../theme/motion.dart';
import '../theme/app_style.dart';
import '../widgets/glass.dart';
import '../widgets/pill_badge.dart';
import 'attachment_pick.dart';
import 'chat_header.dart';
import 'chat_row_model.dart';
import 'chat_rows.dart';
import 'widgets/follow_physics.dart';
import '../../voice/voice_controller.dart';
import '../../transport/reconnecting_link.dart';
import 'render/assistant_markdown.dart';
import 'tool_views.dart';
import 'composer.dart';
import 'model_sheet.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId, required this.title});

  final String sessionId;
  final String title;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// 聊天主体（玻璃 chrome 悬浮 + 全高列表滚动穿过之下 + composer 浮底 +
/// 贴底滚动）。直接持有控制器——ChatScreen 负责 provider 装配，测试直接
/// 构造 ChatBody（header 可省）。
class ChatBody extends StatefulWidget {
  const ChatBody({
    super.key,
    required this.controller,
    this.header,
    this.onDraftChanged,
    this.onSent,
  });

  final ChatController controller;

  /// 顶部玻璃 chrome（标题胶囊组）；null = 无顶栏（部分测试用）。
  final Widget? header;

  /// 草稿变更（chat-composer：持久化在 ChatScreen）。
  final ValueChanged<String>? onDraftChanged;

  /// 发送成功（清空持久化草稿）。
  final VoidCallback? onSent;

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

/// 把会话的 ReconnectingHostLink 适配成听写控制器要的 VoiceLink。
/// 适配器随 ChatBody 创建一次，身份稳定；断连由调用抛错兜底。
class _ChatVoiceLink implements VoiceLink {
  _ChatVoiceLink(this._link);
  final ReconnectingHostLink? _link;

  @override
  Future<Map<String, dynamic>> speechCatalog() async {
    final link = _link;
    if (link == null) throw StateError('not connected');
    final result = await link.call('speech.catalog') as Map<dynamic, dynamic>;
    return result.cast<String, dynamic>();
  }

  @override
  Future<String> speechTranscribe(
    Uint8List wav, {
    String? providerId,
    String? language,
  }) async {
    final link = _link;
    if (link == null) throw StateError('not connected');
    final result = await link.call('speech.transcribe', {
      'audio': base64Encode(wav),
      'providerId': ?providerId,
      'language': ?language,
    }) as Map<dynamic, dynamic>;
    return result['text'] as String? ?? '';
  }
}

class _ChatBodyState extends State<ChatBody> {
  final _scrollController = ScrollController();
  late final _voiceLink = _ChatVoiceLink(widget.controller.link);
  bool _nearBottom = true;
  bool _scrollScheduled = false;



  /// 回底键双阈值（dsh 规格）：未显示时离开 160 就显示，显示后回到 24
  /// 才隐藏（迟滞，避免在阈值附近闪烁）。
  static const _jumpShowPx = 160.0;
  static const _jumpHidePx = 24.0;

  /// chrome 实测高度（列表 padding 与 scrim 高度用）；变更即 setState
  /// 同步列表 padding（scrim 走 ValueListenableBuilder 自行重建）。
  final _headerHeight = ValueNotifier<double>(0);
  final _composerHeight = ValueNotifier<double>(0);

  void _onHeaderHeight(double h) {
    if (h != _headerHeight.value) {
      _headerHeight.value = h;
      setState(() {});
    }
  }

  void _onComposerHeight(double h) {
    if (h != _composerHeight.value) {
      _composerHeight.value = h;
      setState(() {});
    }
  }

  /// 顶部 scrim 强度：0 = 列表在顶部（scrim 不可见），随上滚距离在
  /// ~160px 内渐显到 1（spec: 内容滚动到玻璃之下、遮罩随滚动渐变）。
  final _scrollAway = ValueNotifier<double>(0);

  /// 回到底部浮动键的可见性（双阈值迟滞）；离开期间有新内容加角标。
  final _showJumpToBottom = ValueNotifier<bool>(false);
  final _hasNewContent = ValueNotifier<bool>(false);
  double _lastMaxExtent = 0;

  @override
  void initState() {
    super.initState();
    // 内容增长本身不触发滚动事件，_nearBottom 只在像素移动时更新：
    // 用户上翻 → false；贴底动画落位 → true。
    _scrollController.addListener(() {
      final ScrollMetrics m = _scrollController.position;
      final near = m.pixels >= m.maxScrollExtent - _jumpHidePx;
      if (near != _nearBottom) {
        _nearBottom = near;
        if (near) _hasNewContent.value = false;
        _showJumpToBottom.value = !near;
      } else if (!near &&
          m.pixels < m.maxScrollExtent - _jumpShowPx &&
          !_showJumpToBottom.value) {
        // 离开贴底超过 160 才亮起（迟滞）。
        _showJumpToBottom.value = true;
      }
      // 离开底部期间内容又长了 → 角标。
      if (!_nearBottom && m.maxScrollExtent > _lastMaxExtent + 1) {
        _hasNewContent.value = true;
      }
      _lastMaxExtent = m.maxScrollExtent;
      final t = (m.pixels / 160).clamp(0.0, 1.0);
      if (_scrollAway.value != t) _scrollAway.value = t;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _headerHeight.dispose();
    _composerHeight.dispose();
    _scrollAway.dispose();
    _showJumpToBottom.dispose();
    super.dispose();
  }

  /// 流式期间每个变更帧后贴底（若用户仍在底部附近）。
  /// 必须由转录的 StreamBuilder 调用——外层 build 在流式更新时不会重跑，
  /// 这正是"输出很多时不滚动"那版 bug 的根源。
  void _autoScroll() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_scrollController.hasClients || !_nearBottom) return;
      final target = _scrollController.position.maxScrollExtent;
      final current = _scrollController.offset;
      // 距离大（如入页追底、extent 修正后跳变）直接 jumpTo —— animateTo
      // 的 120ms 动画会与懒加载 extent 修正互相追赶，留下短暂空白帧；
      // 距离小保持动画平滑。
      if ((target - current).abs() > 600) {
        _scrollController.jumpTo(target);
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final mq = MediaQuery.of(context);
    final hasHeader = widget.header != null;
    return Stack(
      children: [
        // 内容层：全高，顶部/底部穿过玻璃 chrome 之下。
        Positioned.fill(
          child: NotificationListener<StreamingFrameNotification>(
            onNotification: (_) {
              // pacer 每帧吐字 → 内容增长 → 贴底跟随同样要看得到。
              _autoScroll();
              return false;
            },
            child: StreamBuilder<void>(
            stream: controller.changes,
            builder: (context, _) {
              _autoScroll();
              return TranscriptListView(
                items: controller.transcript.items,
                queuedTexts: controller.queuedTexts,
                loaded: controller.transcript.loaded,
                scrollController: _scrollController,
                // 同一次布局内贴底跟随（dsh FollowPhysics）。
                physics: FollowPhysics(() => _nearBottom),
                padding: EdgeInsets.only(
                  top: hasHeader ? mq.padding.top + _headerHeight.value + 4 : 8,
                  bottom: _composerHeight.value + 8,
                ),
                onRespondPermission: (itemId, allow, allowForSession) =>
                    controller.respondPermission(itemId, allow,
                        allowToolForSession: allowForSession),
                onSuggestion: (text) => controller.fillDraft(text),
                onQuote: controller.setQuote,
                onQueuedRemove: controller.removeQueuedAt,
                onQueuedEdit: controller.editQueuedAt,
              );
            },
          ),
          ),
        ),
        // 顶部 chrome：随滚动渐变的 scrim + 玻璃头。
        if (hasHeader)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: _scrollAway,
              builder: (context, t, _) => Stack(
                children: [
                  IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _headerHeight,
                      builder: (context, h, _) => Container(
                        height: mq.padding.top + h + 12,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Theme.of(context)
                                  .colorScheme
                                  .surface
                                  .withValues(alpha: 0.85 * t),
                              Theme.of(context)
                                  .colorScheme
                                  .surface
                                  .withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(top: mq.padding.top),
                    child: _Measured(
                      onChange: _onHeaderHeight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                        child: widget.header!,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        // 底部 chrome：静态 scrim + composer 浮底。
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Stack(
            children: [
              IgnorePointer(
                child: ValueListenableBuilder<double>(
                  valueListenable: _composerHeight,
                  builder: (context, h, _) => Container(
                    height: h + 12,
                    alignment: Alignment.bottomCenter,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0.85),
                          Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _Measured(
                onChange: _onComposerHeight,
                child: StreamBuilder<void>(
                  stream: controller.changes,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PermissionPills(controller: controller, onJump: () {
                        if (_scrollController.hasClients) {
                          _scrollController.animateTo(
                            _scrollController.position.maxScrollExtent,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                          );
                        }
                      }),
                      _ActivityPill(controller: controller, onJump: () {
                        if (_scrollController.hasClients) {
                          _scrollController.animateTo(
                            _scrollController.position.maxScrollExtent,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                          );
                        }
                      }),
                      Composer(
                    voiceLink: () => _voiceLink,
                    running: controller.running,
                    busy: controller.busy,
                    pickAttachment: () => pickAttachmentWithSheet(context),
                    slashCommands: controller.slashCommands,
                    draftSink: controller.draftFill,
                    quoteSink: controller.quoteText,
                    onDraftChanged: widget.onDraftChanged,
                    onSend: (text, attachments) async {
                      try {
                        await controller.send(text, attachments: attachments);
                        widget.onSent?.call();
                      } on Object catch (e) {
                        // 发送失败不让消息静默丢失：把原文带回提示里。
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('发送失败：$e\n消息：$text')),
                          );
                        }
                        // 向 Composer 重新抛出：文本与附件保留在输入区。
                        rethrow;
                      }
                    },
                    onCancel: () => controller.cancel(),
                  ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 回到底部浮动键：44 chrome 玻璃圆钮（不模糊），双阈值显隐
        // （scale 0.6→1 pop + quick 淡入）；离开期间新内容加 9px 主色角标
        // （圆心落在 45° 边上，top/right 2）。
        Positioned(
          right: 12,
          bottom: _composerHeight.value + 16,
          child: ValueListenableBuilder<bool>(
            valueListenable: _showJumpToBottom,
            builder: (context, show, _) => IgnorePointer(
              ignoring: !show,
              child: AnimatedScale(
                scale: show ? 1 : 0.6,
                duration: AppMotion.quick,
                curve: AppMotion.enter,
                child: AnimatedOpacity(
                  opacity: show ? 1 : 0,
                  duration: AppMotion.quick,
                  child: SizedBox.square(
                    dimension: 44,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: GlassSurface(
                            tier: GlassTier.chrome,
                            blur: false,
                            radius: 22,
                            onTap: () {
                              if (!_scrollController.hasClients) return;
                              _scrollController.animateTo(
                                _scrollController.position.maxScrollExtent,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                              );
                            },
                            child: const Center(
                              child: Icon(Icons.arrow_downward, size: 22),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _hasNewContent,
                            builder: (context, fresh, _) => AnimatedScale(
                              scale: fresh ? 1 : 0,
                              duration: AppMotion.quick,
                              curve: AppMotion.std,
                              child: Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Theme.of(context).colorScheme.surface,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 输入条上方的权限/自动允许胶囊（chat-transcript-rows）：待权限时
/// 显示权限胶囊（点击定位审批卡）；免问生效后显示自动允许胶囊（状态
/// 展示 —— 撤销需 daemon 撤销协议，见 proposal 不做清单）。
class _PermissionPills extends StatelessWidget {
  const _PermissionPills({required this.controller, required this.onJump});

  final ChatController controller;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final awaiting = <String>{
      for (final i in controller.transcript.items)
        if (i.kind == ItemKind.tool && i.status == 'awaiting-permission')
          i.toolName ?? '工具',
    };
    final allowed = controller.sessionAllowedTools;
    if (awaiting.isEmpty && allowed.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final tool in awaiting)
                  InkWell(
                    onTap: onJump,
                    borderRadius: BorderRadius.circular(999),
                    child: PillBadge.capsule(
                      '待权限：$tool',
                      color: AppColors.waiting.withValues(alpha: 0.15),
                      onColor: Theme.of(context).colorScheme.onSurface,
                      icon: Icons.shield_outlined,
                    ),
                  ),
                for (final tool in allowed)
                  PillBadge.capsule(
                    '$tool 已本会话免问',
                    color: AppColors.neutral.withValues(alpha: 0.15),
                    onColor: Theme.of(context).colorScheme.onSurface,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入条上方的活动胶囊（chat-transcript-rows）：会话运行中显示当前
/// 动作摘要（转录推导）与走秒计时；点击定位当前条目（滚到底部）。
class _ActivityPill extends StatefulWidget {
  const _ActivityPill({required this.controller, required this.onJump});

  final ChatController controller;
  final VoidCallback onJump;

  @override
  State<_ActivityPill> createState() => _ActivityPillState();
}

class _ActivityPillState extends State<_ActivityPill> {
  // 时长不走自调度定时器（会与 pumpAndSettle 类帧等待互相纠缠）：转录
  // 事件本身高频（流式/工具运行持续产生条目更新），每次事件到达即刷新
  // 读秒；静默长工具的秒数在下一个事件帧补齐。
  @override
  Widget build(BuildContext context) {
    final items = widget.controller.transcript.items;
    final label = currentActivityLabel(
      items,
      toolOverview: (i) => toolSubtitleFor(i) ?? i.summary ?? '',
    );
    if (label == null) return const SizedBox.shrink();
    final elapsed = activityElapsedSeconds(items, DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          InkWell(
            onTap: widget.onJump,
            borderRadius: BorderRadius.circular(999),
            child: PillBadge.capsule(
              elapsed == null ? label : '$label · $elapsed s',
              color: Theme.of(context).colorScheme.primaryContainer,
              onColor: Theme.of(context).colorScheme.onPrimaryContainer,
              icon: Icons.play_circle_outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 实测子树高度回调（chrome 高度同步给列表 padding 与 scrim）。
class _Measured extends StatefulWidget {
  const _Measured({required this.onChange, required this.child});

  final ValueChanged<double> onChange;
  final Widget child;

  @override
  State<_Measured> createState() => _MeasuredState();
}

class _MeasuredState extends State<_Measured> {
  final _key = GlobalKey();
  double? _last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() {
    if (!mounted) return;
    final h = _key.currentContext?.size?.height;
    if (h != null && h != _last) {
      _last = h;
      widget.onChange(h);
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  /// 已为其拉取过指令目录的 controller 实例。重连后 provider 会重建出
  /// 新 controller（旧的 slashCommands 丢失）——按身份识别并重拉。
  ChatController? _commandsLoadedFor;

  @override
  void dispose() {
    // 未落盘的草稿快照立即写（页面销毁）。
    _draftSaver.flush();
    super.dispose();
  }

  /// 切到该 controller 时：拉指令目录 + 恢复持久化草稿。
  void _onControllerChanged(ChatController controller) {
    if (identical(_commandsLoadedFor, controller)) return;
    _commandsLoadedFor = controller;
    Future.microtask(() async {
      controller.loadSlashCommands();
      final draft = await DraftStore.load(widget.sessionId);
      if (!identical(_commandsLoadedFor, controller)) return;
      if (draft.text.isNotEmpty) controller.fillDraft(draft.text);
      final quote = draft.quote;
      if (quote != null) controller.setQuote(quote);
    });
  }

  /// 草稿落盘器（防抖 + 最新快照；评审 #8）。
  final _draftSaver = DraftSaver();

  /// 草稿落盘（Composer 每次输入变化回调；发送成功后由 onSend 清除）。
  void _saveDraft(String text) {
    final controller = _commandsLoadedFor;
    final quote = controller?.quoteText.value;
    _draftSaver.sessionId = widget.sessionId;
    _draftSaver.schedule(ChatDraft(
        text: text,
        quote: (quote == null || quote.isEmpty) ? null : quote));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatControllerProvider(widget.sessionId));
    _onControllerChanged(controller);
    // 用量/成本来自会话摘要（task 3.5）：sessions.changed 驱动列表刷新，
    // 这里从会话列表 provider 里按 id 取最新摘要。
    SessionSummary? summary;
    final sessions = ref.watch(sessionsProvider).value;
    if (sessions != null) {
      for (final s in sessions) {
        if (s.id == widget.sessionId) {
          summary = s;
          break;
        }
      }
    }
    return Scaffold(
      // 玻璃 chrome（顶栏/输入区）悬浮在 Stack 顶层，消息内容滚动穿过
      // 其下（chat-visual-system: 内容滚动到玻璃之下）。
      body: ChatBody(
        controller: controller,
        onDraftChanged: _saveDraft,
        onSent: () {
          // 先丢弃未写快照再清空，防抖里的旧文本不得反扑（评审 #8）。
          _draftSaver.discard();
          DraftStore.clear(widget.sessionId);
        },
        header: ChatHeader(
          title: widget.title,
          phase: controller.transcript.phase,
          summary: summary,
          onPickModel: () => _showModelPicker(context, controller, summary),
        ),
      ),
    );
  }

  void _showModelPicker(
    BuildContext context,
    ChatController controller,
    SessionSummary? summary,
  ) {
    showModelSheet(
      context,
      loader: () async {
        final raw = await controller.models();
        final entries = <ModelEntry>[];
        for (final m in (raw['models'] as List<dynamic>? ?? <dynamic>[])) {
          if (m is! Map<String, dynamic>) continue;
          entries.add(ModelEntry(
            id: m['id'] as String? ?? '',
            displayName: m['displayName'] as String? ?? '',
          ));
        }
        return ModelCatalog(models: entries, current: raw['current'] as String?);
      },
      currentModel: summary?.model,
      onApply: (model) => controller.configureModel(model),
    );
  }
}
