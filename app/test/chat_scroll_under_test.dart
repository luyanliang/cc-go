/// 内容滚动到玻璃之下（chat-visual-system）：顶部 scrim 随滚动距离渐显、
/// composer 浮底无溢出。
library;

import 'dart:async';

import 'package:cc_go/state/chat_controller.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/ui/chat/chat_screen.dart';
import 'package:cc_go/ui/chat/composer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class FakeLink implements HostLinkBase {
  final eventsController = StreamController<DaemonEvent>.broadcast();

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'session.watch') {
      return {
        'snapshot': {'items': <dynamic>[], 'phase': 'idle'},
        'summary': {'id': params['sessionId']},
      };
    }
    return {};
  }

  @override
  Future<void> close({String reason = ''}) async => eventsController.close();
}

void main() {
  late FakeLink fake;
  late ReconnectingHostLink wrapped;
  late ChatController controller;

  setUp(() async {
    fake = FakeLink();
    wrapped = ReconnectingHostLink(
      connector: () async => fake,
      baseDelay: const Duration(milliseconds: 1),
    );
    controller = ChatController(sessionId: 's1', link: wrapped);
    await wrapped.start();
    await wrapped.states.firstWhere((s) => s == LinkState.connected);
  });

  tearDown(() async {
    controller.dispose();
    await wrapped.stop();
  });

  Future<void> emitAssistant(WidgetTester tester, String id, String text) async {
    fake.eventsController.add(DaemonEvent({
      'type': 'session',
      'sessionId': 's1',
      'event': {
        'ev': 'item.added',
        'item': {'kind': 'assistant', 'id': id, 'text': text, 'status': 'done', 'createdAt': 1},
      },
    }));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
  }

  double scrimTopAlpha(WidgetTester tester) {
    // 顶部 chrome scrim：begin=顶部 的渐变首色 alpha（列表在顶部时为 0）。
    for (final c in tester.widgetList<Container>(find.byType(Container))) {
      final d = c.decoration;
      if (d is BoxDecoration && d.gradient is LinearGradient) {
        final g = d.gradient! as LinearGradient;
        if (g.begin == Alignment.topCenter) return g.colors.first.a;
      }
    }
    return 0;
  }

  testWidgets('列表在顶部时 scrim 不可见，上滚后渐显', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatBody(
          controller: controller,
          header: const SizedBox(height: 48, child: Text('header')),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(scrimTopAlpha(tester), 0);

    // 两条长内容撑出可滚动区域；emit 会触发贴底，先拉回顶部。
    final longText = List.filled(40, '很长的一行输出内容，用来撑出可滚动区域。').join('\n');
    await emitAssistant(tester, 'a1', longText);
    await emitAssistant(tester, 'a2', longText);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 10000));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(scrimTopAlpha(tester), greaterThan(0),
        reason: '上滚离开顶部后顶部 scrim 应渐显');
  });

  testWidgets('composer 浮底：Stack 布局无溢出', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatBody(controller: controller)),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Composer), findsOneWidget);
    // _Measured 回调后列表 bottom padding 覆盖 composer（无异常即通过）。
  });

  testWidgets('回到底部键：上翻出现、点击回底消失并恢复贴底', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatBody(controller: controller)),
    ));
    await tester.pumpAndSettle();

    final longText = List.filled(40, '很长的一行输出内容，用来撑出可滚动区域。').join('\n');
    await emitAssistant(tester, 'a1', longText);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    double jumpOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(find
            .ancestor(of: find.byIcon(Icons.arrow_downward),
                matching: find.byType(AnimatedOpacity))
            .first)
        .opacity;

    // 贴底时不显示（透明度 0；键常驻树中以驱动显隐动画）。
    expect(jumpOpacity(tester), 0);

    // 上翻 → 出现。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(jumpOpacity(tester), 1);

    // 点击 → 回到底部，键隐去。
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(jumpOpacity(tester), 0);
  });

  testWidgets('待权限时输入条上方出现权限胶囊（chat-transcript-rows）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatBody(controller: controller)),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('待权限'), findsNothing);

    fake.eventsController.add(DaemonEvent({
      'type': 'session',
      'sessionId': 's1',
      'event': {
        'ev': 'item.added',
        'item': {
          'kind': 'tool',
          'id': 't1',
          'status': 'awaiting-permission',
          'name': 'Bash',
          'toolInput': {'command': 'rm -rf /'},
          'createdAt': 1,
        },
      },
    }));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.textContaining('待权限：Bash'), findsOneWidget);
  });
}
