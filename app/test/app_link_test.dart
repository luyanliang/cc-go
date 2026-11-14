import 'dart:async';

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
import 'package:cc_go/transport/network_kicks.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/ssh/ssh_host_key.dart';
import 'package:cc_go/transport/ssh/ssh_secrets.dart';

class _FakeLink implements HostLinkBase {
  final eventsController = StreamController<DaemonEvent>.broadcast();

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async => {};

  @override
  Future<void> close({String reason = ''}) async => eventsController.close();
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
  group('AppLink token-invalid flow (task 4.3)', () {
    testWidgets('token 被拒 → 清凭据 → 路由回配对屏', (tester) async {
      final store = MemoryHostEntryStore()
        ..save(const HostEntry(
          id: 'default',
          mode: ConnectionMode.direct,
          hostName: 'desk',
          host: 'h',
          port: 8747,
          token: 'stale-token',
          fingerprint: 'AA:BB',
        ));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hostEntryStoreProvider.overrideWithValue(store),
            sshSecretsStoreProvider.overrideWithValue(MemorySshSecretsStore()),
            sshHostKeyStoreProvider.overrideWithValue(SshHostKeyMemoryStore()),
            appNotifierProvider.overrideWithValue(_FakeAppNotifier()),
            foregroundLinkProvider.overrideWithValue(_FakeForegroundLink()),
            appLinkFactoryProvider.overrideWithValue((creds) {
              // widget 测试环境没有 connectivity 插件 mock：注入已关闭的
              // sync 广播流（async 广播的 done/取消靠 Timer 收尾，FakeAsync
              // 的 pumpAndSettle 不推进空闲时钟，会悬挂）。
              final changes = StreamController<List<ConnectivityResult>>.broadcast(sync: true);
              unawaited(changes.close());
              return AppLink.custom(creds, () async {
                throw const TokenInvalidException();
              }, kicks: NetworkKicks(changes: changes.stream));
            }),
          ],
          child: const CcGoApp(),
        ),
      );
      await tester.pumpAndSettle();
      // token 失效的清理链在微任务边界上与 pumpAndSettle 的退出时刻敏感，
      // 显式多泵几轮保证失效后的重建（清凭据 → 回配对屏）落地。
      await tester.pump();
      await tester.pump();

      expect(find.text('连接到电脑'), findsOneWidget, reason: '引导重新配对');
      expect(await store.readAll(), isEmpty, reason: '失效凭据被清除');
    });

    test('daemon 以 close 4003 拒绝 → 同样触发 tokenInvalid', () async {
      final link = AppLink.custom(
        const HostEntry(
          id: 'default',
          mode: ConnectionMode.direct,
          hostName: 'desk',
          host: 'h',
          port: 8747,
          token: 'stale',
          fingerprint: 'AA',
        ),
        () async => throw const AuthRejectedByServer('unauthorized'),
      );
      final fired = link.tokenInvalid.first.timeout(const Duration(seconds: 2));
      await link.start();
      await fired;
      await link.stop();
    });

    test('正常连接暴露 wrapped link 状态流', () async {
      final link = AppLink.custom(
        const HostEntry(
          id: 'default',
          mode: ConnectionMode.direct,
          hostName: 'desk',
          host: 'h',
          port: 8747,
          token: 't',
          fingerprint: 'AA',
        ),
        () async => _FakeLink(),
      );
      final connected = link.link.states.firstWhere((s) => s == LinkState.connected);
      await link.start();
      await connected.timeout(const Duration(seconds: 2));
      expect(link.link.state, LinkState.connected);
      await link.stop();
    });
  });
}
