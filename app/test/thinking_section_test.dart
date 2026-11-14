/// task 5.1：thinking 展示 —— 非空默认收起、可展开、无 thinking 不出区块。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

TranscriptItem assistant({String thinking = '', String status = 'done'}) => TranscriptItem(
      id: 'a1',
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: '回答正文',
      thinking: thinking,
      status: status,
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

void main() {
  testWidgets('非空 thinking：默认收起，展开可见全文', (tester) async {
    await tester.pumpWidget(harness(assistant(thinking: '先分析问题，再考虑边界。')));
    expect(find.text('思考过程'), findsOneWidget);
    expect(find.textContaining('先分析问题'), findsNothing, reason: '默认收起');

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.textContaining('先分析问题'), findsOneWidget, reason: '展开后可见');
  });

  testWidgets('无 thinking：不出思考区块', (tester) async {
    await tester.pumpWidget(harness(assistant()));
    expect(find.text('思考过程'), findsNothing);
    expect(find.text('回答正文'), findsWidgets);
  });

  testWidgets('流式中同样可展开查看已到手的 thinking', (tester) async {
    await tester.pumpWidget(harness(assistant(thinking: '推演中…', status: 'streaming')));
    expect(find.text('思考过程'), findsOneWidget);
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.textContaining('推演中'), findsOneWidget);
  });
}
