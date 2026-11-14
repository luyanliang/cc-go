/// task 6.2：回合折叠摘要行 —— 默认收起、展开还原过程、最终回答在外。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

void main() {
  final items = [
    TranscriptItem(
      id: 'u1',
      kind: ItemKind.user,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: '帮我修这个 bug',
    ),
    TranscriptItem(
      id: 't1',
      kind: ItemKind.tool,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: 'done',
      toolName: 'Bash',
      toolInput: const {'command': 'npm test'},
      summary: '3 passed',
    ),
    TranscriptItem(
      id: 'm1',
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: 'done',
      text: '测试过了，再改一处。',
    ),
    TranscriptItem(
      id: 'a1',
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: 'done',
      text: '修好了，测试全绿。',
    ),
  ];

  Widget harness() => MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            items: items,
            queuedTexts: const [],
            loaded: true,
            scrollController: ScrollController(),
          ),
        ),
      );

  testWidgets('完成轮收成折叠行，最终回答无需展开即可见', (tester) async {
    await tester.pumpWidget(harness());
    // 折叠概览行。
    expect(find.textContaining('已收起'), findsOneWidget);
    expect(find.textContaining('1 次工具调用'), findsOneWidget);
    expect(find.textContaining('1 条消息'), findsOneWidget);
    // 最终回答在外面。
    expect(find.textContaining('修好了，测试全绿'), findsOneWidget);
    // 过程默认收起。
    expect(find.textContaining('npm test'), findsNothing);
  });

  testWidgets('展开折叠行还原过程条目', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.textContaining('已收起'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bash · 完成'), findsOneWidget);
    expect(find.textContaining('我先看看'), findsNothing, reason: '中间消息文本在展开内容里');
    // 展开后中间消息正文可见。
    expect(find.textContaining('测试过了'), findsOneWidget);
  });
}
