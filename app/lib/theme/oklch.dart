/// OKLCH → sRGB [Color] 转换（Björn Ottosson 的 OKLab 线性矩阵，逆变换
/// 到线性 sRGB 后做 gamma 编码，超出色域按亮度 clamp）。
///
/// 调色板用 OKLCH 推导的目的："换色相、留明度"——同一 L 下不同强调色的
/// 感知明度一致，对比度天然同档（palette.dart 各值都注明 oklch 源坐标）。
/// 只依赖 dart:math，headless 可测。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// `oklch(L C H°)` → sRGB。L/C 截到 [0,1]，H 按度数取三角。
Color oklch(double l, double c, double hDeg) {
  final h = hDeg * math.pi / 180.0;
  final a = c * math.cos(h);
  final b = c * math.sin(h);

  // OKLab → LMS'（非线性）。
  final lp = l + 0.3963377774 * a + 0.2158037573 * b;
  final mp = l - 0.1055613458 * a - 0.0638541728 * b;
  final sp = l - 0.0894841775 * a - 1.2914855480 * b;

  // LMS' → LMS（立方）→ 线性 sRGB。
  final lc = lp * lp * lp;
  final mc = mp * mp * mp;
  final sc = sp * sp * sp;
  var r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc;
  var g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc;
  var bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc;

  // 色域外：等比例缩回（保色相的近似降法，调色板用途足够）。
  final max = math.max(r, math.max(g, bl));
  if (max > 1.0) {
    r /= max;
    g /= max;
    bl /= max;
  }

  int enc(double v) {
    final x = v.clamp(0.0, 1.0);
    final s = x <= 0.0031308 ? 12.92 * x : 1.055 * math.pow(x, 1 / 2.4) - 0.055;
    return (s * 255.0).round().clamp(0, 255);
  }

  return Color.fromARGB(255, enc(r), enc(g), enc(bl));
}
