import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/main.dart';
import 'package:cc_go/state/app_link.dart';
import 'package:cc_go/state/app_link_provider.dart';
import 'package:cc_go/state/credentials.dart';
import 'package:cc_go/state/providers.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';

class _FakeLink implements HostLinkBase {
  final eventsController = StreamController<DaemonEvent>.broadcast();

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async => {};

  @override
  Future<void> close({String reason = ''}) async => eventsController.close();
}

void main() {
  group('AppLink token-invalid flow (task 4.3)', () {
    testWidgets('token 被拒 → 清凭据 → 路由回配对屏', (tester) async {
      final store = MemoryCredentialStore()
        ..write(const HostCredentials(
          host: 'h',
          port: 8747,
          token: 'stale-token',
          fingerprint: 'AA:BB',
          hostName: 'desk',
        ));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            credentialStoreProvider.overrideWithValue(store),
            appLinkFactoryProvider.overrideWithValue((creds) {
              return AppLink.custom(creds, () async {
                throw const TokenInvalidException();
              });
            }),
          ],
          child: const CcGoApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('连接到电脑'), findsOneWidget, reason: '引导重新配对');
      expect(await store.read(), isNull, reason: '失效凭据被清除');
    });

    test('daemon 以 close 4003 拒绝 → 同样触发 tokenInvalid', () async {
      final link = AppLink.custom(
        const HostCredentials(
          host: 'h',
          port: 8747,
          token: 'stale',
          fingerprint: 'AA',
          hostName: 'desk',
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
        const HostCredentials(
          host: 'h',
          port: 8747,
          token: 't',
          fingerprint: 'AA',
          hostName: 'desk',
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
