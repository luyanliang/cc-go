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
import 'package:cc_go/state/credentials.dart';
import 'package:cc_go/state/providers.dart';
import 'package:cc_go/transport/host_link.dart';

/// 可编程假 daemon：host.info/session.create/projects.list 可预设，事件可注入。
class FakeDaemonLink implements HostLinkBase {
  FakeDaemonLink();

  final eventsController = StreamController<DaemonEvent>.broadcast();
  final calls = <(String, Map<String, dynamic>?)>[];
  List<Map<String, dynamic>> sessions = [];

  /// projects.list 结果；默认单项目（daemon 注册表为空时的默认目录语义）。
  List<Map<String, dynamic>> projects = [
    {'path': '/tmp/ccgo-test', 'name': 'ccgo-test', 'available': true, 'sessionCount': 0},
  ];
  int sessionSeq = 0;

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  Map<String, dynamic> _newSession() {
    sessionSeq++;
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': 's-$sessionSeq',
      'title': '新会话 $sessionSeq',
      'cwd': '/tmp/ccgo-test',
      'phase': 'idle',
      'createdAt': now,
      'updatedAt': now,
      'claudeSessionId': null,
      'model': null,
      'permissionMode': 'default',
    };
  }

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
      final summary = _newSession();
      sessions = [...sessions, summary];
      return {'summary': summary};
    }
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

  void emitSessionsChanged() =>
      eventsController.add(DaemonEvent({'type': 'sessions.changed'}));
}

class Harness {
  final store = MemoryCredentialStore();
  final fake = FakeDaemonLink();

  Widget boot() {
    store.write(const HostCredentials(
      host: '203.0.113.7',
      port: 8747,
      token: 'tok',
      fingerprint: 'AA:BB',
      hostName: 'desk',
    ));
    return ProviderScope(
      overrides: [
        credentialStoreProvider.overrideWithValue(store),
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

Map<String, dynamic> sessionJson(
  String id,
  String title,
  String phase,
  int updatedMinutesAgo, {
  String cwd = '/home/luke/work',
  String origin = 'created',
}) {
  final now = DateTime.now();
  return {
    'id': id,
    'title': title,
    'cwd': cwd,
    'phase': phase,
    'createdAt': now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    'updatedAt': now.subtract(Duration(minutes: updatedMinutesAgo)).millisecondsSinceEpoch,
    'claudeSessionId': null,
    'model': null,
    'permissionMode': 'default',
    'origin': origin,
  };
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
  testWidgets('未配对：显示配对屏表单', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
          appNotifierProvider.overrideWithValue(_FakeAppNotifier()),
          foregroundLinkProvider.overrideWithValue(_FakeForegroundLink()),
        ],
        child: const CcGoApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接到电脑'), findsOneWidget);
    expect(find.text('配对'), findsOneWidget);
  });

  testWidgets('会话列表：字段齐全 + 待权限置顶（5.1/5.3）', (tester) async {
    final h = Harness()
      ..fake.sessions = [
        sessionJson('idle-1', '改 bug', 'idle', 3),
        sessionJson('run-1', '跑测试', 'running', 1),
        sessionJson('perm-1', '要写文件', 'awaiting-permission', 10),
      ];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    expect(find.text('改 bug'), findsOneWidget);
    expect(find.text('/home/luke/work'), findsNWidgets(3));
    expect(find.text('刚刚'), findsNothing); // 1 分钟前的不是"刚刚"
    expect(find.text('1 分钟前'), findsOneWidget);

    // 待权限排在最前（multi-project-history 后首个 ListTile 是分组头，
    // 会话 tile 从含会话标题的 ListTile 里找）
    final sessionTiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .where((tile) => find
            .descendant(of: find.byWidget(tile), matching: find.text('要写文件'))
            .evaluate()
            .isNotEmpty ||
            find.descendant(of: find.byWidget(tile), matching: find.text('改 bug')).evaluate().isNotEmpty ||
            find.descendant(of: find.byWidget(tile), matching: find.text('跑测试')).evaluate().isNotEmpty)
        .toList();
    expect(sessionTiles, isNotEmpty);
    expect(
      find.descendant(of: find.byWidget(sessionTiles.first), matching: find.text('要写文件')),
      findsOneWidget,
    );
    // 金色徽标存在
    expect(
      tester.widget<Icon>(find.descendant(
        of: find.byWidget(sessionTiles.first),
        matching: find.byIcon(Icons.lock_clock),
      )).color,
      Colors.amber,
    );
  });

  testWidgets('sessions.changed 防抖刷新：电脑侧新建 → 列表出现（5.1）', (tester) async {
    final h = Harness()..fake.sessions = [sessionJson('s0', '旧会话', 'idle', 5)];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();
    expect(find.text('未连接电脑，正在重试…'), findsNothing,
        reason: '已连接时无断线横幅');
    expect(find.text('旧会话'), findsOneWidget);
    expect(find.text('新来的'), findsNothing);

    // 电脑侧建了新会话，daemon 广播
    h.fake.sessions = [
      ...h.fake.sessions,
      sessionJson('s1', '新来的', 'idle', 0),
    ];
    h.fake.emitSessionsChanged();
    await tester.pump(); // 触发防抖计时器
    expect(find.text('新来的'), findsNothing, reason: '防抖窗口内不刷新');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(
      h.fake.calls.map((c) => c.$1).where((m) => m == 'host.info').length,
      greaterThan(1),
      reason: '防抖后重新拉取 host.info',
    );
    expect(find.text('新来的'), findsOneWidget);
  });

  testWidgets('新建会话：调 RPC → 列表更新 → 直达聊天页（5.2）', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建会话'));
    await tester.pumpAndSettle();

    final createCall = h.fake.calls
        .where((c) => c.$1 == 'session.create')
        .reduce((a, b) => b); // 取最后一次
    expect(createCall.$2?['cwd'], '/tmp/ccgo-test',
        reason: '仅一个可用项目：直接在该目录创建（multi-project-history 4.3）');
    expect(find.text('新会话 1'), findsOneWidget, reason: '列表即时合入');
    expect(find.text('发送第一条消息开始'), findsOneWidget, reason: '导航到空转录聊天页');
  });

  testWidgets('忘记主机：清凭据回到配对屏', (tester) async {
    final h = Harness()..fake.sessions = [];
    await tester.pumpWidget(h.boot());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('忘记主机').last);
    await tester.pumpAndSettle();

    expect(find.text('连接到电脑'), findsOneWidget);
    expect(await h.store.read(), isNull);
  });
}
