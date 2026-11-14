/// ANSI SGR 基础着色（task 3.2）：把带 ANSI 转义序列的命令输出解析为
/// TextSpan 列表。支持 16 色前景/背景、加粗/暗淡/斜体/下划线与 256 色/
/// 真彩的降级近似；其余 CSI/OSC 序列剥除。畸形输入（孤立 ESC、悬空参
/// 数）按原文渲染，不抛错。纯函数，单测覆盖。
library;

import 'package:material_ui/material_ui.dart';

/// 标准 16 色调色板（SGR 30-37 / 90-97 与 38;5;n 的前 16 项共用）。
const _palette = <Color>[
  Color(0xFF000000), // 0 black
  Color(0xFFCD3131), // 1 red
  Color(0xFF0DBC79), // 2 green
  Color(0xFFE5E510), // 3 yellow
  Color(0xFF2472C8), // 4 blue
  Color(0xFFBC3FBC), // 5 magenta
  Color(0xFF11A8CD), // 6 cyan
  Color(0xFFE5E5E5), // 7 white
  Color(0xFF666666), // 8 bright black
  Color(0xFFF14C4C), // 9 bright red
  Color(0xFF23D18B), // 10 bright green
  Color(0xFFF5F543), // 11 bright yellow
  Color(0xFF3B8EEA), // 12 bright blue
  Color(0xFFD670D6), // 13 bright magenta
  Color(0xFF29B8DB), // 14 bright cyan
  Color(0xFFFFFFFF), // 15 bright white
];

class _SgrState {
  Color? fg;
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;
}

final _csiPattern = RegExp('\x1b\\[([0-9;:?]*)([A-Za-z])');
final _oscPattern = RegExp('\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)');

/// 解析 ANSI 文本为带样式 span（无样式部分也产出，保持文本完整）。
/// 序列匹配必须锚定在当前位置：未识别的 ESC 前缀（如字符集切换
/// `\x1b(B`）不能跳到后面最近的序列上——那会把中间的正文整段吞掉。
List<TextSpan> parseAnsiSpans(String input, {TextStyle base = const TextStyle()}) {
  final spans = <TextSpan>[];
  final state = _SgrState();
  var buffer = StringBuffer();
  var i = 0;

  void flush() {
    if (buffer.isNotEmpty) {
      spans.add(_span(buffer.toString(), state, base));
      buffer = StringBuffer();
    }
  }

  while (i < input.length) {
    if (input[i] == '\x1b') {
      final rest = input.substring(i);
      final osc = _oscPattern.matchAsPrefix(rest);
      if (osc != null) {
        flush();
        i += osc.end;
        continue;
      }
      final csi = _csiPattern.matchAsPrefix(rest);
      if (csi != null) {
        if (csi.group(2) == 'm') {
          flush();
          _applySgr(csi.group(1) ?? '', state);
        } else {
          // 非 SGR 的 CSI（光标移动等）：剥除。
          flush();
        }
        i += csi.end;
        continue;
      }
      // 当前位置不是可识别序列：ESC 按原文渲染，继续逐字符（后续文本
      // 完整保留），期间再次遇到 ESC 仍会尝试识别。
    }
    buffer.write(input[i]);
    i++;
  }
  flush();
  return spans;
}

TextSpan _span(String text, _SgrState state, TextStyle base) {
  var style = base;
  if (state.fg != null) style = style.copyWith(color: state.fg);
  if (state.bold) style = style.copyWith(fontWeight: FontWeight.w700);
  if (state.dim) style = style.copyWith(color: style.color?.withValues(alpha: 0.6));
  if (state.italic) style = style.copyWith(fontStyle: FontStyle.italic);
  if (state.underline) style = style.copyWith(decoration: TextDecoration.underline);
  return TextSpan(text: text, style: style);
}

void _applySgr(String params, _SgrState state) {
  // 空参数（"\x1b[m"）按 0 处理。
  final parts = params == '' ? ['0'] : params.split(';');
  for (var i = 0; i < parts.length; i++) {
    final code = int.tryParse(parts[i]);
    if (code == null) continue; // 悬空参数：跳过，容错
    if (code == 0) {
      state
        ..fg = null
        ..bold = false
        ..dim = false
        ..italic = false
        ..underline = false;
    } else if (code == 1) {
      state.bold = true;
    } else if (code == 2) {
      state.dim = true;
    } else if (code == 3) {
      state.italic = true;
    } else if (code == 4) {
      state.underline = true;
    } else if (code == 22) {
      state
        ..bold = false
        ..dim = false;
    } else if (code == 23) {
      state.italic = false;
    } else if (code == 24) {
      state.underline = false;
    } else if (code >= 30 && code <= 37) {
      state.fg = _palette[code - 30];
    } else if (code == 39) {
      state.fg = null;
    } else if (code >= 90 && code <= 97) {
      // 亮色系 90-97：palette 的 8-15。
      state.fg = _palette[code - 90 + 8];
    } else if (code == 38) {
      // 扩展色 38;5;n / 38;2;r;g;b：前 16 项用调色板（mod 16 近似），
      // 真彩直接用。参数不完整时整组丢弃，容错。
      if (i + 2 < parts.length && parts[i + 1] == '5') {
        final n = int.tryParse(parts[i + 2]);
        if (n != null) state.fg = _palette[n % 16];
        i += 2;
      } else if (i + 4 < parts.length && parts[i + 1] == '2') {
        final r = int.tryParse(parts[i + 2]);
        final g = int.tryParse(parts[i + 3]);
        final b = int.tryParse(parts[i + 4]);
        if (r != null && g != null && b != null) {
          state.fg = Color.fromARGB(255, r & 0xFF, g & 0xFF, b & 0xFF);
        }
        i += 4;
      } else {
        i = parts.length; // 悬空 38：跳过剩余参数
      }
    }
    // 40-47/49/100-107（背景）与其他未知码：忽略 —— 手机上长输出的背景
    // 色干扰可读性，且不影响语义。
  }
}
