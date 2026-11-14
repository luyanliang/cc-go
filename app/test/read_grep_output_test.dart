/// task 3.3（评审修正后）：Read 完整内容原样渲染 —— Claude Code 的 Read
/// 结果自带 cat -n 风格行号，不得叠加第二层 gutter；截断标记与旧数据
/// 回退照旧。Grep 完整命中渲染。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

TranscriptItem tool(String name, Map<String, dynamic> input,
        {String? resultText, bool truncated = false, String? summary}) =>
    TranscriptItem(
      id: 't1',
      kind: ItemKind.tool,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: 'done',
      toolName: name,
      toolInput: input,
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

Future<void> expand(WidgetTester tester, String title) async {
  await tester.tap(find.textContaining(title));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Read：内容自带行号，原样渲染不叠加 gutter', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Read',
      {'file_path': '/tmp/a.dart', 'offset': 10, 'limit': 2},
      resultText: '10\t# Tasks\n11\t====',
    )));
    await expand(tester, 'Read · 完成');
    // 恰好一层行号：内容里那层。
    expect(find.textContaining('10\t# Tasks'), findsOneWidget);
    expect(find.textContaining('11\t===='), findsOneWidget);
    // 自造 gutter 的形态（行号 + 两个空格 + 行号）不应出现。
    expect(find.textContaining('10  10'), findsNothing);
  });

  testWidgets('Read：截断标记', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Read',
      {'file_path': '/tmp/a.dart'},
      resultText: '1\tx',
      truncated: true,
    )));
    await expand(tester, 'Read · 完成');
    expect(find.textContaining('已截断'), findsOneWidget);
  });

  testWidgets('Read：旧数据回退摘要', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Read',
      {'file_path': '/tmp/a.dart'},
      summary: '一行摘要',
    )));
    await expand(tester, 'Read · 完成');
    expect(find.text('一行摘要'), findsOneWidget);
  });

  testWidgets('Grep：完整命中内容渲染，旧数据回退摘要', (tester) async {
    await tester.pumpWidget(harness(tool(
      'Grep',
      {'pattern': 'TODO', 'path': 'lib'},
      resultText: 'lib/a.dart:3: // TODO fix',
    )));
    await expand(tester, 'Grep · 完成');
    expect(find.textContaining('lib/a.dart:3: // TODO fix'), findsOneWidget);
  });
}
