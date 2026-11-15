/// 输入区（task 6.3/6.4 + chat-composer）：文本框 + 发送；运行中出现
/// 打断按钮；附件按钮（选图回调可注入）；语音听写（系统识别引擎，不
/// 可用时显示语音入口；听写经 VoiceInputController（双引擎 + daemon
/// 转录降级，见 lib/voice/）；草稿变更回调（按会话持久化在 ChatScreen）；
/// 斜杠面板候选带中文说明与选中提示。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../state/attachment.dart';
import '../../state/chat_controller.dart' show SlashCommand;
import '../../voice/voice_bridge.dart';
import '../../voice/voice_controller.dart';
import '../theme/app_style.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';

/// 输入条圆键（dsh 数字组：36 径、按下缩 0.97/90ms）：主键 = 主色实心圆
/// （发送/停止听写），次键 = onSurface 淡底圆。禁用底 0.12/前景 0.38。
class _ComposerKey extends StatelessWidget {
  const _ComposerKey({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !enabled
                ? scheme.onSurface.withValues(alpha: 0.12)
                : primary
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.06),
          ),
          child: Icon(
            icon,
            size: primary ? 20 : 22,
            color: !enabled
                ? scheme.onSurface.withValues(alpha: 0.38)
                : primary
                    ? scheme.onPrimary
                    : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 待发附件的完整行为（选图 → 压缩）；测试注入假实现。
typedef AttachmentPicker = Future<PendingAttachment?> Function();

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.running,
    required this.busy,
    required this.onSend,
    required this.onCancel,
    this.pickAttachment,
    this.slashCommands = const [],
    this.draftSink,
    this.quoteSink,
    this.onDraftChanged,
    this.initialText = '',
    this.voiceLink,
  });

  final bool running;
  final bool busy;
  final Future<void> Function(String text, List<PendingAttachment> attachments) onSend;
  final VoidCallback onCancel;

  /// null 时隐藏附件按钮（未接选图能力的环境）。
  final AttachmentPicker? pickAttachment;

  /// 斜杠指令目录（task 4.4）；空目录永不弹面板。
  final List<SlashCommand> slashCommands;

  /// 外部填入草稿的通道（空态建议卡片/引用追问）：收到非 null 文本即
  /// 填入输入框（不发送）并清空信号。
  final ValueNotifier<String?>? draftSink;

  /// 引用追问（chat-message-interactions）：非 null 时输入框上方显示
  /// 引用胶囊；随本次发送以 blockquote 前缀并入并清除。
  final ValueNotifier<String?>? quoteSink;

  /// 草稿变更回调（chat-composer：按会话持久化）。
  final ValueChanged<String>? onDraftChanged;

  /// 初始草稿文本（恢复持久化草稿；仅首帧生效）。
  final String initialText;

  /// 听写的连接访问器；null = 无语音入口（保持纯键盘输入，测试环境）。
  /// 听写控制器在本 State 内创建/销毁，文本写入内部输入控制器。
  final VoiceLink? Function()? voiceLink;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _attachments = <PendingAttachment>[];
  bool _picking = false;
  bool _sending = false;
  VoiceInputController? _voice;

  @override
  void initState() {
    super.initState();
    if (widget.initialText.isNotEmpty) {
      _controller.text = widget.initialText;
      _controller.selection =
          TextSelection.collapsed(offset: widget.initialText.length);
    }
    _controller.addListener(() {
      setState(() {});
      widget.onDraftChanged?.call(_controller.text);
    });
    widget.draftSink?.addListener(_onDraftFill);
    widget.quoteSink?.addListener(_onQuoteChanged);
    final linkAccessor = widget.voiceLink;
    if (linkAccessor != null) {
      _voice = VoiceInputController(
        input: _controller,
        bridge: MethodChannelVoiceBridge(),
        link: linkAccessor,
      );
      _voice!.onMessage = _onVoiceMessage;
      _voice!.addListener(_onVoiceChanged);
    }
  }

  @override
  void didUpdateWidget(covariant Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  /// 听写失败/降级的人话提示。
  void _onVoiceMessage(VoiceMessage message) {
    final context = this.context;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message.text)),
    );
    if (message.openSettings) {
      unawaited(_voice?.bridge.openSettings());
    }
  }

  void _onDraftFill() {
    final text = widget.draftSink?.value;
    if (text == null) return;
    widget.draftSink?.value = null;
    setState(() {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    });
    _focusNode.requestFocus();
  }

  void _onQuoteChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.quoteSink?.removeListener(_onQuoteChanged);
    widget.draftSink?.removeListener(_onDraftFill);
    // 听写中离开页面：立即取消并释放麦克风（评审 #6）。
    _voice?.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_picking || _attachments.length >= kAttachmentMaxCount) return;
    _picking = true;
    try {
      final picked = await widget.pickAttachment?.call();
      if (picked != null && mounted) {
        setState(() => _attachments.add(picked));
      }
    } finally {
      _picking = false;
    }
  }

  /// 引文 + 正文：引文以 Markdown blockquote 前缀并入发送文本。
  String get _composedText {
    final quote = widget.quoteSink?.value;
    final text = _controller.text.trim();
    if (quote == null || quote.trim().isEmpty) return text;
    final quoted = quote
        .trim()
        .split('\n')
        .map((line) => '> $line')
        .join('\n');
    return '$quoted\n\n$text';
  }

  Future<void> _submit() async {
    final text = _composedText;
    if (_controller.text.trim().isEmpty || widget.busy || _sending) return;
    _sending = true;
    try {
      await widget.onSend(text, List.unmodifiable(_attachments));
    } on Object {
      // 发送失败：保留文本与附件（压缩成果不丢），错误呈现由 onSend
      // 侧负责（SnackBar 带回原文）。
      return;
    } finally {
      _sending = false;
    }
    _controller.clear();
    widget.quoteSink?.value = null;
    setState(_attachments.clear);
    _focusNode.requestFocus();
  }

  /// 草稿为空且非听写中 → 发送键位显示语音入口（chat-composer）。
  bool get _showMic =>
      !_voiceActive && _controller.text.trim().isEmpty && !widget.busy;

  bool get _voiceActive => (_voice?.phase ?? VoicePhase.idle) != VoicePhase.idle;

  /// 语音入口键（草稿为空时占据发送键位）；听写中变成停止键。
  Widget _buildMicButton(VoiceInputController voice) {
    final phase = voice.phase;
    if (phase == VoicePhase.listening) {
      return _ComposerKey(
        icon: Icons.stop,
        tooltip: '停止听写',
        primary: true,
        onTap: voice.stop,
      );
    }
    if (phase == VoicePhase.transcribing) {
      return const Padding(
        padding: EdgeInsets.only(left: 2),
        child: SizedBox.square(
          dimension: 36,
          child: Padding(
            padding: EdgeInsets.all(9),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return _ComposerKey(
      icon: Icons.mic_none_outlined,
      tooltip: '语音输入',
      onTap: widget.busy ? null : voice.start,
    );
  }

  /// 当前输入是否处于"指令名"阶段：以 / 开头且尚未出现空格 —— 面板
  /// 展示窗口；首个空格后进入参数输入，面板收起。
  List<SlashCommand> get _commandMatches {
    final text = _controller.text;
    if (!text.startsWith('/')) return const [];
    final afterSlash = text.substring(1);
    if (afterSlash.contains(' ')) return const [];
    final token = afterSlash.toLowerCase();
    if (token.isEmpty) return widget.slashCommands;
    return widget.slashCommands
        .where((c) => c.name.toLowerCase().startsWith(token))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final voice = _voice;
    final matches = _commandMatches;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.quoteSink?.value case final quote?) _QuoteChip(
              quote: quote,
              onClear: () => setState(() => widget.quoteSink?.value = null),
            ),
            if (matches.isNotEmpty)
              _SlashPalette(
                matches: matches,
                showPickHint: _controller.text.trim().length > 1,
                onPick: (name) {
                  _controller.text = '/$name ';
                  _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
                  _focusNode.requestFocus();
                },
              ),
            if (_attachments.isNotEmpty) _AttachmentPreviewStrip(
              attachments: _attachments,
              onRemove: (a) => setState(() => _attachments.remove(a)),
            ),
            if (_voice case final voice? when _voiceActive)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.mic, size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: voice.level,
                        builder: (context, _) => LinearProgressIndicator(
                          value: voice.level.value.clamp(0.0, 1.0),
                          minHeight: 3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      voice.phase == VoicePhase.transcribing ? '转写中…' : '听写中…',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            // 输入条 = chrome 玻璃胶囊（radius 28）+ 36 圆键端盖（dsh
            // 数字组：键径 36、圆角 28、文字 15/1.45）。
            GlassSurface(
              tier: GlassTier.chrome,
              radius: 28,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.pickAttachment != null)
                    _ComposerKey(
                      icon: Icons.add_photo_alternate_outlined,
                      tooltip: _attachments.length >= kAttachmentMaxCount
                          ? '最多 $kAttachmentMaxCount 张'
                          : '添加图片',
                      onTap: widget.busy ||
                              _attachments.length >= kAttachmentMaxCount
                          ? null
                          : _pick,
                    ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: !widget.busy,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 15, height: 1.45),
                      decoration: InputDecoration(
                        hintText:
                            widget.running ? '输入将排队，当前轮结束后送出' : '发消息…',
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (widget.running)
                    _ComposerKey(
                      icon: Icons.stop_circle_outlined,
                      tooltip: '打断当前轮',
                      onTap: widget.onCancel,
                    ),
                  if (voice case final voice? when _voiceActive)
                    _buildMicButton(voice)
                  else if (voice != null && _showMic)
                    _buildMicButton(voice)
                  else
                    _ComposerKey(
                      icon: Icons.arrow_upward,
                      tooltip: '发送',
                      primary: true,
                      onTap: widget.busy ? null : _submit,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 斜杠指令面板（task 4.4）：过滤结果列表，点选补全指令名。
class _SlashPalette extends StatelessWidget {
  const _SlashPalette({
    required this.matches,
    required this.onPick,
    this.showPickHint = false,
  });

  final List<SlashCommand> matches;
  final ValueChanged<String> onPick;

  /// 用户仍在敲指令名（未出现空格）→ 首行提示"发送会选中该指令"
  /// （chat-composer：确认语义标示）。
  final bool showPickHint;

  /// 常见指令的中文说明（daemon 目录的 description 多为英文原文；
  /// 未命中回退原文/无说明）。
  static const _zhDescriptions = <String, String>{
    'clear': '清空对话历史并开始新会话',
    'compact': '压缩对话历史，节省上下文',
    'config': '打开配置面板',
    'cost': '显示本会话的用量统计',
    'doctor': '检查 Claude Code 安装状态',
    'help': '帮助与可用指令',
    'init': '初始化项目 CLAUDE.md',
    'login': '登录账号',
    'logout': '退出登录',
    'memory': '编辑项目记忆文件',
    'model': '选择模型',
    'permissions': '查看与设置权限',
    'review': '审查一个 Pull Request',
    'status': '查看系统状态面板',
    'vim': '切换 Vim 编辑模式',
    'terminal-setup': '安装终端 Shift+Enter 换行',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassSurface(
        tier: GlassTier.card,
        radius: 14,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showPickHint)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('发送会选中当前候选指令',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final command = matches[index];
                    final description =
                        _zhDescriptions[command.name] ?? command.description;
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text('/${command.name}', style: AppMono.code),
                      subtitle: description == null
                          ? null
                          : Text(
                              description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                      onTap: () => onPick(command.name),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// 待发附件预览条：缩略图 + 移除键。
class _AttachmentPreviewStrip extends StatelessWidget {
  const _AttachmentPreviewStrip({required this.attachments, required this.onRemove});

  final List<PendingAttachment> attachments;
  final ValueChanged<PendingAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          return Stack(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, right: 8, bottom: 4),
                width: 72,
                height: 72,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Image.memory(attachment.bytes, fit: BoxFit.cover),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: SizedBox(
                  height: 28,
                  width: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '移除附件',
                    onPressed: () => onRemove(attachment),
                    icon: const Icon(Icons.cancel, size: 18),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 引用胶囊（chat-message-interactions）：输入框上方全圆胶囊 —— 引文
/// 单行省略 + ✕ 取消；随发送并入 blockquote。
class _QuoteChip extends StatelessWidget {
  const _QuoteChip({required this.quote, required this.onClear});

  final String quote;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.format_quote_outlined,
                size: 14, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                quote,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 6),
            InkWell(
              onTap: onClear,
              customBorder: const CircleBorder(),
              child: Icon(Icons.close,
                  size: 16, color: theme.colorScheme.onSecondaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}
