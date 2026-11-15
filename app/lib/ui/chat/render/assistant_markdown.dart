/// 助手消息 Markdown 渲染（task 1.2 + chat-streaming-rendering）：
/// gpt_markdown + 自定义代码块 + 流式匀速吐出（pacer）+ 呼吸光标
/// （sentinel + StreamingCursor）+ 残缺 Markdown/公式容错。完成后以服务
/// 端最终全文整体替换。
///
/// 流式性能三件套（对齐 dsh-Go）：① 同文字复用同一 GptMarkdown 实例
/// （父级每事件帧重建时命中缓存，不重解析 Markdown）；② 光标 sentinel
/// `` 经 inlinePatterns 换成 RepaintBoundary 的 StreamingCursor
/// （只重绘光标 2.5px，透明度呼吸不带动整段正文）；③ 代码块流式期间
/// 250ms 节流高亮（见 code_block.dart）。
library;

import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'code_block.dart';
import 'math_guard.dart';
import 'stream_pacer.dart';
import 'stream_repair.dart';
import '../../../theme/palette.dart';
import '../../../theme/typography.dart';
import '../../widgets/streaming_cursor.dart';

/// 流式光标 sentinel：拼在正文末尾，经 inlinePatterns 换成光标 widget。
/// 用私用区码位，永远不会与真实内容冲突。
const _cursorSentinel = '';

/// 光标 inline 模式：sentinel → WidgetSpan（行内居中，跟着换行走）。
InlinePattern _cursorPattern() => InlinePattern(
      pattern: RegExp(_cursorSentinel),
      builder: (context, match, style) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: RepaintBoundary(
          child: StreamingCursor(height: 18),
        ),
      ),
    );

/// Markdown 主题（dsh「Mist」规格）：标题阶 h1 20 → h6 15（w600）、hr
/// 0.5px、行内代码 JetBrainsMono ×0.875 + 0.5px 边框 + radius 6、
/// blockquote bar 3px、bullet 5px、表格 0.5px 方角 + cellPadding h12v8 +
/// 横滚、GitHub alert 五档语义色、`<mark>` 警示底。每档亮度一份静态
/// 实例（调色板固定，不随帧变）。
final Map<Brightness, GptMarkdownThemeData> _mdThemes = {
  for (final b in Brightness.values) b: _buildMarkdownTheme(b)
};

GptMarkdownThemeData _buildMarkdownTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final t = light ? LightPalette.instance : DarkPalette.instance;
  return GptMarkdownThemeData(
    brightness: brightness,
    h1: TextStyle(fontSize: 20, height: 1.4, fontWeight: FontWeight.w600, color: t.onSurface, locale: const Locale('zh', 'CN')),
    h2: TextStyle(fontSize: 18, height: 1.4, fontWeight: FontWeight.w600, color: t.onSurface, locale: const Locale('zh', 'CN')),
    h3: TextStyle(fontSize: 16.5, height: 1.4, fontWeight: FontWeight.w600, color: t.onSurface, locale: const Locale('zh', 'CN')),
    h4: TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.w600, color: t.onSurface, locale: const Locale('zh', 'CN')),
    h5: TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w600, color: t.onSurface, locale: const Locale('zh', 'CN')),
    h6: TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w600, color: t.onSurfaceVariant, locale: const Locale('zh', 'CN')),
    hrLineThickness: 0.5,
    hrLineColor: t.outlineVariant,
    hrLinePadding: const EdgeInsets.symmetric(vertical: 12),
    linkColor: t.primary,
    linkHoverColor: t.primary.withValues(alpha: 0.7),
    autoAddDividerLineAfterH1: false,
    inlineCode: InlineCodeStyle(
      fontFamily: AppType.monoFamily,
      fontFamilyFallback: AppType.monoFallback,
      fontSizeFactor: 0.875,
      backgroundColor: light ? const Color(0xFFEEF1F9) : const Color(0xFF272C36),
      borderColor: t.outlineVariant,
      borderWidth: 0.5,
      borderRadius: const Radius.circular(6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    ),
    styleSheet: GptMarkdownStyleSheet(
      blockQuote: BlockQuoteStyle(
        barWidth: 3,
        barRadius: const Radius.circular(2),
        barColor: t.outline,
      ),
      list: const ListStyle(bulletSize: 5),
      table: TableStyle(
        borderWidth: 0.5,
        borderColor: t.outlineVariant,
        borderRadius: Radius.zero,
        cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        headerBackground:
            light ? const Color(0xFFEEF1F9) : const Color(0xFF272C36),
        overflow: TableOverflow.scroll,
      ),
      alert: AlertStyle(
        borderRadius: const Radius.circular(10),
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        titleGap: 4,
        note: AlertStyle(color: t.info),
        tip: AlertStyle(color: t.success),
        important: AlertStyle(color: const Color(0xFF6B578F)), // 暮紫
        warning: AlertStyle(color: t.warning),
        caution: AlertStyle(color: t.error),
      ),
      highlight: HighlightStyle(
        backgroundColor: light
            ? const Color(0xFF936123).withValues(alpha: 0.18)
            : const Color(0xFFE6BD7C).withValues(alpha: 0.18),
      ),
      codeBlock: CodeBlockStyle(fontFamily: AppType.monoFamily),
    ),
  );
}

/// pacer 吐出的每一帧冒泡给聊天页（贴底跟随需要看到内容增长 ——
/// 不经 StreamBuilder，普通 setState 不会触发 ChatBody 的滚动逻辑）。
class StreamingFrameNotification extends Notification {
  const StreamingFrameNotification();
}

/// 助手正文 Markdown 视图。空文本显示占位（流式起笔阶段）。
///
/// 流式期间：文字经 [StreamPacer] 匀速吐出（成块增量不闪跳），渲染前
/// 做残缺 Markdown 补全与公式判定守卫；完成时全量放行并以原始全文
/// 整体替换 —— 上一帧的补全/光标痕迹不会残留。
class AssistantMarkdown extends StatefulWidget {
  const AssistantMarkdown({
    super.key,
    required this.text,
    this.streaming = false,
    this.onLinkTap,
  });

  final String text;

  /// 流式期间为 true：pacer 吐字 + 残缺补全 + 流式光标。
  final bool streaming;

  /// 链接点击回调（测试与后续导航用）。
  final void Function(String url)? onLinkTap;

  @override
  State<AssistantMarkdown> createState() => _AssistantMarkdownState();
}

class _AssistantMarkdownState extends State<AssistantMarkdown>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final StreamPacer _pacer = StreamPacer();

  /// 当前显示长度（streaming 时 0..text.length）。
  int _displayLength = 0;

  /// 同（文字, 光标, 亮度）复用的 GptMarkdown 实例缓存（流式三件套 ①）；
  /// 亮度进 key —— 主题切换时同一文字必须换主题包裹重建。
  String? _builtSource;
  bool? _builtCursor;
  Brightness? _builtBrightness;
  Widget? _builtBody;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _sync();
  }

  @override
  void didUpdateWidget(covariant AssistantMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// 同步 pacer 目标与 ticker 状态：落后时跑 ticker 逐帧吐字，
  /// 追上即停（不空转）；完成时全量放行。
  void _sync() {
    if (!widget.streaming) {
      _displayLength = widget.text.length;
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    _pacer.setTotal(widget.text.length);
    if (_pacer.released < _pacer.total) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    setState(() {
      _displayLength = _pacer.tick(elapsed.inMilliseconds);
    });
    const StreamingFrameNotification().dispatch(context);
    if (_pacer.released >= _pacer.total && _ticker.isActive) _ticker.stop();
  }

  /// 按 Unicode 码位安全截断（不劈开代理对）。
  String _safeSubstring(String text, int length) {
    if (length >= text.length) return text;
    var end = length;
    while (end > 0 && end < text.length && text.codeUnitAt(end) >= 0xD800 && text.codeUnitAt(end) <= 0xDBFF) {
      end--;
    }
    return text.substring(0, end);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (text.isEmpty) {
      return Text(
        widget.streaming ? '…' : '',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    if (!widget.streaming) {
      // 完成：原始全文整体替换（LaTeX 判定守卫只修误判，不改公式）。
      return _build(
        context,
        guardMathDelimiters(text),
        cursor: false,
      );
    }
    final displayed = _safeSubstring(text, _displayLength);
    // 顺序：先补悬空展示公式的闭合占位（此时 `$$` 尚未配对、可检出），
    // 再做公式判定守卫——守卫会把不成对的 `$` 转义，反过来跑会让
    // 悬空检测永远失配（评审 #4）。
    return _build(
      context,
      guardMathDelimiters(
        closeDanglingDisplayMath(repairStreamingMarkdown(displayed)),
      ),
      cursor: true,
    );
  }

  Widget _build(BuildContext context, String source, {required bool cursor}) {
    final brightness = Theme.of(context).brightness;
    // 同（源文, 光标, 亮度）直接复用上一帧的 widget 实例：不重解析。
    if (_builtSource == source && _builtCursor == cursor && _builtBrightness == brightness) {
      return _builtBody!;
    }
    _builtSource = source;
    _builtCursor = cursor;
    _builtBrightness = brightness;
    _builtBody = GptMarkdownTheme(
      gptThemeData: _mdThemes[brightness]!,
      child: GptMarkdown(
      cursor ? '$source$_cursorSentinel' : source,
      style: Theme.of(context).textTheme.bodyLarge,
      // $…$ 视为 LaTeX（gpt_markdown 默认关闭）；价格语境由
      // guardMathDelimiters 在渲染前转义，两者配合实现 spec 的判定规则。
      useDollarSignsForLatex: true,
      onLinkTap: widget.onLinkTap == null
          ? null
          : (url, title) {
              // 链接安全白名单（dsh 同款）：只放行 http/https/mailto，
              // tel:/intent:/javascript: 等一律不开。
              final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
              if ({'http', 'https', 'mailto'}.contains(scheme)) {
                widget.onLinkTap!(url);
              }
            },
      inlinePatterns: cursor ? [_cursorPattern()] : null,
      // 列表 marker gutter 对齐（chat-streaming-rendering）：统一两列
      // 解剖 —— 固定 min 宽度的图形/编号列 + 文字列；编号位数多时列宽
      // 自适应加宽；嵌套子列表随 child 缩进，marker 天然对齐父文字列。
      orderedListBuilder: (context, no, child, config) => _ListGutter(
        gutterMin: 24,
        marker: Text(
          '$no.',
          style: config.style,
          textAlign: TextAlign.right,
        ),
        child: child,
      ),
      unOrderedListBuilder: (context, child, config) => _ListGutter(
        gutterMin: 16,
        marker: Text('•', style: config.style, textAlign: TextAlign.right),
        child: child,
      ),
        // 回复内图片（§9）：data: URI 直接解码；http(s) 走网络图；其余
        // scheme 封禁。inline 限高 480，等比变窄；解码失败给占位块。
        imageBuilder: (context, imageUrl, width, height) {
          Widget? child;
          double? w = width;
          double? h = height;
          if (h != null && h > 480) {
            // 限高 480：宽高等比缩到上限内。
            final scale = 480 / h;
            h = 480;
            w = (w ?? 480) * scale;
          }
          final uri = Uri.tryParse(imageUrl);
          if (uri?.scheme == 'data') {
            final data = uri!.data;
            child = data == null
                ? null
                : Image.memory(
                    Uint8List.fromList(data.contentAsBytes()),
                    width: w,
                    height: h,
                    fit: BoxFit.contain,
                  );
          } else if (uri?.scheme == 'http' || uri?.scheme == 'https') {
            child = Image.network(
              imageUrl,
              width: w,
              height: h,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => _imagePlaceholder(context),
            );
          }
          child ??= _imagePlaceholder(context);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: ClipRSuperellipse(
              borderRadius: const BorderRadius.all(Radius.circular(14)),
              child: child,
            ),
          );
        },
        // 代码块：流式期间内部按 250ms 节流高亮（CodeBlockView 自理）。
        // mermaid 块的分发在 CodeBlockView 内按语言名进行。
        codeBuilder: (context, name, code, closed) => CodeBlockView(
          code: code,
          language: name,
          closed: closed,
          streaming: widget.streaming,
        ),
      ),
    );
    return _builtBody!;
  }
}

/// 图片占位/错误块（radius md14，浅底）。
Widget _imagePlaceholder(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    height: 120,
    color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
    alignment: Alignment.center,
    child: Icon(Icons.broken_image_outlined,
        size: 24, color: scheme.onSurfaceVariant),
  );
}

/// 列表两列解剖：固定 min 宽度的 marker 列（右对齐，位数多自适应加宽）
/// + 文字列。嵌套子列表在 child 内部再起 gutter，marker 对齐父文字列。
class _ListGutter extends StatelessWidget {
  const _ListGutter({
    required this.marker,
    required this.child,
    required this.gutterMin,
  });

  final Widget marker;
  final Widget child;
  final double gutterMin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minWidth: gutterMin),
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: marker,
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
