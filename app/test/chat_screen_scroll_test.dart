import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/chat_controller.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/ui/chat/chat_screen.dart';

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

  Future<void> pumpBody(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatBody(controller: controller))),
    );
  }

  /// FakeAsync 的 pump 只冲刷微任务一跳，跨流多跳（fake→wrapper→controller）
  /// 的事件链不会自动送达——用 runAsync 在真实时区把链路冲完。
  Future<void> emitAssistant(WidgetTester tester, String id, String text, String status) async {
    fake.eventsController.add(DaemonEvent({
      'type': 'session',
      'sessionId': 's1',
      'event': {
        'ev': 'item.added',
        'item': {'kind': 'assistant', 'id': id, 'text': text, 'status': status, 'createdAt': 1},
      },
    }));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
  }

  ScrollPosition positionOf(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!.position;

  testWidgets('流式输出时贴底自动滚动（回归：外层 build 不重跑导致不滚）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await pumpBody(tester);
    await tester.pumpAndSettle();

    final longText = List.filled(60, '很长的一行输出内容，用来撑出可滚动区域。').join('\n');
    await emitAssistant(tester, 'a1', longText, 'streaming');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    final position = positionOf(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '内容确实超出视口');
    expect(position.pixels, greaterThan(position.maxScrollExtent - 200),
        reason: '首条长内容应自动贴底');

    await emitAssistant(tester, 'a2', longText, 'streaming');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    final position2 = positionOf(tester);
    expect(position2.pixels, greaterThan(position2.maxScrollExtent - 200),
        reason: '后续流式条目继续贴底');
  });

  testWidgets('用户上翻后不抢滚动', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await pumpBody(tester);
    await tester.pumpAndSettle();

    final longText = List.filled(60, '很长的一行输出内容，用来撑出可滚动区域。').join('\n');
    await emitAssistant(tester, 'a1', longText, 'streaming');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(positionOf(tester).pixels,
        greaterThan(positionOf(tester).maxScrollExtent - 200));

    // 用户上翻离开底部
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();

    await emitAssistant(tester, 'a2', longText, 'streaming');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    final position = positionOf(tester);
    expect(position.pixels, lessThan(position.maxScrollExtent - 200),
        reason: '用户在上方阅读时不强制贴底');
  });
}
