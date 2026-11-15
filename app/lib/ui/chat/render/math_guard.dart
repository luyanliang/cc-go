/// LaTeX 判定守卫（chat-streaming-rendering）：gpt_markdown 自带
/// `$…$` / `$$…$$` 渲染，但价格语境（"$5 和 $10"）会被误判成公式。
/// 本层按 remark-math 通行约定做保守判定：疑似非公式的 `$` 在渲染前
/// 转义（`\$`），公式原样放行。纯函数，幂等。
library;

/// CJK 与常见中文标点（内容含中文的 `$` 对几乎不可能是公式）。
final _cjk = RegExp(r'[一-鿿　-〿＀-￯]');

/// 单个 `$…$` 对的内容是否"看起来像公式"。
bool isLikelyInlineMath(String content) {
  if (content.isEmpty) return false;
  // remark-math：内联公式内容不能以空白开头/结尾。
  if (content.startsWith(' ') || content.endsWith(' ')) return false;
  // 含 CJK → 价格/普通文本。
  if (_cjk.hasMatch(content)) return false;
  // 纯货币数字（$5、$10.00 形态的内容）→ 非公式。
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(content)) return false;
  // 其余（字母/符号混合、LaTeX 命令）→ 放行当公式。
  return true;
}

/// 渲染前处理：把疑似非公式的行内 `$` 转义为 `\$`；展示公式 `$$…$$`
/// 原样放行（未闭合的展示公式由调用方在流式期间扣住，见
/// [closeDanglingDisplayMath]）。幂等 —— 已转义的 `\$` 不再处理。
String guardMathDelimiters(String text) {
  if (!text.contains(r'$')) return text;
  final sb = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    // 已转义的 $ 原样带过。
    if (ch == '\\' && i + 1 < text.length && text[i + 1] == r'$') {
      sb.write(text.substring(i, i + 2));
      i += 2;
      continue;
    }
    // 展示公式块：成对放行（配对扫描）。
    if (ch == r'$' && i + 1 < text.length && text[i + 1] == r'$') {
      final end = text.indexOf(r'$$', i + 2);
      if (end > 0) {
        sb.write(text.substring(i, end + 2));
        i = end + 2;
        continue;
      }
    }
    if (ch == r'$') {
      // 行内公式对：找下一个未转义 $。
      var j = i + 1;
      while (j < text.length) {
        if (text[j] == '\\') {
          j += 2;
          continue;
        }
        if (text[j] == r'$') break;
        j++;
      }
      final content = j < text.length ? text.substring(i + 1, j) : null;
      if (content != null && isLikelyInlineMath(content)) {
        sb.write(text.substring(i, j + 1)); // 公式：整对原样放行
        i = j + 1;
        continue;
      }
      // 非公式（价格/孤立 $）：转义。
      sb.write(r'\$');
      i++;
      continue;
    }
    sb.write(ch);
    i++;
  }
  return sb.toString();
}

/// 流式期间未闭合的展示公式 `$$` → 以占位围栏扣住（避免半截解析
/// 撕裂版面），闭合后恢复原样。幂等。
String closeDanglingDisplayMath(String text) {
  final pattern = RegExp(r'\$\$');
  final count = pattern.allMatches(text).length;
  if (count % 2 == 0) return text;
  return '$text\n\$\$';
}
