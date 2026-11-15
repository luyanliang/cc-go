import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

TranscriptItem toolItem(String status) => TranscriptItem(
      id: 't1',
      kind: ItemKind.tool,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: status,
      toolName: 'Write',
      toolInput: const {
        'file_path': '/tmp/perm/a.txt',
        'content': 'hello',
      },
    );

Widget harness(TranscriptItem item, Future<void> Function(String, bool, bool) onRespond) {
  return MaterialApp(
    home: Scaffold(
      body: TranscriptListView(
        items: [item],
        queuedTexts: const [],
        loaded: true,
        scrollController: ScrollController(),
        onRespondPermission: onRespond,
      ),
    ),
  );
}

void main() {
  testWidgets('awaiting-permission 工具条目渲染为权限卡片（7.1）', (tester) async {
    await tester.pumpWidget(harness(toolItem('awaiting-permission'), (id, a, f) async {}));
    expect(find.text('允许运行这个工具？'), findsOneWidget);
    expect(find.text('Write'), findsWidgets);
    expect(find.textContaining('/tmp/perm/a.txt'), findsOneWidget,
        reason: '等宽参数展示');
    expect(find.text('允许'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('本次会话不再询问此类工具'), findsOneWidget);
  });

  testWidgets('点击允许 → allow=true 且不带免问', (tester) async {
    String? itemId;
    bool? allow;
    bool? forSession;
    await tester.pumpWidget(harness(toolItem('awaiting-permission'),
        (id, a, f) async => (itemId, allow, forSession) = (id, a, f)));
    await tester.tap(find.text('允许'));
    expect(itemId, 't1');
    expect(allow, isTrue);
    expect(forSession, isFalse);
  });

  testWidgets('勾选免问后拒绝 → allow=false, allowToolForSession=true', (tester) async {
    bool? allow;
    bool? forSession;
    await tester.pumpWidget(harness(toolItem('awaiting-permission'),
        (id, a, f) async => (allow, forSession) = (a, f)));
    await tester.tap(find.text('本次会话不再询问此类工具'));
    await tester.pump();
    await tester.tap(find.text('拒绝'));
    expect(allow, isFalse);
    expect(forSession, isTrue);
  });

  testWidgets('应答后状态翻转 → 卡片消失，回到工具行（7.2）', (tester) async {
    await tester.pumpWidget(harness(toolItem('running'), (id, a, f) async {}));
    expect(find.text('请求权限：Write'), findsNothing, reason: '卡片消失');
    expect(find.text('Write'), findsOneWidget);
    // 运行中：行尾状态条为 spinner（dsh 规格，不再有文字标签）。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(harness(toolItem('denied'), (id, a, f) async {}));
    expect(find.text('Write'), findsOneWidget);
    expect(find.text('已拒绝'), findsOneWidget);
  });
}
