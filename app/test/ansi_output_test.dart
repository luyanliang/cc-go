/// task 3.2：ANSI SGR 解析单测（颜色/加粗/复位/畸形容错）与 Bash 完整
/// 输出视图 widget 测试（多行、截断标记、旧数据回退摘要）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';
import 'package:cc_go/ui/chat/output_page.dart';
import 'package:cc_go/ui/chat/render/ansi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseAnsiSpans', () {
    test('纯文本单 span 无样式', () {
      final spans = parseAnsiSpans('hello');
      expect(spans.single.text, 'hello');
      expect(spans.single.style?.color, isNull);
    });

    test('基础前景色与复位', () {
      final spans = parseAnsiSpans('a\x1b[31mred\x1b[0mplain');
      expect(spans, hasLength(3));
      expect(spans[0].text, 'a');
      expect(spans[1].text, 'red');
      expect(spans[1].style?.color, const Color(0xFFCD3131));
      expect(spans[2].text, 'plain');
      expect(spans[2].style?.color, isNull, reason: '复位后回到默认');
    });

    test('加粗与亮色', () {
      final spans = parseAnsiSpans('\x1b[1;92mbold-green');
      expect(spans.single.style?.fontWeight, FontWeight.w700);
      expect(spans.single.style?.color, const Color(0xFF23D18B));
    });

    test('256 色近似与真彩', () {
      final a = parseAnsiSpans('\x1b[38;5;200mx');
      expect(a.single.style?.color, isNotNull);
      final b = parseAnsiSpans('\x1b[38;2;10;20;30mx');
      expect(b.single.style?.color, const Color(0xFF0A141E));
    });

    test('非 SGR 序列剥除、OSC 剥除', () {
      expect(parseAnsiSpans('a\x1b[2Kbc').map((s) => s.text).join(), 'abc');
      expect(parseAnsiSpans('a\x1b]0;title\x07bc').map((s) => s.text).join(), 'abc');
    });

    test('畸形输入容错：孤立 ESC 按原文', () {
      final spans = parseAnsiSpans('a\x1bb');
      expect(spans.map((s) => s.text).join(), 'a\x1bb');
      // 悬空参数不抛错。
      expect(() => parseAnsiSpans('\x1b[38m'), returnsNormally);
      expect(() => parseAnsiSpans('\x1b[;1;m'), returnsNormally);
    });

    test('未识别 ESC 前缀不吞后续正文（评审回归）', () {
      // 字符集切换 \x1b(B 后跟正文与一个真颜色序列：中间的 Working
      // 必须完整保留，不得跳到 \x1b[32m 上。
      final spans = parseAnsiSpans('\x1b(BWorking\x1b[32mok');
      expect(spans.map((s) => s.text).join(), '\x1b(BWorkingok');
      // ok 仍是绿色（后面的真序列被正确应用）。
      expect(spans.last.style?.color, const Color(0xFF0DBC79));
    });

    test('文本完整性：所有内容保留', () {
      const input = 'ok:\x1b[32m pass\x1b[0m\nfail:\x1b[31m nope';
      expect(parseAnsiSpans(input).map((s) => s.text).join(), 'ok: pass\nfail: nope');
    });
  });

  group('Bash 完整输出视图', () {
    TranscriptItem bash({String? resultText, bool truncated = false, String? summary}) =>
        TranscriptItem(
          id: 't1',
          kind: ItemKind.tool,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
          status: 'done',
          toolName: 'Bash',
          toolInput: const {'command': 'npm test'},
          summary: summary,
          resultText: resultText,
          resultTruncated: truncated,
        );

    Widget harness(TranscriptItem item) => MaterialApp(
          home: Scaffold(
            body: TranscriptListView(
              items: [item],
              queuedTexts: const [],
              loaded: true,
              scrollController: ScrollController(),
            ),
          ),
        );

    Future<void> expand(WidgetTester tester) async {
      await tester.tap(find.text('Bash').first);
      await tester.pumpAndSettle();
    }

    testWidgets('完整多行输出渲染（含着色 span）', (tester) async {
      await tester.pumpWidget(harness(bash(resultText: 'RUNS 1\nPASS 2\nDONE')));
      await expand(tester);
      expect(find.textContaining('RUNS 1'), findsOneWidget);
      expect(find.textContaining('PASS 2'), findsOneWidget);
      expect(find.textContaining('DONE'), findsOneWidget);
    });

    testWidgets('截断标记显示', (tester) async {
      await tester.pumpWidget(harness(bash(resultText: 'x', truncated: true)));
      await expand(tester);
      expect(find.textContaining('已截断'), findsOneWidget);
    });

    testWidgets('旧数据回退单行摘要', (tester) async {
      await tester.pumpWidget(harness(bash(summary: '3 passed')));
      await expand(tester);
      // 副标题是命令（npm test），摘要只出现在回退输出区。
      expect(find.text('3 passed'), findsOneWidget);
    });

    testWidgets('长输出：详情排头尾摘要 + 全文页（chat-transcript-rows）',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final long = [
        for (var i = 0; i < 120; i++) 'line-$i 内容输出足够长以触发头尾摘要',
      ].join('\n');
      await tester.pumpWidget(harness(bash(resultText: long)));
      await expand(tester);
      // 头部与尾部可见，中间省略提示出现。
      expect(find.textContaining('line-0'), findsOneWidget);
      expect(find.textContaining('line-119'), findsOneWidget);
      expect(find.textContaining('中间省略'), findsOneWidget);

      // 全文页：完整内容 + 复制入口。
      await tester.tap(find.text('查看全文'));
      await tester.pumpAndSettle();
      expect(find.byType(ToolOutputPage), findsOneWidget);
      expect(find.textContaining('line-60'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });
  });
}
/* 组合进 main 之外不可行——见下方 testWidgets 由 python 追加进 main */
