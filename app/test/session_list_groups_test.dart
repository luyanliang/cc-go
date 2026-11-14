/// multi-project-history 4.2/4.3：会话列表按项目分组渲染（显示名/失效
/// 置灰/空分组提示/导入标识/历史入口）与新建会话目录选择（单项目直建、
/// 多项目先选）。
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

/// 可编程假 daemon：本组测试关心 projects.list / host.info / session.create。
class FakeDaemonLink implements HostLinkBase {
  FakeDaemonLink();

  final eventsController = StreamController<DaemonEvent>.broadcast();
  final calls = <(String, Map<String, dynamic>?)>[];
  List<Map<String, dynamic>> projects = [];
  List<Map<String, dynamic>> sessions = [];

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
    if (method == 'session.create') {
      final now = DateTime.now().millisecondsSinceEpoch;
      final summary = {
        'id': 's-new',
        'title': '新会话',
        'cwd': params['cwd'],
        'phase': 'idle',
        'createdAt': now,
        'updatedAt': now,
        'claudeSessionId': null,
        'model': null,
        'permissionMode': 'default',
        'origin': 'created',
      };
      return {'summary': summary};
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

Map<String, dynamic> _project(String path, String name, bool available) =>
    {'path': path, 'name': name, 'available': available, 'sessionCount': 0};

Map<String, dynamic> _session(
  String id,
  String title,
  String cwd,
  int updatedMinutesAgo, {
  String origin = 'created',
}) {
  final now = DateTime.now();
  return {
    'id': id,
    'title': title,
    'cwd': cwd,
    'phase': 'idle',
    'createdAt': now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
    'updatedAt': now.subtract(Duration(minutes: updatedMinutesAgo)).millisecondsSinceEpoch,
    'claudeSessionId': null,
    'model': null,
    'permissionMode': 'default',
    'origin': origin,
  };
}

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
  testWidgets('分组渲染：项目显示名分组、组内会话归属正确、最近活动的组在前', (tester) async {
    final h = Harness()
      ..fake.projects = [
        _project('/w/alpha', 'alpha', true),
        _project('/w/beta', 'beta', true),
      ]
      ..fake.sessions = [
        _session('a1', '改 bug', '/w/alpha', 3),
        _session('b1', '跑测试', '/w/beta', 30),
      ];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    expect(find.text('alpha'), findsOneWidget, reason: '分组标题=项目显示名');
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('/w/alpha'), findsNWidgets(2),
        reason: '组头副标题 + 组内会话行副标题都带路径');

    final alphaHeaderY = tester.getTopLeft(find.text('alpha')).dy;
    final a1Y = tester.getTopLeft(find.text('改 bug')).dy;
    final betaHeaderY = tester.getTopLeft(find.text('beta')).dy;
    final b1Y = tester.getTopLeft(find.text('跑测试')).dy;
    expect(alphaHeaderY, lessThan(betaHeaderY), reason: 'alpha 组更近活动，排在前');
    expect(alphaHeaderY, lessThan(a1Y));
    expect(a1Y, lessThan(betaHeaderY), reason: 'alpha 的会话在 alpha 组内');
    expect(betaHeaderY, lessThan(b1Y));
  });

  testWidgets('导入会话带"导入"来源标识，创建的没有', (tester) async {
    final h = Harness()
      ..fake.projects = [_project('/w/alpha', 'alpha', true)]
      ..fake.sessions = [
        _session('a1', '自己建的', '/w/alpha', 5),
        _session('a2', '接管的', '/w/alpha', 6, origin: 'imported'),
      ];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    expect(find.text('接管的'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget, reason: '仅 imported 会话带标识');
  });

  testWidgets('失效目录分组置灰：目录不存在标记 + 历史入口禁用但可见', (tester) async {
    final h = Harness()
      ..fake.projects = [
        _project('/w/alpha', 'alpha', true),
        _project('/w/gone', 'gone', false),
      ]
      ..fake.sessions = [_session('a1', '改 bug', '/w/alpha', 3)];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    expect(find.text('gone'), findsOneWidget, reason: '失效目录不被隐藏');
    expect(find.text('目录不存在'), findsOneWidget);
    expect(find.byIcon(Icons.folder_off_outlined), findsOneWidget);
    expect(find.text('目录已不存在，无法新建或发现会话'), findsOneWidget);

    // 失效组的历史入口禁用；可用组的可点。
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('project-history-disabled-gone')))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('project-history-/w/alpha'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('空分组提示可新建；每组提供会话历史入口', (tester) async {
    final h = Harness()
      ..fake.projects = [
        _project('/w/alpha', 'alpha', true),
        _project('/w/empty', 'empty', true),
      ]
      ..fake.sessions = [_session('a1', '改 bug', '/w/alpha', 3)];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    expect(find.text('empty'), findsOneWidget, reason: '空分组保留可见');
    expect(find.text('该项目还没有会话，点右下角新建'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('project-history-/w/alpha')));
    await tester.pumpAndSettle();
    expect(find.text('会话历史 · alpha'), findsOneWidget, reason: '进入该项目的会话历史页');
  });

  testWidgets('4.3 仅一个可用项目：点新建直接创建，不弹目录选择', (tester) async {
    final h = Harness()
      ..fake.projects = [_project('/w/only', 'only', true)]
      ..fake.sessions = [];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建会话'));
    await tester.pumpAndSettle();

    expect(find.text('选择项目目录'), findsNothing, reason: '单项目无需选择');
    final createCall = h.fake.calls.where((c) => c.$1 == 'session.create').single;
    expect(createCall.$2?['cwd'], '/w/only');
    expect(find.byType(TextField), findsOneWidget, reason: '直达正常聊天页（composer 可用）');
  });

  testWidgets('4.3 多个可用项目：先弹选择，选定目录后创建', (tester) async {
    final h = Harness()
      ..fake.projects = [
        _project('/w/alpha', 'alpha', true),
        _project('/w/beta', 'beta', true),
        _project('/w/dead', 'dead', false), // 不可用项目不得进入选择
      ]
      ..fake.sessions = [];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建会话'));
    await tester.pumpAndSettle();

    expect(find.text('选择项目目录'), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-project-/w/alpha')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-project-/w/beta')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-project-/w/dead')), findsNothing,
        reason: '失效目录不出现在选择列表');

    await tester.tap(find.byKey(const ValueKey('pick-project-/w/beta')));
    await tester.pumpAndSettle();

    final createCall = h.fake.calls.where((c) => c.$1 == 'session.create').single;
    expect(createCall.$2?['cwd'], '/w/beta');
  });

  testWidgets('4.3 多项目但取消选择：不创建任何会话', (tester) async {
    final h = Harness()
      ..fake.projects = [
        _project('/w/alpha', 'alpha', true),
        _project('/w/beta', 'beta', true),
      ]
      ..fake.sessions = [];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建会话'));
    await tester.pumpAndSettle();
    // 点 modal barrier 取消。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(h.fake.calls.where((c) => c.$1 == 'session.create'), isEmpty);
    expect(find.text('会话'), findsOneWidget, reason: '仍停留列表页');
  });
}
