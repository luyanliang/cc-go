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
import 'package:re_highlight/styles/github-dark.dart';

import 'copy_button.dart';

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

/// 计算代码块的高亮 span；不可高亮（未知语言/超长/解析失败）返回 null。
TextSpan? highlightCode(String code, String language) {
  if (code.length > kHighlightMaxChars) return null;
  try {
    final result = _highlight.highlight(code: code, language: language, ignoreIllegals: true);
    if (result.errorRaised != null) return null;
    final renderer = TextSpanRenderer(
      const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.45),
      githubDarkTheme,
    );
    result.render(renderer);
    return renderer.span;
  } on Object {
    // 高亮失败不应影响展示 —— 回退纯文本。
    return null;
  }
}

/// 代码块视图：深色底 + 语言标签 + 复制按钮 + 横向可滚代码体。
class CodeBlockView extends StatelessWidget {
  const CodeBlockView({
    super.key,
    required this.code,
    this.language = '',
    this.closed = true,
    this.highlight = true,
  });

  final String code;

  /// Markdown 围栏标注的原语言串（可能为空或任意别名）。
  final String language;

  /// 围栏是否闭合（流式期间为 false，照常展示）。
  final bool closed;

  /// 是否做语法高亮。流式期间应为 false：每帧重解析长代码会卡顿，
  /// 先纯等宽展示，条目完成后整体替换时再高亮。
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final lang = normalizeLanguage(language);
    final span = highlight && lang != null ? highlightCode(code, lang) : null;
    final body = span == null
        ? Text(
            code,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.45),
          )
        : Text.rich(span);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    lang ?? language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
                  ),
                ),
                CopyIconButton(
                  text: code,
                  tooltip: '复制代码',
                  color: const Color(0xFF8B949E),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Color(0xFFC9D1D9)),
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}
