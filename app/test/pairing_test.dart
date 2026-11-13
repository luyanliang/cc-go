import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/credentials.dart';
import 'package:cc_go/state/pairing.dart';
import 'package:cc_go/transport/tofu.dart';

void main() {
  group('runPairing', () {
    test('成功：凭据落库（token + 指纹）', () async {
      final store = MemoryCredentialStore();
      final creds = await runPairing(
        store: store,
        host: ' 203.0.113.7 ',
        portText: ' 8747 ',
        code: '654321',
        pair: () async => const PairSuccess(
          token: 'tok-1',
          deviceId: 'dev-1',
          fingerprint: 'AA:BB',
          hostName: 'desk',
        ),
      );
      expect(creds.host, '203.0.113.7');
      expect(creds.token, 'tok-1');
      expect(creds.fingerprint, 'AA:BB');
      expect((await store.read())?.token, 'tok-1', reason: 'persisted');
    });

    test('配对码错误：可读错误 + 不落任何凭据', () async {
      final store = MemoryCredentialStore();
      await expectLater(
        runPairing(
          store: store,
          host: 'h',
          portText: '8747',
          code: '000000',
          pair: () async => throw const PairingFailedException('配对码不正确'),
        ),
        throwsA(isA<PairingError>().having((e) => e.message, 'message', '配对码不正确')),
      );
      expect(await store.read(), isNull);
    });

    test('网络不通：SocketException → 可读错误', () async {
      await expectLater(
        runPairing(
          store: MemoryCredentialStore(),
          host: '203.0.113.7',
          portText: '8747',
          code: '654321',
          pair: () async => throw const SocketException('unreachable'),
        ),
        throwsA(isA<PairingError>().having(
          (e) => e.message,
          'message',
          contains('无法连接'),
        )),
      );
    });

    test('指纹不符：TOFU 错误 → 引导忘记主机', () async {
      await expectLater(
        runPairing(
          store: MemoryCredentialStore(),
          host: 'h',
          portText: '8747',
          code: '654321',
          pair: () async => throw const TofuRejectedException('h:8747'),
        ),
        throwsA(isA<PairingError>().having(
          (e) => e.message,
          'message',
          contains('忘记主机'),
        )),
      );
    });

    test('输入校验：地址/端口/配对码', () async {
      Future<PairingError> message(Future Function() run) async {
        try {
          await run();
          fail('expected PairingError');
        } on PairingError catch (e) {
          return e;
        }
      }

      expect((await message(() => runPairing(
            store: MemoryCredentialStore(),
            host: '',
            portText: '8747',
            code: '654321',
            pair: () async => throw StateError('unreached'),
          ))).message, '请输入服务器地址');

      expect((await message(() => runPairing(
            store: MemoryCredentialStore(),
            host: 'h',
            portText: 'abc',
            code: '654321',
            pair: () async => throw StateError('unreached'),
          ))).message, '端口格式不正确');

      expect((await message(() => runPairing(
            store: MemoryCredentialStore(),
            host: 'h',
            portText: '8747',
            code: '123',
            pair: () async => throw StateError('unreached'),
          ))).message, '配对码为 6 位数字');
    });
  });

  group('HostCredentials', () {
    test('wsUri 与 displayHost', () {
      const creds = HostCredentials(
        host: '203.0.113.7',
        port: 8747,
        token: 't',
        fingerprint: 'f',
        hostName: 'desk',
      );
      expect(creds.wsUri.toString(), 'wss://203.0.113.7:8747/ws');
      expect(creds.displayHost, '203.0.113.7:8747');
    });
  });
}
