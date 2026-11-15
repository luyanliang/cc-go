/// 流式残缺 Markdown 补全（task 2.1）：流式期间条目文本可能停在任意字节，
/// 未闭合的代码围栏 / 截断的表格行会让渲染布局撕裂。本函数在渲染前做
/// 轻量补全：补上闭合围栏、补齐表格尾行的竖线；条目完成后不走本函数，
/// 直接以原始全文整体替换。
///
/// 性质：幂等 —— 对已补全的文本再跑一次结果不变。
library;

/// 补全流式残缺的 Markdown 文本。
String repairStreamingMarkdown(String text) {
  var repaired = _repairTableTail(_closeOpenCodeFence(text));
  repaired = _closeUnclosedEmphasis(repaired);
  repaired = _closeUnclosedLink(repaired);
  return repaired;
}

/// 在围栏外扫描 `**` 记号：奇数个未闭合 → 追加闭合符。
/// 逐行单遍（O(全文长度)）：`_fencePattern` 的 `$` 在非 multiline 下
/// 只匹配串尾，此前对"每个行首做 substring+正则"的写法永远检不出中
/// 部围栏，还会把代码块里的 `**` 计入——两案一并修。
/// 幂等：闭合后记号成对，再跑不追加。
String _closeUnclosedEmphasis(String text) {
  final lines = text.split('\n');
  var inFence = false;
  String? fence;
  var count = 0;
  for (final line in lines) {
    final m = _fencePattern.firstMatch(line);
    if (m != null) {
      final f = m.group(1)!;
      final info = m.group(2) ?? '';
      // 开栏：反引号围栏的信息串里不允许再出现反引号（GFM）。
      final opens = f.contains('`') ? !info.contains('`') : true;
      if (opens) {
        if (!inFence) {
          inFence = true;
          fence = f;
        } else if (f[0] == fence![0] && f.length >= fence.length) {
          inFence = false;
          fence = null;
        }
        continue;
      }
    }
    if (inFence) continue;
    // 数本行的 ** 记号（跳过转义对）。
    var i = 0;
    while (i < line.length) {
      if (line[i] == '\\') {
        i += 2;
        continue;
      }
      if (line[i] == '*' && i + 1 < line.length && line[i + 1] == '*') {
        count++;
        i += 2;
        continue;
      }
      i++;
    }
  }
  if (count % 2 == 0) return text;
  // 奇数个 ** 记号：闭合粗体。
  return '$text**';
}

/// 半截链接/图片 `[text](url` → 补右括号；`[text`（无 `](`）不猜。
String _closeUnclosedLink(String text) {
  if (text.isEmpty) return text;
  // 从尾部找未闭合的 `[...](...`：最后一个 [ 之后有 ]( 却没有 )。
  final openBracket = text.lastIndexOf('[');
  if (openBracket < 0) return text;
  // 图片 `![alt](…` 的头截断更复杂，不猜（`[` 前一个字符是 `!`）。
  if (openBracket > 0 && text[openBracket - 1] == '!') return text;
  final after = text.substring(openBracket);
  final parenIdx = after.indexOf('](');
  if (parenIdx < 0) return text; // 还在 alt 文本里，等下文
  final rest = after.substring(parenIdx + 2);
  if (rest.contains(')')) return text;
  return '$text)';
}

/// 围栏行：行首至多 3 个空格 + 3 个及以上 ` 或 ~。
final _fencePattern = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// 未闭合代码围栏 → 追加与开栏同字符、至少同长度的闭合行。
String _closeOpenCodeFence(String text) {
  if (text.isEmpty) return text;
  final lines = text.split('\n');
  String? openFence;
  for (final line in lines) {
    final match = _fencePattern.firstMatch(line);
    if (match == null) continue;
    final fence = match.group(1)!;
    if (openFence == null) {
      // 开栏：反引号围栏的信息串里不允许再出现反引号（GFM）。
      final info = match.group(2) ?? '';
      if (fence.contains('`') && info.contains('`')) continue;
      openFence = fence;
    } else if (fence[0] == openFence[0] && fence.length >= openFence.length) {
      openFence = null;
    }
  }
  if (openFence == null) return text;
  // 末行若非空先补换行，再补闭合围栏。
  final endsWithNewline = text.endsWith('\n');
  return '$text${endsWithNewline ? '' : '\n'}$openFence';
}

/// 分隔行单元格：`---`、`:--`、`--:`、`:-:`（允许空白）。
final _delimiterCell = RegExp(r'^:?-+:?$');

/// 是否为 GFM 表格分隔行。
bool _isDelimiterRow(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && s.isNotEmpty) s = s.substring(0, s.length - 1);
  final cells = s.split('|').map((c) => c.trim());
  if (cells.isEmpty) return false;
  return cells.every((c) => c.isNotEmpty && _delimiterCell.hasMatch(c));
}

/// 未转义竖线的个数。
int _pipeCount(String line) {
  var count = 0;
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '|') {
      count++;
    } else if (line[i] == '\\' && i + 1 < line.length && line[i + 1] == '|') {
      i++;
    }
  }
  return count;
}

/// 截断的表格尾行 → 补齐到与表头相同的竖线数（缺的单元格补成空单元格，
/// 渲染布局稳定）。只修最后一个非空白行，且只修以 `|` 开头的行；否则
/// 宁可不动，也不猜。
String _repairTableTail(String text) {
  if (text.isEmpty) return text;
  final lines = text.split('\n');
  // 找最后一个非纯空白行。
  var last = lines.length - 1;
  while (last >= 0 && lines[last].trim().isEmpty) {
    last--;
  }
  if (last < 2) return text; // 至少表头 + 分隔行 + 数据行。
  if (!_isDelimiterRow(lines[last - 1])) return text;
  final header = lines[last - 2];
  final row = lines[last];
  if (!row.trimLeft().startsWith('|') || row.contains('\\|')) return text;
  final deficit = _pipeCount(header) - _pipeCount(row);
  if (deficit <= 0) return text;
  lines[last] = '$row${' |' * deficit}';
  return lines.join('\n');
}
