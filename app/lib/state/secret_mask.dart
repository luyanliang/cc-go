/// 用户消息中的疑似凭据屏显遮罩（chat-message-interactions）：单遍扫描，
/// 产出遮罩区间 —— 只影响显示（渲染层画 chip），复制/引用/编辑/发送
/// 均为原文。宁多勿漏：命中规则放宽，误报可逐段点开查看。
/// 纯函数，无 Flutter 依赖。
library;

/// 一段遮罩：原文 [text] 在消息中的 [start..end)。
class MaskedSecret {
  const MaskedSecret({required this.start, required this.end, required this.text});

  final int start;
  final int end;
  final String text;

  /// 展示摘要（chip 文案）：只露类别 + 尾 4 位。
  String get label {
    final tail = text.length > 4 ? text.substring(text.length - 4) : text;
    return '$kind…$tail';
  }

  String get kind {
    if (text.startsWith('sk-')) return 'API key';
    if (text.contains('PRIVATE KEY')) return '私钥';
    if (text.contains('://')) return 'URL 凭据';
    if (RegExp(r'^[A-Za-z0-9_\-]{8,}$').hasMatch(text)) return '令牌';
    return '疑似凭据';
  }
}

// 各规则共用：凭据字符集（URL 凭据除外）。
final _tokenChars = RegExp(r'^[A-Za-z0-9_\-\.]{8,}$');

/// 扫描 [text]，返回互不重叠、按起点排序的遮罩区间。
List<MaskedSecret> scanSecrets(String text) {
  final hits = <MaskedSecret>[];

  void add(int start, int end) {
    if (end <= start) return;
    // 与已命中区间重叠时丢弃后者（保持顺序）。
    for (final h in hits) {
      if (start < h.end && end > h.start) return;
    }
    hits.add(MaskedSecret(start: start, end: end, text: text.substring(start, end)));
  }

  // 1. API key 形态：sk- 前缀 + ≥16 个凭据字符（OpenAI/Anthropic 风格）。
  final sk = RegExp(r'sk-[A-Za-z0-9_\-]{16,}');
  for (final m in sk.allMatches(text)) {
    add(m.start, m.end);
  }

  // 2. PEM 私钥块头尾行。
  final pem = RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----');
  for (final m in pem.allMatches(text)) {
    add(m.start, m.end);
  }

  // 3. URL 内嵌凭据：scheme://user:password@…
  final urlCred = RegExp(RegExp.escape('://') + r'[^\s/@]+:[^\s/@]+@');
  for (final m in urlCred.allMatches(text)) {
    add(m.start, m.end);
  }

  // 4. Bearer 令牌：Bearer <token>。
  final bearer = RegExp('[Bb]earer [A-Za-z0-9_\\-\\.]{16,}');
  for (final m in bearer.allMatches(text)) {
    add(m.start, m.end);
  }

  // 5. 长十六进制/随机串（≥32 位凭据字符，可能是裸 key）。
  final hexish = RegExp(r'\b[A-Za-z0-9_\-]{32,}\b');
  for (final m in hexish.allMatches(text)) {
    final v = m.group(0)!;
    if (_tokenChars.hasMatch(v)) add(m.start, m.end);
  }

  hits.sort((a, b) => a.start - b.start);
  return hits;
}
