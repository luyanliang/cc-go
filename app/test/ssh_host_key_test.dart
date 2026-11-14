import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/ssh/ssh_host_key.dart';

void main() {
  group('SshHostKeyPolicy', () {
    test('首连无已知指纹 → learn', () {
      expect(
        SshHostKeyPolicy().decide('SHA256:AbCdEf123456'),
        SshHostKeyDecision.learn,
      );
    });

    test('指纹一致（忽略 SHA256: 前缀与首尾空白；base64 区分大小写）→ trust', () {
      final policy = SshHostKeyPolicy(knownFingerprint: ' SHA256:AbCdEf123456= ');
      expect(policy.decide('AbCdEf123456='), SshHostKeyDecision.trust);
      // base64 大小写敏感：不应把大小写差异视为同一指纹。
      expect(
        policy.decide('abcdef123456='),
        SshHostKeyDecision.reject,
      );
    });

    test('指纹不一致 → reject', () {
      final policy = SshHostKeyPolicy(knownFingerprint: 'SHA256:AbCdEf123456=');
      expect(policy.decide('SHA256:SomethingElse='), SshHostKeyDecision.reject);
    });
  });

  group('SshHostKeyVerifier', () {
    late SshHostKeyMemoryStore store;
    late SshHostKeyVerifier verifier;

    setUp(() {
      store = SshHostKeyMemoryStore();
      verifier = SshHostKeyVerifier(store: store);
    });

    test('首连 learn 并写入指纹', () async {
      final decision =
          await verifier.verify('pc.local', 22, 'SHA256:HostKeyOne=');
      expect(decision, SshHostKeyDecision.learn);
      expect(
        await store.read(sshHostKeyStoreKey('pc.local', 22)),
        'SHA256:HostKeyOne=',
      );
    });

    test('同指纹再次连接 trust', () async {
      await verifier.verify('pc.local', 22, 'SHA256:HostKeyOne=');
      expect(
        await verifier.verify('pc.local', 22, 'SHA256:HostKeyOne='),
        SshHostKeyDecision.trust,
      );
    });

    test('指纹变化 reject 且不改写已存指纹', () async {
      await verifier.verify('pc.local', 22, 'SHA256:HostKeyOne=');
      final decision =
          await verifier.verify('pc.local', 22, 'SHA256:Attacker=');
      expect(decision, SshHostKeyDecision.reject);
      expect(
        await store.read(sshHostKeyStoreKey('pc.local', 22)),
        'SHA256:HostKeyOne=',
      );
    });

    test('用户显式确认后更新指纹', () async {
      await verifier.verify('pc.local', 22, 'SHA256:HostKeyOne=');
      final decision = await verifier.verify('pc.local', 22, 'SHA256:NewKey=',
          userConfirmedReplacement: true);
      expect(decision, SshHostKeyDecision.learn);
      expect(
        await store.read(sshHostKeyStoreKey('pc.local', 22)),
        'SHA256:NewKey=',
      );
    });

    test('hosts 相互独立、forget 后重新 learn', () async {
      await verifier.verify('pc.local', 22, 'SHA256:KeyA=');
      expect(
        await verifier.verify('other.local', 22, 'SHA256:KeyB='),
        SshHostKeyDecision.learn,
      );

      await verifier.forget('pc.local', 22);
      expect(
        await verifier.verify('pc.local', 22, 'SHA256:KeyC='),
        SshHostKeyDecision.learn,
      );
    });
  });

  group('sshHostKeyStoreKey', () {
    test('与 daemon 证书指纹键空间隔离', () {
      expect(sshHostKeyStoreKey('pc.local', 22), 'ssh-hostkey:pc.local:22');
    });
  });
}
