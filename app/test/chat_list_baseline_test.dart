/// 列表重构基线（chat-list-scroll 3.1）：迁居中锚定前，把「重构后必须
/// 仍然成立」的行为固化成测试 —— 视口中部查看时底部追加不动当前行、
/// 折叠行展开状态在视口内滚动后保持。
///
/// 注：懒加载列表把行滚出视口后行内状态（ExpansionTile 等）本来就会
/// 释放，这是现状基线，不在此要求升级（居中锚定重构不改变该语义）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

TranscriptItem _assistant(String id, String text, {String status = 'done'}) =>
    TranscriptItem(
      id: id,
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: status,
      text: text,
    );

Future<void> pumpList(WidgetTester tester, ScrollController controller,
    List<TranscriptItem> items) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TranscriptListView(
        items: items,
        queuedTexts: const [],
        loaded: true,
        scrollController: controller,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('视口中部查看时底部追加内容不改变当前行位置', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // user/assistant 交错：每轮无过程条目 → 不触发回合折叠，行 = 60 条。
    final items = [
      for (var i = 0; i < 30; i++) ...[
        TranscriptItem(
          id: 'u$i',
          kind: ItemKind.user,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
          text: '问 $i',
        ),
        _assistant('a$i', '第 $i 条消息内容'),
      ],
    ];
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await pumpList(tester, controller, items);

    // 拖到中部行可见（行主键 = 条目 id），锁定它在屏幕上的位置。
    final anchorItem = find.byKey(const ValueKey<String>('a15'), skipOffstage: false);
    for (var i = 0; i < 40 && anchorItem.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(anchorItem.evaluate(), isNotEmpty, reason: '拖拽后锚点行应可见');
    final before = tester.getRect(anchorItem).top;

    // 底部追加 10 条（列表自然增长）。
    items.addAll([for (var i = 30; i < 40; i++) _assistant('a$i', '第 $i 条消息内容')]);
    await pumpList(tester, controller, items);

    expect(tester.getRect(anchorItem).top, before,
        reason: '底部追加不应移动视口中部的行（重构前后都必须成立）');
  });

  testWidgets('折叠行展开状态在视口内小距离滚动后保持', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
      _assistant('a1', '修好了，测试全绿。'),
    ];
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await pumpList(tester, controller, items);

    await tester.tap(find.textContaining('已收起'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bash'), findsOneWidget);

    // 视口内小距离滚动（不出 cacheExtent）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bash'), findsOneWidget,
        reason: '行主键必须让展开状态在视口内滚动态保持（重构前后都必须成立）');
  });
}
