/// 视觉 token 层测试：OKLCH 转换已知值、明暗 token 完备性、动效档位
/// 约束，以及"token 层不依赖 UI 屏幕"的源码扫描守卫（chat-visual-system
/// requirement: 主题 token 层）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/theme/oklch.dart';
import 'package:cc_go/theme/tokens.dart';

void main() {
  group('oklch 转换', () {
    test('极端值：黑与白', () {
      expect(oklch(0, 0, 0), const Color(0xFF000000));
      expect(oklch(1, 0, 0), const Color(0xFFFFFFFF));
    });

    test('中性灰：oklch(0.5 0 0) ≈ #636363', () {
      // L=0.5 → 线性 0.125 → gamma 0.388 → 99 (0x63)。
      expect(oklch(0.5, 0, 0).toARGB32(), const Color(0xFF636363).toARGB32());
    });

    test('超出色域时 clamp 不抛错、不产生负 alpha 通道', () {
      final c = oklch(0.95, 0.4, 30); // 高明度高彩度暖色必出 gamut
      expect(c.a, 1.0);
      expect(c.r, greaterThanOrEqualTo(0));
      expect(c.r, lessThanOrEqualTo(255));
    });

    test('同色相换明度：明度单调', () {
      final l1 = oklch(0.4, 0.09, 255);
      final l2 = oklch(0.6, 0.09, 255);
      // 雾蓝系：明度更高的取值整体更亮（蓝通道为主）。
      expect(l2.b, greaterThan(l1.b));
    });
  });

  group('CcTokens', () {
    test('明暗两套均带三级玻璃/动效/形状', () {
      for (final theme in [CcTheme.light(), CcTheme.dark()]) {
        final tokens = theme.extension<CcTokens>();
        expect(tokens, isNotNull);
        expect(tokens!.glassChrome.blur, greaterThan(0));
        expect(tokens.glassSheet.blur, greaterThan(0));
        expect(tokens.glassCard.blur, 0); // card 近似：不挂 BackdropFilter
      }
    });

    test('三级玻璃规格互异', () {
      final tokens = CcTheme.light().extension<CcTokens>()!;
      expect(tokens.glassChrome.blur, isNot(tokens.glassSheet.blur));
      expect(tokens.glassChrome.fill, isNot(tokens.glassCard.fill));
    });

    test('动效三档满足纪律：反馈 < 结构 < 环境', () {
      final m = CcTheme.dark().extension<CcTokens>()!.motion;
      expect(m.fast.inMilliseconds, lessThanOrEqualTo(160));
      expect(m.structure.inMilliseconds, inInclusiveRange(240, 340));
      expect(m.ambient.inMilliseconds, greaterThanOrEqualTo(2000));
    });

    test('lerp 在明暗两套间不丢 token', () {
      final a = CcTheme.light().extension<CcTokens>()!;
      final b = CcTheme.dark().extension<CcTokens>()!;
      final mid = a.lerp(b, 0.5);
      expect(mid.motion.fast, a.motion.fast); // 两套动效同值
      expect(identical(mid.glassChrome, b.glassChrome), isTrue); // t≥0.5 取 b
    });
  });

  group('token 层依赖守卫', () {
    test('lib/theme/ 不 import 任何 UI 屏（headless 纯净）', () {
      final dir = Directory('lib/theme');
      expect(dir.existsSync(), isTrue, reason: 'lib/theme/ 应存在');
      final offenders = <String>[];
      for (final f in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        for (final line in src.split('\n')) {
          final t = line.trim();
          if (t.startsWith('import ') &&
              (t.contains('ui/chat') || t.contains('../ui/') || t.contains('/ui/'))) {
            offenders.add('${f.path}: $t');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
