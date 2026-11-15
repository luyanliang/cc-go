/// 共享视觉件测试：玻璃胶囊/卡片（读 token、形状正确）、胶囊 chip、
/// 状态点、工具图形映射（chat-visual-system requirement: 共享视觉件）。
library;

import 'package:cc_go/theme/tokens.dart';
import 'package:cc_go/ui/theme/app_style.dart';
import 'package:cc_go/ui/widgets/glass.dart';
import 'package:cc_go/ui/widgets/pill_badge.dart';
import 'package:cc_go/ui/widgets/status_dot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: brightness == Brightness.light ? CcTheme.light() : CcTheme.dark(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('GlassPill / GlassCard', () {
    testWidgets('胶囊：真模糊 chrome 规格 + Stadium 全圆角', (tester) async {
      await tester.pumpWidget(_host(const GlassPill(child: Text('x'))));
      final context = tester.element(find.text('x'));
      final spec = context.tokens.glassChrome;
      // DecoratedBox 的形状 = 全圆角。
      final deco = tester
          .widget<DecoratedBox>(find.byType(DecoratedBox).first)
          .decoration as ShapeDecoration;
      expect(deco.shape, isA<StadiumBorder>()); // Stadium：全圆角胶囊
      expect(deco.color, spec.fill);
      // chrome 有 blur → 存在 BackdropFilter。
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('卡片：连续曲率（RoundedSuperellipseBorder）+ 无模糊',
        (tester) async {
      await tester.pumpWidget(_host(const GlassCard(child: Text('x'))));
      final context = tester.element(find.text('x'));
      final tokens = context.tokens;
      final deco = tester
          .widget<DecoratedBox>(find.byType(DecoratedBox).first)
          .decoration as ShapeDecoration;
      expect(deco.shape, isA<RoundedSuperellipseBorder>());
      expect(deco.color, tokens.glassCard.fill);
      expect(find.byType(BackdropFilter), findsNothing); // card 近似玻璃
    });

    testWidgets('暗色主题下取暗色 token', (tester) async {
      await tester.pumpWidget(_host(const GlassPill(child: Text('x')),
          brightness: Brightness.dark));
      final context = tester.element(find.text('x'));
      final deco = tester
          .widget<DecoratedBox>(find.byType(DecoratedBox).first)
          .decoration as ShapeDecoration;
      expect(deco.color, context.tokens.glassChrome.fill);
      expect(context.tokens.glassChrome.fill,
          isNot(CcTheme.light().extension<CcTokens>()!.glassChrome.fill));
    });
  });

  group('PillBadge.capsule', () {
    testWidgets('胶囊变体：全圆角、语义色底', (tester) async {
      await tester.pumpWidget(_host(PillBadge.capsule('模型',
          color: Colors.blue, onColor: Colors.white)));
      final deco = tester
          .widget<Container>(find.byType(Container))
          .decoration! as BoxDecoration;
      expect(deco.color, Colors.blue);
      expect(deco.borderRadius, BorderRadius.circular(999));
    });
  });

  group('StatusDot', () {
    testWidgets('语义色着色', (tester) async {
      await tester.pumpWidget(_host(const StatusDot(AppStatus.waiting)));
      final dot = tester.widget<Container>(find.byType(Container));
      expect((dot.decoration! as BoxDecoration).color, AppColors.waiting);
    });
  });

  group('AppToolGlyph', () {
    test('同类工具同字形', () {
      expect(AppToolGlyph.forTool('Bash'), AppToolGlyph.forTool('bash'));
      expect(AppToolGlyph.forTool('Edit'), AppToolGlyph.forTool('Write'));
      expect(AppToolGlyph.forTool('Grep'), AppToolGlyph.forTool('Glob'));
    });
    test('未知工具回退通用字形', () {
      expect(AppToolGlyph.forTool('WebFetch'),
          AppToolGlyph.forTool('SomeUnknownTool'));
    });
  });
}
