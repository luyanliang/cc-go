/// multi-project-history 4.4：项目历史列表页（发现结果/已托管标记/分流）
/// 与只读聊天页（回放渲染/只读态/分页加载更早/接管动作）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cc_go/main.dart';
import 'package:cc_go/notify/app_notifier.dart';
import 'package:cc_go/notify/foreground_link.dart';
import 'package:cc_go/notify/notification_policy.dart';
import 'package:cc_go/state/app_link.dart';
import 'package:cc_go/state/app_link_provider.dart';
import 'package:cc_go/state/host_entry.dart';
import 'package:cc_go/state/providers.dart';
import 'package:cc_go/transport/host_link.dart';

/// 可编程假 daemon：discover/history 分页/import 可预设。
class FakeDaemonLink implements HostLinkBase {
  FakeDaemonLink();

  final eventsController = StreamController<DaemonEvent>.broadcast();
  final calls = <(String, Map<String, dynamic>?)>[];

  List<Map<String, dynamic>> projects = [
    {'path': '/w/alpha', 'name': 'alpha', 'available': true, 'sessionCount': 1},
  ];
  List<Map<String, dynamic>> sessions = [];

  /// sessions.discover 结果（cwd → 列表）。
  Map<String, List<Map<String, dynamic>>> discovered = {};

  /// session.history 的页序列（调用一次弹出一页，首页在前）。
  List<({List<Map<String, dynamic>> items, int? next})> historyPages = [];

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (method == 'host.info') {
      return {'host': {'name': 'desk'}, 'sessions': sessions};
    }
    if (method == 'projects.list') {
      return {'projects': projects};
    }
    if (method == 'sessions.discover') {
      return {'sessions': discovered[params['cwd']] ?? const []};
    }
    if (method == 'session.history') {
      assert(historyPages.isNotEmpty, '测试未预置 history 页');
      final page = historyPages.removeAt(0);
      return {'items': page.items, 'nextBeforeLine': page.next};
    }
    if (method == 'session.import') {
      final now = DateTime.now().millisecondsSinceEpoch;
      return {
        'summary': {
          'id': 's-imported',
          'title': params['title'] ?? '导入的会话',
          'cwd': params['cwd'],
          'phase': 'idle',
          'createdAt': now,
          'updatedAt': now,
          'claudeSessionId': params['claudeSessionId'],
          'model': null,
          'permissionMode': 'default',
          'origin': 'imported',
        },
      };
    }
    if (method == 'session.watch') {
      return {
        'snapshot': {'items': <dynamic>[], 'phase': 'idle'},
      };
    }
    return {};
  }

  @override
  Future<void> close({String reason = ''}) async => eventsController.close();
}

Map<String, dynamic> _user(String id, String text, int createdAtMs) =>
    {'kind': 'user', 'id': id, 'text': text, 'createdAt': createdAtMs};

Map<String, dynamic> _assistant(String id, String text, int createdAtMs) =>
    {'kind': 'assistant', 'id': id, 'text': text, 'status': 'done', 'createdAt': createdAtMs};

Map<String, dynamic> _discovered(
  String claudeSessionId,
  String title,
  int minutesAgo, {
  bool managed = false,
  String? ccGoSessionId,
  int messageCount = 7,
}) =>
    {
      'claudeSessionId': claudeSessionId,
      'title': title,
      'lastActiveAt':
          DateTime.now().subtract(Duration(minutes: minutesAgo)).millisecondsSinceEpoch,
      'messageCount': messageCount,
      'managed': managed,
      'ccGoSessionId': ccGoSessionId,
    };

class Harness {
  final entryStore = MemoryHostEntryStore();
  final fake = FakeDaemonLink();

  Widget boot() {
    entryStore.save(const HostEntry(
      id: 'default',
      mode: ConnectionMode.direct,
      hostName: 'desk',
      host: '203.0.113.7',
      port: 8747,
      token: 'tok',
      fingerprint: 'AA:BB',
    ));
    return ProviderScope(
      overrides: [
        hostEntryStoreProvider.overrideWithValue(entryStore),
        appNotifierProvider.overrideWithValue(_FakeAppNotifier()),
        foregroundLinkProvider.overrideWithValue(_FakeForegroundLink()),
        appLinkFactoryProvider.overrideWithValue(
          (creds) => AppLink.custom(creds, () async => fake),
        ),
      ],
      child: const CcGoApp(),
    );
  }

  /// 打开 alpha 项目的历史页（从会话列表的分组入口进入）。
  Future<void> openHistory(WidgetTester tester) async {
    await tester.pumpWidget(boot());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-history-/w/alpha')));
    await tester.pumpAndSettle();
    expect(find.text('会话历史 · alpha'), findsOneWidget);
  }
}

class _FakeAppNotifier extends AppNotifier {
  final tapsController = StreamController<String>.broadcast();

  @override
  Stream<String> get taps => tapsController.stream;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(NotifyIntent intent) async {}

  @override
  Future<String?> launchPayload() async => null;
}

class _FakeForegroundLink extends ForegroundLink {
  @override
  Future<void> start(String hostName) async {}

  @override
  Future<void> update({required bool connected, required String hostName}) async {}

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('历史列表页：标题/消息数/时间/已托管标记；托管会话直达正常聊天页', (tester) async {
    final h = Harness()
      ..fake.discovered['/w/alpha'] = [
        _discovered('cs-ext', '终端里改的 bug', 5),
        _discovered('cs-managed', '手机里建的', 30,
            managed: true, ccGoSessionId: 's-m1'),
      ];
    await h.openHistory(tester);

    expect(find.text('终端里改的 bug'), findsOneWidget);
    expect(find.text('手机里建的'), findsOneWidget);
    expect(find.text('7 条消息 · 5 分钟前'), findsOneWidget);
    expect(find.text('已托管'), findsOneWidget, reason: '已托管标记与外部会话区分');
    expect(find.byIcon(Icons.terminal), findsOneWidget, reason: '外部（终端）会话图标');
    expect(find.byIcon(Icons.link), findsOneWidget, reason: '已托管会话图标');

    await tester.tap(find.text('手机里建的'));
    await tester.pumpAndSettle();
    expect(find.text('发送第一条消息开始'), findsOneWidget,
        reason: '已托管会话进入正常聊天页（空转录）');
  });

  testWidgets('历史列表页：空结果显示空态', (tester) async {
    final h = Harness()..fake.discovered['/w/alpha'] = [];
    await h.openHistory(tester);
    expect(find.text('该项目还没有 Claude Code 会话'), findsOneWidget);
  });

  testWidgets('只读聊天页：回放条目渲染 + 只读标识 + 无输入框 + 接管入口', (tester) async {
    final h = Harness()
      ..fake.discovered['/w/alpha'] = [_discovered('cs-ext', '终端会话', 5)]
      ..fake.historyPages = [
        (
          items: [
            _user('hist-cs-ext-u1', '帮我看看构建', 1000),
            _assistant('hist-cs-ext-a1', '构建挂在了测试上', 2000),
          ],
          next: null,
        ),
      ];
    await h.openHistory(tester);

    await tester.tap(find.text('终端会话'));
    await tester.pumpAndSettle();

    expect(find.text('只读历史'), findsOneWidget, reason: 'AppBar 标识只读状态');
    expect(find.text('帮我看看构建'), findsOneWidget, reason: '回放用户条目复用现有渲染');
    expect(find.text('构建挂在了测试上'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: '未接管时不提供发送入口');
    expect(find.text('接管续聊'), findsOneWidget);
    expect(find.text('已是最早消息'), findsOneWidget, reason: '单页取尽后提示');
  });

  testWidgets('分页：加载更早带 beforeLine，更早条目前插，取尽后提示', (tester) async {
    final h = Harness()
      ..fake.discovered['/w/alpha'] = [_discovered('cs-ext', '终端会话', 5)]
      ..fake.historyPages = [
        (
          items: [
            _user('hist-cs-ext-u2', '新问题', 3000),
          ],
          next: 2,
        ),
        (
          items: [
            _user('hist-cs-ext-u1', '旧问题', 1000),
            _assistant('hist-cs-ext-a1', '旧回答', 2000),
          ],
          next: null,
        ),
      ];
    await h.openHistory(tester);

    await tester.tap(find.text('终端会话'));
    await tester.pumpAndSettle();
    expect(find.text('新问题'), findsOneWidget);
    expect(find.text('旧问题'), findsNothing);

    await tester.tap(find.text('加载更早'));
    await tester.pumpAndSettle();

    final historyCalls =
        h.fake.calls.where((c) => c.$1 == 'session.history').toList();
    expect(historyCalls, hasLength(2), reason: '首页 + 翻页各一次');
    expect(historyCalls[1].$2?['beforeLine'], 2, reason: '翻页携带上一页 cursor');
    expect(find.text('旧问题'), findsOneWidget);
    expect(find.text('旧回答'), findsOneWidget);
    expect(find.text('已是最早消息'), findsOneWidget);
    expect(find.text('加载更早'), findsNothing, reason: '取尽后翻页入口消失');

    // 前插：旧条目在新条目上方。
    expect(tester.getTopLeft(find.text('旧问题')).dy,
        lessThan(tester.getTopLeft(find.text('新问题')).dy));
  });

  testWidgets('接管：session.import 带全参数 → 成功后进入正常聊天页', (tester) async {
    final h = Harness()
      ..fake.discovered['/w/alpha'] = [_discovered('cs-ext', '终端会话', 5)]
      ..fake.historyPages = [
        (
          items: [_user('hist-cs-ext-u1', '帮我看看构建', 1000)],
          next: null,
        ),
      ];
    await h.openHistory(tester);

    await tester.tap(find.text('终端会话'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('接管续聊'));
    await tester.pumpAndSettle();

    final importCall = h.fake.calls.where((c) => c.$1 == 'session.import').single;
    expect(importCall.$2?['claudeSessionId'], 'cs-ext');
    expect(importCall.$2?['cwd'], '/w/alpha');
    expect(importCall.$2?['title'], '终端会话', reason: '标题随会话延续');

    expect(find.byType(TextField), findsOneWidget, reason: '接管后进入正常聊天页');
    expect(find.text('发送第一条消息开始'), findsOneWidget);
    expect(find.text('只读历史'), findsNothing, reason: '只读页被替换');
  });
}
