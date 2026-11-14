import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/ssh/ssh_secrets.dart';

void main() {
  group('MemorySshSecretsStore', () {
    test('write → read → remove', () async {
      final store = MemorySshSecretsStore();
      expect(await store.read('host1'), isNull);

      const secrets =
          SshSecrets(password: 'pw', privateKeyPem: '-----BEGIN KEY-----');
      await store.write('host1', secrets);
      expect(await store.read('host1'), same(secrets));

      await store.remove('host1');
      expect(await store.read('host1'), isNull);
    });

    test('hosts 相互独立', () async {
      final store = MemorySshSecretsStore();
      await store.write('host1', const SshSecrets(password: 'a'));
      await store.write('host2', const SshSecrets(privateKeyPem: 'key'));
      expect((await store.read('host1'))!.password, 'a');
      expect((await store.read('host1'))!.privateKeyPem, isNull);
      expect((await store.read('host2'))!.password, isNull);
    });
  });

  group('SshSecrets JSON 往返', () {
    test('只编码已设置的字段', () {
      const pemOnly = SshSecrets(privateKeyPem: 'pem');
      expect(pemOnly.toJson(), {'privateKeyPem': 'pem'});
      expect(SshSecrets.fromJson(pemOnly.toJson()).privateKeyPem, 'pem');
      expect(SshSecrets.fromJson(pemOnly.toJson()).password, isNull);
    });

    test('isEmpty 区分已配置与未配置', () {
      expect(const SshSecrets().isEmpty, isTrue);
      expect(const SshSecrets(password: 'x').isEmpty, isFalse);
    });
  });
}
