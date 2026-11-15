/// 流式渲染测试（chat-streaming-rendering）：pacer 匀速与完成对齐、
/// 修复扩展（粗体/链接）、公式判定守卫、流式光标、mermaid 源码视图。
library;

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';
import 'package:cc_go/ui/chat/render/math_guard.dart';
import 'package:cc_go/ui/chat/render/stream_pacer.dart';
import 'package:cc_go/ui/chat/render/stream_repair.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/ui/widgets/streaming_cursor.dart';
import 'package:material_ui/material_ui.dart';

TranscriptItem _assistant(String id, String text, {String status = 'done'}) =>
    TranscriptItem(
      id: id,
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: status,
      text: text,
    );

void main() {
  group('StreamPacer', () {
    test('匀速吐出：大块增量不闪现', () {
      final pacer = StreamPacer();
      pacer.setTotal(1200);
      // 第 100ms：应只吐出一部分（600cps×2×0.1s = 120 字）。
      expect(pacer.tick(100), lessThan(300));
      // 第 2000ms：全部放完。
      expect(pacer.tick(2000), 1200);
    });

    test('积压上限：超长文本有限时间放行', () {
      final pacer = StreamPacer(maxBacklogChars: 300);
      pacer.setTotal(10000);
      // 首帧：放行量至少 total - maxBacklog（floor）。
      expect(pacer.tick(100), greaterThanOrEqualTo(10000 - 300));
      // 之后按速率续流，有限时间放完。
      expect(pacer.tick(5000), 10000);
    });

    test('完成全量放行，与最终全文对齐', () {
      final pacer = StreamPacer();
      pacer.setTotal(500);
      expect(pacer.tick(10), lessThan(500));
      expect(pacer.releaseAll(), 500);
    });

    test('setTotal 只增不减（增量语义）', () {
      final pacer = StreamPacer();
      pacer.setTotal(100);
      pacer.setTotal(50);
      expect(pacer.total, 100);
    });
  });

  group('残缺修复扩展', () {
    test('未闭合粗体补闭合，幂等', () {
      final repaired = repairStreamingMarkdown('这是 **加粗文本');
      expect(repaired.endsWith('**'), isTrue);
      expect(repairStreamingMarkdown(repaired), repaired); // 幂等
    });

    test('成对粗体不追加', () {
      expect(repairStreamingMarkdown('**好的** 完整'), '**好的** 完整');
    });

    test('半截链接补右括号', () {
      final repaired = repairStreamingMarkdown('看 [文档](https://e');
      expect(repaired.endsWith(')'), isTrue);
      expect(repairStreamingMarkdown(repaired), repaired);
    });

    test('链接完整不追加', () {
      expect(
          repairStreamingMarkdown('看 [文档](https://example.com) 了'),
          '看 [文档](https://example.com) 了');
    });

    test('代码围栏内的 ** 不参与计数', () {
      final text = '正文\n```\n**inside**\n```';
      expect(repairStreamingMarkdown(text), text);
    });
  });

  group('LaTeX 判定守卫', () {
    test('公式放行', () {
      expect(guardMathDelimiters(r'质能方程 $E=mc^2$ 很有名'),
          r'质能方程 $E=mc^2$ 很有名');
      expect(guardMathDelimiters(r'展示公式 $$\int_a^b f(x)dx$$ 结束'),
          r'展示公式 $$\int_a^b f(x)dx$$ 结束');
    });

    test('价格转义不误判', () {
      final guarded = guardMathDelimiters('套餐价格 \$5 和 \$10');
      // "5 和 " 不像公式 → 首个 $ 被转义。
      expect(guarded, contains(r'\$'));
      expect(guarded, isNot(contains(r'$$')));
    });

    test('幂等：已转义不再处理', () {
      final once = guardMathDelimiters('价格 \$5');
      expect(guardMathDelimiters(once), once);
    });

    test('未闭合展示公式补占位闭合', () {
      final closed = closeDanglingDisplayMath('公式开头 \$\$\\int');
      expect(closed.endsWith(r'$$'), isTrue);
      // 已闭合不追加。
      expect(closeDanglingDisplayMath('\$\$x\$\$ 之后'), '\$\$x\$\$ 之后');
    });
  });

  group('流式渲染 widget', () {
    testWidgets('流式期间正文末尾有光标，完成后消失', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            items: [_assistant('a1', '输出完成的内容')],
            queuedTexts: const [],
            loaded: true,
            scrollController: controller,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(StreamingCursor), findsNothing);

      final streaming = [
        _assistant('a2', '正在输出的内容', status: 'streaming'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            items: streaming,
            queuedTexts: const [],
            loaded: true,
            scrollController: controller,
          ),
        ),
      ));
      // pacer 吐字期间正文带光标（等 catch-up 完成）。
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(StreamingCursor), findsOneWidget);
    });

    testWidgets('嵌套列表：子列表 marker 与父级文字列对齐（chat-streaming-rendering）',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TranscriptListView(
          items: [
            _assistant(
              'a1',
              '1. 第一项\n   1. 子项甲\n   2. 子项乙\n2. 第二项',
            ),
          ],
          queuedTexts: const [],
          loaded: true,
          scrollController: controller,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final parentMarker = find.text('1.').first;
    final childText = find.text('子项甲');
    expect(childText.evaluate(), isNotEmpty);
    // 子列表文字列起点 = 父 marker 列右缘 + 间距（子项比父 marker 至少
    // 缩进一个 gutter 宽度）。
    expect(
      tester.getRect(childText).left,
      greaterThan(tester.getRect(parentMarker).left + 20),
    );
    // 编号列随位数加宽：两位数编号的 marker 列不与文字挤压（有 gutter）。
    expect(find.text('2.'), findsNWidgets(2));
  });

  testWidgets('mermaid 块显示源码视图与渲染入口', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            items: [
              _assistant('a1', '看看：\n\n```mermaid\ngraph TD; A-->B;\n```'),
            ],
            queuedTexts: const [],
            loaded: true,
            scrollController: controller,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('mermaid'), findsWidgets);
      expect(find.text('渲染'), findsOneWidget);
      // 源码可见（不自动渲染 WebView）。
      expect(find.textContaining('graph TD'), findsOneWidget);
    });
  });
}
