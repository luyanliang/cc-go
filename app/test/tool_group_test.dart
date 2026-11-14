/// task 3.3：分组行装配 —— 连续 3 次工具调用收成一行，展开可见组内明细。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

TranscriptItem tool(String id, String name) => TranscriptItem(
      id: id,
      kind: ItemKind.tool,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: 'done',
      toolName: name,
      toolInput: const {'file_path': '/tmp/x'},
      summary: 'ok',
    );

Widget harness(List<TranscriptItem> items) => MaterialApp(
      home: Scaffold(
        body: TranscriptListView(
          items: items,
          queuedTexts: const [],
          loaded: true,
          scrollController: ScrollController(),
        ),
      ),
    );

void main() {
  testWidgets('连续 3 次调用收成一行分组行，展开见明细', (tester) async {
    await tester.pumpWidget(harness([
      tool('t1', 'Bash'),
      tool('t2', 'Read'),
      tool('t3', 'Edit'),
    ]));
    expect(find.text('工具调用 × 3'), findsOneWidget);
    expect(find.textContaining('Bash · Read · Edit'), findsOneWidget, reason: '工具名概览');

    // 展开列出组内每次调用。
    await tester.tap(find.text('工具调用 × 3'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bash · 完成'), findsOneWidget);
    expect(find.textContaining('Read · 完成'), findsOneWidget);
    expect(find.textContaining('Edit · 完成'), findsOneWidget);
  });

  testWidgets('不足 3 次不成分组行', (tester) async {
    await tester.pumpWidget(harness([tool('t1', 'Bash'), tool('t2', 'Read')]));
    expect(find.text('工具调用 × 2'), findsNothing);
    expect(find.textContaining('Bash · 完成'), findsOneWidget);
  });
}
