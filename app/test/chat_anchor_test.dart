/// 居中锚定不跳动（chat-list-scroll）：中部查看时前插更早历史不动视点、
/// 上翻中流式追加不动视点（spec 两条核心场景）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_rows.dart';

TranscriptItem _user(String id, String text) => TranscriptItem(
      id: id,
      kind: ItemKind.user,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      text: text,
    );

TranscriptItem _assistant(String id, String text) => TranscriptItem(
      id: id,
      kind: ItemKind.assistant,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: 'done',
      text: text,
    );

/// user/assistant 交错的 n 轮会话（无过程条目 → 不触发回合折叠）。
List<TranscriptItem> turns(int from, int to) => [
      for (var i = from; i < to; i++) ...[
        _user('u$i', '问 $i'),
        _assistant('a$i', '答 $i'),
      ],
    ];

Future<double> scrollToMiddle(WidgetTester tester, ScrollController controller,
    String anchorKey, List<TranscriptItem> items) async {
  final anchor = find.byKey(ValueKey<String>(anchorKey), skipOffstage: false);
  for (var i = 0; i < 40 && anchor.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  expect(anchor.evaluate(), isNotEmpty, reason: '$anchorKey 应可见');
  return tester.getRect(anchor).top;
}

void main() {
  testWidgets('中部查看时前插更早历史不移动当前行', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var items = turns(0, 30);
    final controller = ScrollController();
    addTearDown(controller.dispose);

    Future<void> pump() async {
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

    await pump();
    final before = await scrollToMiddle(tester, controller, 'a15', items);

    // 前插 10 轮更早历史（历史分页/终端合并场景）。
    items = [...turns(-10, 0), ...items];
    await pump();

    final anchor = find.byKey(const ValueKey<String>('a15'), skipOffstage: false);
    expect(anchor.evaluate(), isNotEmpty);
    expect(tester.getRect(anchor).top, before,
        reason: '前插不应移动视口中部的锚点行（居中锚定核心场景）');
    // 锚点上方就是新载入的历史。
    expect(
        find.byKey(const ValueKey<String>('a-1'), skipOffstage: false)
            .evaluate(),
        isNotEmpty,
        reason: '更早历史应在前段（向上滚动可达）');
  });

  testWidgets('上翻查看时流式追加不移动当前行', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var items = turns(0, 30);
    final controller = ScrollController();
    addTearDown(controller.dispose);

    Future<void> pump() async {
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

    await pump();
    final before = await scrollToMiddle(tester, controller, 'a5', items);

    // 尾部追加（流式新条目）。
    items = [...items, ...turns(30, 40)];
    await pump();

    final anchor = find.byKey(const ValueKey<String>('a5'), skipOffstage: false);
    expect(anchor.evaluate(), isNotEmpty);
    expect(tester.getRect(anchor).top, before,
        reason: '尾部追加不应移动上翻查看的锚点行（居中锚定核心场景）');
  });
}
