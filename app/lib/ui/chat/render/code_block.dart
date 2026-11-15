/// 代码块渲染（task 1.2）：语法高亮 + 整块复制；超长与未知语言回退纯等宽。
/// 未闭合围栏（流式期间）按普通代码展示，不报错。
library;

import 'package:material_ui/material_ui.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import 'copy_button.dart';
import 'mermaid_preview.dart';
import '../../../theme/highlight_theme.dart';
import '../../../theme/squircle.dart';
import '../../../theme/tokens.dart';
import '../../theme/app_style.dart';
import '../../widgets/edge_fade.dart';
import '../../widgets/overscroll_forwarder.dart';

/// 超过该长度不做语法高亮（纯等宽渲染），避免大输出卡顿。
const kHighlightMaxChars = 20000;

/// Markdown 语言标注 → re_highlight 语言名的归一。只列语法注册表别名
/// 之外真正缺的映射（ts/py/sh/yml 等内建别名由 getLanguage 自行解析）。
const _languageAliases = {
  'tsx': 'typescript',
  'console': 'bash',
  'properties': 'ini',
  'toml': 'ini',
  'html': 'xml',
  'python3': 'python',
};

final Highlight _highlight = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'dockerfile': langDockerfile,
    'go': langGo,
    'graphql': langGraphql,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'lua': langLua,
    'makefile': langMakefile,
    'markdown': langMarkdown,
    'objectivec': langObjectivec,
    'perl': langPerl,
    'php': langPhp,
    'protobuf': langProtobuf,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'scala': langScala,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

/// 归一后的语言名；未注册返回 null（调用方回退纯等宽）。
String? normalizeLanguage(String raw) {
  final name = raw.trim().toLowerCase();
  if (name.isEmpty) return null;
  final mapped = _languageAliases[name] ?? name;
  return _highlight.getLanguage(mapped) == null ? null : mapped;
}

/// 计算代码块的高亮 span（"Mist" 主题，随明暗）；不可高亮（未知语言/
/// 超长/解析失败）返回 null。
TextSpan? highlightCode(String code, String language,
    {Brightness brightness = Brightness.light}) {
  if (code.length > kHighlightMaxChars) return null;
  try {
    final result = _highlight.highlight(code: code, language: language, ignoreIllegals: true);
    if (result.errorRaised != null) return null;
    final renderer = TextSpanRenderer(
      AppMono.code,
      mistHighlightTheme(brightness),
    );
    result.render(renderer);
    return renderer.span;
  } on Object {
    // 高亮失败不应影响展示 —— 回退纯文本。
    return null;
  }
}

/// 代码块视图：代码井 + 语言标签 + 复制按钮 + 横向可滚代码体。
/// [streaming] 为 true 时高亮按 250ms 节流（流式三件套 ③）：冷却期内新增
/// 的尾部以纯等宽拼接在已高亮前缀之后，不逐帧重解析整块代码。
class CodeBlockView extends StatefulWidget {
  const CodeBlockView({
    super.key,
    required this.code,
    this.language = '',
    this.closed = true,
    this.highlight = true,
    this.streaming = false,
  });

  final String code;

  /// Markdown 围栏标注的原语言串（可能为空或任意别名）。
  final String language;

  /// 围栏是否闭合（流式期间为 false，照常展示）。
  final bool closed;

  /// 是否做语法高亮。
  final bool highlight;

  /// 流式期间节流高亮。
  final bool streaming;

  @override
  State<CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<CodeBlockView> {
  /// 高亮节流：缓存的已高亮前缀 span + 长度 + 上次高亮时刻。
  TextSpan? _cachedSpan;
  int _cachedLen = 0;
  int _lastHighlightMs = 0;

  static const _highlightEvery = Duration(milliseconds: 250);

  TextSpan? _highlightNow(String code, String? lang, Brightness brightness) {
    final span = highlightCode(code, lang!, brightness: brightness);
    if (span != null) {
      _cachedSpan = span;
      _cachedLen = code.length;
      _lastHighlightMs = DateTime.now().millisecondsSinceEpoch;
    } else {
      _cachedSpan = null;
      _cachedLen = 0;
    }
    return span;
  }

  @override
  Widget build(BuildContext context) {
    // mermaid 块：源码 + 全屏渲染入口（chat-streaming-rendering）。
    if (widget.language.trim().toLowerCase() == 'mermaid') {
      return MermaidPreview(code: widget.code);
    }
    final brightness = Theme.of(context).brightness;
    final lang = normalizeLanguage(widget.language);
    final TextSpan? span;
    if (widget.highlight && lang != null) {
      if (!widget.streaming) {
        // 完成：整块高亮（每次构建重解析一次，成本可接受）。
        span = _highlightNow(widget.code, lang, brightness);
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        final cooled =
            now - _lastHighlightMs >= _highlightEvery.inMilliseconds;
        if (_cachedSpan == null || cooled) {
          span = _highlightNow(widget.code, lang, brightness);
        } else if (widget.code.length >= _cachedLen) {
          // 冷却期：新增尾部纯等宽拼接（不重解析）。
          span = TextSpan(
            style: AppMono.code,
            children: [
              _cachedSpan!,
              TextSpan(text: widget.code.substring(_cachedLen)),
            ],
          );
        } else {
          // 代码变短（少见）：立即重高亮。
          span = _highlightNow(widget.code, lang, brightness);
        }
      }
    } else {
      span = null;
    }
    final (bg, header, border, _, comment, text) = CodeWell.of(brightness);
    final body = span == null
        ? Text(widget.code, style: AppMono.code)
        : Text.rich(span);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: ShapeDecoration(
        color: bg,
        shape: Squircle.border(
          context.tokens.shape.md,
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题条：高 max(36, 字高+8)，左语言名，右复制键。
          Container(
            height: 36,
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            decoration: BoxDecoration(
              color: header,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    lang ?? widget.language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppMono.label.copyWith(color: comment),
                  ),
                ),
                CopyIconButton(
                  text: widget.code,
                  tooltip: '复制代码',
                  color: comment,
                ),
              ],
            ),
          ),
          // 不换行时横向滚动 + 两端淡出；纵向到头让路给外层列表。
          OverscrollForwarder(
            child: HorizontalEdgeFade(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: text),
                  child: body,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
