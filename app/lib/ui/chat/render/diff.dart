/// 行级 diff（task 4.1）：经典 LCS 动态规划，输入是 Edit 工具的
/// old_string/new_string（规模小，端上计算）。纯 Dart。超出规模上限时
/// 退化为"全删 + 全增"，保证总是可渲染。
library;

enum DiffLineKind { same, add, remove }

class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffLineKind kind;
  final String text;
}

/// 超过该行数不做 LCS（退化渲染），避免大编辑在 UI 线程上做百万级
/// 单元的 DP。手机上超过几百行的 diff 本就读不完。
const kDiffMaxLines = 500;

/// 计算行级 diff：公共行保留（same），旧文件独有 remove，新文件独有 add。
List<DiffLine> diffLines(List<String> oldLines, List<String> newLines) {
  if (oldLines.isEmpty) {
    return [for (final line in newLines) DiffLine(DiffLineKind.add, line)];
  }
  if (newLines.isEmpty) {
    return [for (final line in oldLines) DiffLine(DiffLineKind.remove, line)];
  }
  if (oldLines.length > kDiffMaxLines || newLines.length > kDiffMaxLines) {
    return [
      for (final line in oldLines) DiffLine(DiffLineKind.remove, line),
      for (final line in newLines) DiffLine(DiffLineKind.add, line),
    ];
  }

  final n = oldLines.length;
  final m = newLines.length;
  // lcs[i][j]：oldLines[i..] 与 newLines[j..] 的最长公共子序列长度。
  final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = oldLines[i] == newLines[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final result = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      result.add(DiffLine(DiffLineKind.same, oldLines[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      result.add(DiffLine(DiffLineKind.remove, oldLines[i]));
      i++;
    } else {
      result.add(DiffLine(DiffLineKind.add, newLines[j]));
      j++;
    }
  }
  while (i < n) {
    result.add(DiffLine(DiffLineKind.remove, oldLines[i]));
    i++;
  }
  while (j < m) {
    result.add(DiffLine(DiffLineKind.add, newLines[j]));
    j++;
  }
  return result;
}
