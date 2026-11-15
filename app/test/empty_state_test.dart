/// 空态测试（chat-visual-system）：时段问候、建议卡片填入输入框（不直
/// 接发送）、加载态与空态可区分（chat-empty-state + draftSink 通道）。
library;

import 'dart:async';

import 'package:cc_go/state/chat_controller.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/ui/chat/chat_screen.dart';
import 'package:cc_go/ui/chat/empty_state.dart';
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

/// watch 永不返回：未加载态用。
class HangingLink implements HostLinkBase {
  @override
  Stream<DaemonEvent> get events => const Stream.empty();

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) =>
      Completer<dynamic>().future;

  @override
  Future<void> close({String reason = ''}) async {}
}

void main() {
  group('greetingForHour', () {
    test('时段划分', () {
      expect(greetingForHour(6), '早上好');
      expect(greetingForHour(12), '中午好');
      expect(greetingForHour(15), '下午好');
      expect(greetingForHour(20), '晚上好');
      expect(greetingForHour(2), '夜深了');
    });
  });

  group('ChatEmptyState', () {
    testWidgets('渲染问候 + 建议卡片，点击回调给出提示词', (tester) async {
      String? filled;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatEmptyState(
            onSuggestion: (t) => filled = t,
            suggestions: const [EmptySuggestion('标题', '说明', '提示词原文', Icons.map_outlined)],
          ),
        ),
      ));
      expect(find.textContaining(RegExp('早上好|中午好|下午好|晚上好|夜深了')),
          findsOneWidget);
      expect(find.text('标题'), findsOneWidget);

      await tester.tap(find.text('标题'));
      expect(filled, '提示词原文');
    });
  });

  testWidgets('未加载显示加载态（转圈），与空态可区分', (tester) async {
    // 不 start 链路：watch 未发出，loaded 仍为 false。
    final pendingLink = ReconnectingHostLink(
      connector: () async => HangingLink(),
      baseDelay: const Duration(milliseconds: 1),
    );
    addTearDown(pendingLink.stop);
    final pending = ChatController(sessionId: 's2', link: pendingLink);
    addTearDown(pending.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatBody(controller: pending)),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(ChatEmptyState), findsNothing);
  });

  group('空态接线', () {
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

    testWidgets('已加载为空时空态出现；点建议卡片经 draftSink 填入 Composer',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatBody(controller: controller)),
      ));
      // watch 返回后 loaded = true，items 为空 → 空态。
      await tester.pumpAndSettle();
      expect(find.byType(ChatEmptyState), findsOneWidget);

      await tester.tap(find.text('项目导览'));
      await tester.pumpAndSettle();
      // draftSink → Composer 的输入框出现提示词。
      expect(find.textContaining('介绍一下这个项目'), findsOneWidget);
    });
  });
}
