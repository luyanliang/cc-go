/// 转录行渲染：derive（chat_row_model.dart）出行列表后逐行装配 ——
/// 用户气泡 / 助手 Markdown / 工具折叠行 / 工具分组行 / notice 提示条 /
/// 权限卡 / 排队气泡。结构与分组决策都在 derive 层，这里只认行。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/transcript.dart';
import 'chat_row_model.dart';
import 'empty_state.dart';
import 'message_menu.dart';
import 'process_rows.dart';
import 'widgets/stream_row.dart';
import 'widgets/thinking_ticker.dart';
import '../../ui/widgets/expand_reveal.dart';
import '../widgets/pill_badge.dart';
import 'image_viewer.dart';
import 'render/assistant_markdown.dart';
import 'render/copy_button.dart';
import 'tool_views.dart';
import '../../theme/squircle.dart';
import '../../theme/spacing.dart';
import '../theme/app_style.dart';
import '../widgets/mono_block.dart';

/// 转录列表（chat-list-scroll）：居中锚定的 CustomScrollView —— 视口
/// 切成锚点前/后两段 sliver，锚点前增长（加载更早历史）与锚点后增长
/// （流式追加）都不移动用户正在看的内容；贴底时锚定首行 + 由 ChatBody
/// 的贴底跟随同帧追新。
class TranscriptListView extends StatefulWidget {
  const TranscriptListView({
    super.key,
    required this.items,
    required this.queuedTexts,
    required this.loaded,
    required this.scrollController,
    this.padding,
    this.physics,
    this.onRespondPermission,
    this.onSuggestion,
    this.onQuote,
    this.onQueuedRemove,
    this.onQueuedEdit,
  });

  final List<TranscriptItem> items;
  final List<String> queuedTexts;
  final bool loaded;
  final ScrollController scrollController;

  /// 贴底跟随物理（ChatBody 注入 _FollowPhysics）。
  final ScrollPhysics? physics;

  /// 列表 padding（玻璃 chrome 下穿行的顶部/底部留白由 ChatBody 计算）。
  final EdgeInsetsGeometry? padding;

  final Future<void> Function(String itemId, bool allow, bool allowToolForSession)?
      onRespondPermission;

  /// 空态建议卡片点击（填入输入框，不发送）；null = 纯展示。
  final ValueChanged<String>? onSuggestion;

  /// 引用某条消息（进引用胶囊）；null = 无引用能力。
  final ValueChanged<String>? onQuote;

  /// 撤回排队消息（仅未送出条目）。
  final void Function(int index)? onQueuedRemove;

  /// 编辑排队消息后重发。
  final void Function(int index, String newText)? onQueuedEdit;

  @override
  State<TranscriptListView> createState() => _TranscriptListViewState();
}

class _TranscriptListViewState extends State<TranscriptListView> {
  // 每实例一把 key：静态 GlobalObjectKey 会让并存的两份聊天页（新对话
  // 推入第二个 ChatScreen、历史接管跳转）在转场期撞 duplicate key。
  late final Key _centerKey = UniqueKey();

  /// 当前行的派生缓存（didUpdateWidget 里做分界决策需要旧行表）。
  List<ChatRow> _rows = const [];

  /// 分界行主键（居中锚定的"锚"）：视口坐标原点固定在这行的前缘 ——
  /// 前段（更早历史）向上长、后段（流式追加）向下长，两侧增长都
  /// 不移动分界行两侧既有内容的像素位置（sliver 语义：子行只在一端
  /// 增长时，另一端既有行的位置不变）。坐标原点不改，就不需要任何
  /// 滚动位置补偿 —— 这是居中锚定的核心（chat-list-scroll spec）。
  ///
  /// 分界行只在一种情况下移动：列表贴顶（pixels ≈ 0，只读回放翻页/
  /// 会话刚打开）时前插了新行 —— 此时重置到新表首行，让更早内容直接
  /// 可见（等价旧 ListView 的前插语义，offset 0 处无可见跳变）。
  String? _boundaryKey;

  @override
  void initState() {
    super.initState();
    _rows = deriveChatRows(
        items: widget.items, queuedTexts: widget.queuedTexts);
    _boundaryKey = _rows.isEmpty ? null : _rows.first.key;
  }

  @override
  void didUpdateWidget(covariant TranscriptListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameItems = _listEquals(oldWidget.items, widget.items) &&
        _listEquals(oldWidget.queuedTexts, widget.queuedTexts);
    if (sameItems) return;

    final newRows = deriveChatRows(
        items: widget.items, queuedTexts: widget.queuedTexts);
    _resolveBoundary(newRows);
    _rows = newRows;
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _resolveBoundary(List<ChatRow> newRows) {
    if (newRows.isEmpty) {
      _boundaryKey = null;
      return;
    }
    final position = widget.scrollController.hasClients
        ? widget.scrollController.position
        : null;
    final atTop = position == null || position.pixels.abs() < 4;
    // 贴顶前插 → 移分界到新表首行（更早内容直接可见，offset 0 无跳变）。
    if (atTop || _boundaryKey == null) {
      _boundaryKey = newRows.first.key;
      return;
    }
    // 分界行仍在（用户在中部/底部阅读）→ 保持，两侧增长不动视点。
    if (newRows.any((r) => r.key == _boundaryKey)) {
      return;
    }
    // 分界行被折叠/移除（回合折叠把过程行收走是唯一常规来源）：
    // 回退到首行。此时用户多半不在分界附近，坐标重置由贴底跟随或
    // 用户的重新滚动消化。
    _boundaryKey = newRows.first.key;
  }

  int _boundaryIndex() {
    if (_boundaryKey == null) return 0;
    final i = _rows.indexWhere((r) => r.key == _boundaryKey);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.loaded && widget.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.items.isEmpty && widget.queuedTexts.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => ListView(
          controller: widget.scrollController,
          children: [
            SizedBox(
              height: constraints.maxHeight,
              child: Center(
                child: ChatEmptyState(onSuggestion: widget.onSuggestion),
              ),
            ),
          ],
        ),
      );
    }
    final rows = _rows;
    final boundaryIndex = _boundaryIndex().clamp(0, rows.length);
    final before = rows.sublist(0, boundaryIndex);
    final after = rows.sublist(boundaryIndex);
    // padding 拆给两段（前段吃 top、后段吃 bottom），避免锚点交界处双份。
    final pad = (widget.padding ?? const EdgeInsets.symmetric(vertical: 8))
        as EdgeInsets;
    final bottomPad = SliverPadding(
        padding: EdgeInsets.only(
            bottom: pad.bottom, left: pad.left, right: pad.right));

    // 行主键必须挂给 framework：历史分页向前插页、回合折叠把 N 行收成
    // 2 行时槽位会平移，无 key 的展开/复制状态会跳到别的条目上。
    Widget rowAt(ChatRow row, int index, List<ChatRow> list) => KeyedSubtree(
          key: ValueKey<String>(row.key),
          child: Padding(
            padding: EdgeInsets.only(top: _gapBefore(list, index)),
            child: _rowWidget(row),
          ),
        );

    return CustomScrollView(
      controller: widget.scrollController,
      center: _centerKey,
      physics: widget.physics,
      // 键盘只随本列表的拖动收起。
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        // 锚点前段：倒序排（首子行最靠近锚点），增长向上延伸。
        if (before.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.only(left: pad.left, right: pad.right),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => rowAt(before[before.length - 1 - index],
                    before.length - 1 - index, before),
                childCount: before.length,
              ),
            ),
          ),
        // 锚点后段（center）：增长向下延伸，视口锚在它的前缘。
        SliverPadding(
          key: _centerKey,
          padding: EdgeInsets.only(
              top: pad.top, left: pad.left, right: pad.right),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => rowAt(after[index], index, after),
              childCount: after.length,
            ),
          ),
        ),
        bottomPad,
      ],
    );
  }

  /// 行间距阶梯（dsh-Go 同款）：换轮 24 / 同轮 8 / 相邻过程行 0 /
  /// 卡片 12 / 脚注 4。水平 gutter 16 由各行/列表承担。
  double _gapBefore(List<ChatRow> rows, int i) {
    if (i <= 0) return 0;
    final prev = rows[i - 1];
    final cur = rows[i];
    bool isProcess(ChatRow r) => r is ToolRow || r is ToolGroupRow || r is NoticeRow;
    if (cur is FootnoteRow) return 4;
    if (cur is PermissionRow || cur is TurnFoldRow) return 12;
    if (cur is UserRow || cur is QueuedRow) return 24; // 新一轮
    if (cur is AssistantRow) {
      return prev is AssistantRow ? AppSpace.inTurn : AppSpace.betweenTurns;
    }
    if (isProcess(cur)) return isProcess(prev) ? 0 : AppSpace.inTurn;
    return AppSpace.inTurn;
  }

  /// 行装配的唯一入口（折叠区内部也走这里，见 [insideFold]）。
  Widget _rowWidget(ChatRow row, {bool insideFold = false}) {
    return switch (row) {
      UserRow(:final item) => _UserBubble(
          item: item,
          onQuote:
              widget.onQuote == null ? null : () => widget.onQuote!(item.text)),
      AssistantRow(:final item, :final turnEnd) => _AssistantText(
          item: item,
          turnEnd: turnEnd,
          onQuote:
              widget.onQuote == null ? null : () => widget.onQuote!(item.text)),
      ToolRow(:final item) => _ToolRow(item: item),
      ToolGroupRow(:final tools) => _ToolGroupTile(tools: tools),
      // 回合折叠行（task 6.2）：展开后过程条目复用同一套行装配。
      TurnFoldRow() => insideFold
          ? const SizedBox.shrink()
          : _TurnFoldTile(
              row: row,
              rowBuilder: (inner) => _rowWidget(inner, insideFold: true),
            ),
      NoticeRow(:final item) => _NoticeBand(item: item),
      // 权限卡片内联在对话流中：应答后该条目状态翻转，derive 下一帧
      // 自动回到普通工具行。折叠资格判定排除了待授权工具，折叠区内
      // 按构造不可能出现。
      PermissionRow(:final item) => insideFold
          ? const SizedBox.shrink()
          : PermissionCard(item: item, onRespond: widget.onRespondPermission),
      QueuedRow(:final text, :final index) => _QueuedBubble(
          text: text,
          index: index,
          onRemove: widget.onQueuedRemove,
          onEdit: widget.onQueuedEdit,
        ),
      FootnoteRow foot => _FootnoteLine(fold: foot.fold, seconds: foot.seconds),
    };
  }
}

/// 内联权限卡片（task 7.1）：工具名 + 等宽参数 + 允许/拒绝 + 免问勾选。
class PermissionCard extends StatefulWidget {
  const PermissionCard({super.key, required this.item, this.onRespond});

  final TranscriptItem item;
  final Future<void> Function(String itemId, bool allow, bool allowToolForSession)?
      onRespond;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  bool _allowForSession = false;
  bool _busy = false;

  Future<void> _respond(bool allow) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRespond?.call(widget.item.id, allow, _allowForSession);
    } on Object {
      // 应答没送达（掉线/超时）——重新启用按钮允许重试；条目状态未变，
      // 卡片依旧是 awaiting-permission。
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      // 审批卡（chat-transcript-rows）：醒目但不靠大面积红 —— 玻璃卡
      // 外形 + 警示色盾牌与细线强调。
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
        border: Border.all(color: AppColors.waiting.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, color: AppColors.waiting, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '允许运行这个工具？',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              PillBadge.tinted(
                widget.item.toolName ?? '工具',
                color: AppColors.waiting.withValues(alpha: 0.15),
                onColor: theme.colorScheme.onSurface,
              ),
            ],
          ),
          if (widget.item.toolInput != null && widget.item.toolInput!.isNotEmpty) ...[
            const SizedBox(height: 8),
            MonoBlock.text(
              const JsonEncoder.withIndent('  ').convert(widget.item.toolInput!),
            ),
          ],
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _allowForSession,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _allowForSession = v ?? false),
              title: const Text('本次会话不再询问此类工具',
                  style: TextStyle(fontSize: 13)),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => _respond(false),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : () => _respond(true),
                child: const Text('允许'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 回合折叠摘要行（task 6.2）：已收起的过程条目一行概览，默认收起；
/// 展开后过程条目经 [rowBuilder] 走同一套行装配还原，最终回答始终在
/// 折叠行之外。
class _TurnFoldTile extends StatelessWidget {
  const _TurnFoldTile({required this.row, required this.rowBuilder});

  final TurnFoldRow row;
  final Widget Function(ChatRow row) rowBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = [
      if (row.toolCount > 0) '${row.toolCount} 次工具调用',
      if (row.messageCount > 0) '${row.messageCount} 条消息',
    ];
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(Icons.unfold_more, size: 18, color: theme.colorScheme.outline),
      title: Text('已收起 · ${parts.join(' · ')}', style: theme.textTheme.labelMedium),
      childrenPadding: const EdgeInsets.only(left: 8),
      children: [
        for (final inner in deriveChatRows(items: row.process, foldTurns: false))
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: rowBuilder(inner),
          ),
      ],
    );
  }
}

/// 连续工具调用分组行（task 3.2）：折叠单行显示次数与工具名概览，
/// 展开列出组内每次调用（复用 _ToolRow）。
class _ToolGroupTile extends StatelessWidget {
  const _ToolGroupTile({required this.tools});

  final List<TranscriptItem> tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = tools.map((t) => t.toolName ?? '工具').toSet().join(' · ');
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.build_circle_outlined, size: 20),
      title: Text(
        '工具调用 × ${tools.length}',
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: names.isEmpty
          ? null
          : Text(names, maxLines: 1, overflow: TextOverflow.ellipsis),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      children: [for (final tool in tools) _ToolRow(item: tool)],
    );
  }
}

class _UserBubble extends StatefulWidget {
  const _UserBubble({required this.item, this.onQuote});

  final TranscriptItem item;

  /// 引用回调（非 null 才显示引用项）。
  final VoidCallback? onQuote;

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    // dsh 几何：右对齐、最大宽 82%、padding h16 v8、squircle lg20；
    // 附件在气泡上方右对齐（不塞进气泡）。
    return Align(
      alignment: Alignment.centerRight,
      child: LayoutBuilder(builder: (context, constraints) {
        Widget bubble = Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: ShapeDecoration(
            color: scheme.primaryContainer,
            shape: Squircle.border(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 密钥遮罩（chat-message-interactions）：疑似凭据段屏显为
              // chip，点开逐段查看；复制/引用仍是原文（菜单里拿 item.text）。
              GestureDetector(
                onLongPress: () => showMessageMenu(context,
                    text: item.text, onQuote: widget.onQuote),
                child: SecretMaskedText(item.text),
              ),
            ],
          ),
        );
        final maxWidth = constraints.maxWidth * 0.82;
        if (item.attachments.isNotEmpty) {
          // 附件缩略图（task 2.4）：气泡上方右对齐；点开全屏，长按保存/分享。
          bubble = Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  for (final attachment in item.attachments)
                    GestureDetector(
                      onTap: () =>
                          showAttachmentFullScreen(context, attachment),
                      onLongPress: () =>
                          _imageActions(context, attachment.dataBase64),
                      child: Container(
                        width: 96,
                        height: 96,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: scheme.surfaceContainerHighest,
                        ),
                        child: Image.memory(
                          base64Decode(attachment.dataBase64),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              bubble,
            ],
          );
        }
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: bubble,
        );
      }),
    );
  }

  /// 图片长按动作（chat-message-interactions）：保存到相册 / 系统分享。
  Future<void> _imageActions(BuildContext context, String dataBase64) async {
    final messenger = ScaffoldMessenger.of(context);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('保存到相册'),
              onTap: () => Navigator.of(sheetContext).pop('save'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('分享'),
              onTap: () => Navigator.of(sheetContext).pop('share'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    try {
      final bytes = base64Decode(dataBase64);
      if (chosen == 'save') {
        // 相册保存权限（Android 13+ 由系统相册接管，无需 WRITE_EXTERNAL_STORAGE）。
        await Gal.requestPermission();
        await Gal.putImageBytes(Uint8List.fromList(bytes),
            name: 'cc-go-${DateTime.now().millisecondsSinceEpoch}');
        messenger.showSnackBar(const SnackBar(content: Text('已保存到相册')));
      } else {
        final tmp = File(
            '${Directory.systemTemp.path}/cc-go-${DateTime.now().millisecondsSinceEpoch}.jpg')
          ..writeAsBytesSync(bytes);
        await SharePlus.instance.share(ShareParams(files: [
          XFile(tmp.path, mimeType: 'image/jpeg'),
        ]));
      }
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$e')));
    }
  }
}

class _AssistantText extends StatelessWidget {
  const _AssistantText({required this.item, this.turnEnd = false, this.onQuote});

  final TranscriptItem item;

  /// 回合末 → 回答下方挂安静操作行（复制/分享/引用）。
  final bool turnEnd;

  /// 引用回调（引用本条消息；非 null 才显示引用项）。
  final VoidCallback? onQuote;

  void _menu(BuildContext context) {
    showMessageMenu(context, text: item.text, onQuote: onQuote);
  }

  @override
  Widget build(BuildContext context) {
    final streaming = item.isStreamingAssistant;
    return Padding(
      // 助手正文无框全宽裸排；垂直节奏归列表的行间距阶梯，水平 gutter 16。
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Opacity(
        // 流式期间整体降不透明度示意"未完成"；完成后恢复。
        opacity: streaming ? 0.85 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // thinking 数据一直在协议里流动（task 5.1 补展示）：
            // 默认收起，点开可读全文。
            if (item.thinking.isNotEmpty)
              _ThinkingSection(thinking: item.thinking, streaming: streaming),
            // 链接点击用系统浏览器打开（gpt_markdown 只在回调非空时
            // 才挂点击处理器，不传就是死链）。
            GestureDetector(
              onLongPress: () => _menu(context),
              child: AssistantMarkdown(
                text: item.text,
                streaming: streaming,
                onLinkTap: (url) => launchUrl(Uri.parse(url)),
              ),
            ),
            if (!streaming && item.text.isNotEmpty) ...[
              // 完成且非空才提供整条复制（复制的是 Markdown 原文）。
              CopyIconButton(text: item.text, tooltip: '复制消息'),
              if (turnEnd && !streaming) _TurnEndActions(item: item, onQuote: onQuote),
            ],
          ],
        ),
      ),
    );
  }
}

/// 回合末操作行（chat-message-interactions）：安静图标行 —— 复制/分享/
/// 引用，只在回合完成后出现。
class _TurnEndActions extends StatelessWidget {
  const _TurnEndActions({required this.item, this.onQuote});

  final TranscriptItem item;
  final VoidCallback? onQuote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget action(IconData icon, String tooltip, VoidCallback? onTap) => IconButton(
          icon: Icon(icon, size: 18),
          color: theme.colorScheme.onSurfaceVariant,
          tooltip: tooltip,
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        action(Icons.copy_outlined, '复制',
            () => Clipboard.setData(ClipboardData(text: item.text))),
        action(Icons.ios_share, '分享', () async {
          await SharePlus.instance.share(ShareParams(text: item.text));
        }),
        action(Icons.format_quote_outlined, '引用', onQuote),
      ],
    );
  }
}

/// 助手思考 pill（chat-transcript-rows + dsh-Go 思考窗口）：收起为一行
/// 预览，流式时标签扫光 + 恒高三行实时窗口（匀速上移）；点开看全文。
class _ThinkingSection extends StatefulWidget {
  const _ThinkingSection({required this.thinking, this.streaming = false});

  final String thinking;

  /// 助手消息是否仍在流式（决定 pill 标题与实时窗口）。
  final bool streaming;

  @override
  State<_ThinkingSection> createState() => _ThinkingSectionState();
}

class _ThinkingSectionState extends State<_ThinkingSection> {
  bool _expanded = false;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ThinkingSection old) {
    super.didUpdateWidget(old);
    // 流式跟随：展开且文本增长时吸底显示最新思考。
    if (_expanded && old.thinking != widget.thinking && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    // 一轮结束强制收回手动展开（dsh 同款）。
    if (old.streaming && !widget.streaming) _expanded = false;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 收起预览：全文第一行去加粗标记。
  String get _preview {
    final first = widget.thinking.trimRight().split('\n').first;
    return first.replaceAll('**', '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: kProcessRowPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StreamRowFrame(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                StreamLead(
                  child: Container(
                    width: StreamRow.lead,
                    height: StreamRow.lead,
                    decoration: BoxDecoration(
                      color: (widget.streaming
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.psychology_outlined,
                      size: 15,
                      color: widget.streaming
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: StreamRow.gap),
                // 单行布局（dsh 同款）：标签 + 间隔点 + 一行预览。
                Expanded(
                  child: Row(
                    children: [
                      ThinkingLabel('思考', active: widget.streaming),
                      if (!widget.streaming && _preview.isNotEmpty) ...[
                        const StreamDot(),
                        Expanded(
                          child: Text(
                            _preview,
                            style: StreamRow.detail(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                StreamChevron(open: _expanded),
              ],
            ),
          ),
          // 流式实时窗口：恒高三行，写满一行匀速上滑（不随帧追底）。
          if (widget.streaming)
            Padding(
              padding: const EdgeInsets.only(
                  left: StreamRow.indent, top: 2, bottom: 2, right: 8),
              child: ThinkingTicker(text: widget.thinking),
            ),
          ExpandReveal(
            open: _expanded,
            child: ProcessDetail(
              child: SizedBox(
                height: 120,
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SelectableText(
                    widget.thinking,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.item});

  final TranscriptItem item;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    // 状态表：状态 → (标签, 语义, 状态字形)。行主字形按工具视觉类别
    // （AppToolGlyph），状态由字形色 + 尾部文字标签表达 —— 颜色不单独
    // 表达状态。
    final (label, status, statusIcon) = switch (item.status) {
      'running' => ('运行中', AppStatus.active, Icons.sync),
      'awaiting-permission' => ('待授权', AppStatus.waiting, Icons.lock_clock),
      'done' => ('完成', AppStatus.success, Icons.check_circle),
      'denied' => ('已拒绝', AppStatus.neutral, Icons.block),
      'error' => ('出错', AppStatus.error, Icons.error_outline),
      _ => (item.status, AppStatus.neutral, Icons.build_circle_outlined),
    };
    final overview = toolSubtitleFor(item) ?? item.summary;
    final detail = _detail(context, item);
    // 行尾状态条（dsh 风格）：运行中转 spinner、失败 ✕、拒绝/待授权小字、
    // **成功默认安静**；diff 计数由工具详情自身表达。
    final Widget? trailing = switch (item.status) {
      'running' => SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: status.color,
          ),
        ),
      'error' => Icon(statusIcon, size: 16, color: status.color),
      'done' => null,
      _ => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(statusIcon, size: 12, color: status.color),
            const SizedBox(width: 3),
            Text(
              label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: status.color),
            ),
          ],
        ),
    };
    return Padding(
      padding: kProcessRowPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProcessLine(
            glyph: AppToolGlyph.forTool(item.toolName ?? ''),
            glyphColor: status.color,
            title: item.toolName ?? '工具',
            subtitle: (overview == null || overview.isEmpty) ? label : overview,
            onTap: detail == null ? null : () => setState(() => _expanded = !_expanded),
            expanded: _expanded,
            trailing: trailing,
          ),
          if (_expanded && detail != null) detail,
        ],
      ),
    );
  }

  /// 展开详情：定制视图优先（task 4.2/4.3）；未知工具回退通用 JSON
  /// 输入 + 摘要。null = 无可展开内容。
  Widget? _detail(BuildContext context, TranscriptItem item) {
    final theme = Theme.of(context);
    return ProcessDetail(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (toolDetailFor(item) case final detail?)
            detail
          else ...[
            if (item.toolInput != null && item.toolInput!.isNotEmpty) ...[
              Text('输入', style: theme.textTheme.labelSmall),
              const SizedBox(height: 2),
              MonoBlock.text(
                const JsonEncoder.withIndent('  ').convert(item.toolInput!),
              ),
            ],
            if (item.summary != null && item.summary!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('结果', style: theme.textTheme.labelSmall),
              const SizedBox(height: 2),
              Text(item.summary!, style: theme.textTheme.bodySmall),
            ],
          ],
          // 结果图片（task 3.4）：所有工具类型统一在详情尾部展示。
          if (item.resultImages.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final image in item.resultImages)
                  GestureDetector(
                    onTap: () => showAttachmentFullScreen(context, image),
                    child: Container(
                      width: 128,
                      height: 128,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      child: Image.memory(base64Decode(image.dataBase64),
                          fit: BoxFit.cover),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _NoticeBand extends StatefulWidget {
  const _NoticeBand({required this.item});

  final TranscriptItem item;

  @override
  State<_NoticeBand> createState() => _NoticeBandState();
}

/// 常见错误码 → 人话短句；未命中回退原文（notice 行正文仍显示原始信息，
/// 短句只作为前缀摘要）。
const _errorCodeHints = <String, String>{
  'rate_limit': '请求太频繁，稍等再试',
  'overloaded': '服务繁忙，稍后重试',
  'payment_required': '需要绑卡或充值后继续',
  'authentication_error': '登录已过期，请重新登录',
  'permission_error': '没有权限执行这个操作',
  'invalid_request_error': '请求参数有问题',
  'api_error': '服务临时出错，重试一次',
  'aborted': '本轮已中止',
};

class _NoticeBandState extends State<_NoticeBand> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final (glyph, glyphColor, fg) = switch (item.level) {
      'warn' => (
          Icons.warning_amber_outlined,
          AppColors.warning,
          AppColors.warningOnTint,
        ),
      'error' => (
          Icons.error_outline,
          AppColors.error,
          AppColors.errorOnTint,
        ),
      _ => (
          Icons.info_outline,
          AppColors.neutral,
          AppColors.neutralOnTint,
        ),
    };
    final hint = _errorCodeHint(item.text);
    final detail = item.resultText;
    return Padding(
      // 出错类保留淡底色带（警示语气），info 用统一过程行几何。
      padding: EdgeInsets.only(
        left: item.level == 'error' ? 12 : kProcessRowPadding.left,
        right: item.level == 'error' ? 12 : kProcessRowPadding.right,
        top: 2,
        bottom: 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProcessLine(
            glyph: glyph,
            glyphColor: glyphColor,
            title: hint ?? item.text,
            subtitle: hint == null ? null : item.text,
            // 有详情可展开时一行 + 省略；无详情则全量换行（评审 #5）。
            titleMaxLines:
                (detail == null || detail.isEmpty) ? null : 1,
            onTap: (detail == null || detail.isEmpty) ? null : () => setState(() => _expanded = !_expanded),
            expanded: _expanded,
            trailing: hint == null
                ? null
                : Icon(glyph, size: 12, color: glyphColor),
          ),
          if (_expanded && detail != null && detail.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 32, top: 4, bottom: 6),
              padding: const EdgeInsets.all(8),
              width: double.infinity,
              decoration: BoxDecoration(
                color: glyphColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                detail,
                style: AppMono.denseLoose.copyWith(color: fg),
              ),
            ),
        ],
      ),
    );
  }

  /// 错误码 → 人话短句；文本形如 "API Error: 429 rate_limit …" 时取
  /// 尾部 token 逐个对照。
  String? _errorCodeHint(String text) {
    for (final entry in _errorCodeHints.entries) {
      if (text.contains(entry.key)) return entry.value;
    }
    return null;
  }
}

/// 回合脚注（chat-transcript-rows）：`42 秒 · 3 次工具调用 ›`；点开
/// 本轮摘要（工具归类计数）。被打断/出错的轮没有折叠 → 自然无脚注。
class _FootnoteLine extends StatefulWidget {
  const _FootnoteLine({required this.fold, required this.seconds});

  final TurnFoldRow fold;

  /// 回合耗时（秒）；null = 不可得，标签里省略。
  final int? seconds;

  @override
  State<_FootnoteLine> createState() => _FootnoteLineState();
}

class _FootnoteLineState extends State<_FootnoteLine> {
  bool _expanded = false;

  String get _label {
    final seconds = widget.seconds;
    final parts = <String>[
      if (seconds != null) _formatSeconds(seconds),
      '${widget.fold.toolCount} 次工具调用',
    ];
    return parts.join(' · ');
  }

  static String _formatSeconds(int s) {
    if (s < 60) return '$s 秒';
    return '${s ~/ 60} 分 ${s % 60} 秒';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 热区加大（真机上小 InkWell 难点中）：整行宽 + 更大纵向 padding。
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 0, top: 2),
              child: Text(
                widget.fold.toolBreakdown
                    .map((e) => '${e.$1} ×${e.$2}')
                    .join(' · '),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _QueuedBubble extends StatelessWidget {
  const _QueuedBubble({
    required this.text,
    required this.index,
    this.onRemove,
    this.onEdit,
  });

  final String text;
  final int index;
  final void Function(int index)? onRemove;
  final void Function(int index, String newText)? onEdit;

  void _menu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.undo_outlined),
              title: const Text('撤回'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onRemove?.call(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑后重发'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _edit(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final field = TextEditingController(text: text);
        return AlertDialog(
          title: const Text('编辑后重发'),
          content: TextField(controller: field, autofocus: true, maxLines: null),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(field.text),
              child: const Text('重发'),
            ),
          ],
        );
      },
    );
    if (edited != null && edited.trim().isNotEmpty) {
      onEdit?.call(index, edited);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        // 排队消息可撤回/编辑重发（chat-message-interactions）：点按编辑，
        // 长按菜单。
        onTap: onEdit == null ? null : () => _edit(context),
        onLongPress: (onRemove == null && onEdit == null)
            ? null
            : () => _menu(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: ShapeDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            shape: Squircle.border(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text),
              const SizedBox(height: 2),
              Text('已排队', style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}
