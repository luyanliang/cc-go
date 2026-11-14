/// 输入区（task 6.3/6.4 + transcript-data-protocol 2.3）：文本框 + 发送；
/// 运行中出现打断按钮；附件按钮（选图回调可注入，测试注入假实现），
/// 待发附件以预览条展示、可逐个移除、随消息一并送出。
library;

import 'package:material_ui/material_ui.dart';

import '../../state/attachment.dart';
import '../../state/chat_controller.dart' show SlashCommand;
import '../theme/app_style.dart';

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
  });

  final bool running;
  final bool busy;
  final Future<void> Function(String text, List<PendingAttachment> attachments) onSend;
  final VoidCallback onCancel;

  /// null 时隐藏附件按钮（未接选图能力的环境）。
  final AttachmentPicker? pickAttachment;

  /// 斜杠指令目录（task 4.4）；空目录永不弹面板。
  final List<SlashCommand> slashCommands;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _attachments = <PendingAttachment>[];
  bool _picking = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
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

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.busy || _sending) return;
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
    setState(_attachments.clear);
    _focusNode.requestFocus();
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
    final matches = _commandMatches;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (matches.isNotEmpty)
              _SlashPalette(
                matches: matches,
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (widget.pickAttachment != null)
                  IconButton(
                    tooltip: _attachments.length >= kAttachmentMaxCount
                        ? '最多 $kAttachmentMaxCount 张'
                        : '添加图片',
                    onPressed: widget.busy || _attachments.length >= kAttachmentMaxCount
                        ? null
                        : _pick,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled: !widget.busy,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: widget.running ? '输入将排队，当前轮结束后送出' : '发消息…',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.running)
                  IconButton.filledTonal(
                    tooltip: '打断当前轮',
                    onPressed: widget.onCancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                const SizedBox(width: 4),
                IconButton.filled(
                  tooltip: '发送',
                  onPressed: widget.busy ? null : _submit,
                  icon: const Icon(Icons.send_outlined),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 斜杠指令面板（task 4.4）：过滤结果列表，点选补全指令名。
class _SlashPalette extends StatelessWidget {
  const _SlashPalette({required this.matches, required this.onPick});

  final List<SlashCommand> matches;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: matches.length,
            itemBuilder: (context, index) {
              final command = matches[index];
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('/${command.name}', style: AppMono.code),
                subtitle: command.description == null
                    ? null
                    : Text(
                        command.description!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                onTap: () => onPick(command.name),
              );
            },
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
