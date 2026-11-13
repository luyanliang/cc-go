import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/tofu.dart';

void main() {
  group('fingerprint format', () {
    test('openssl-style uppercase colon hex (known vector)', () {
      // sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      expect(
        fingerprintOfDer([]),
        'E3:B0:C4:42:98:FC:1C:14:9A:FB:F4:C8:99:6F:B9:24:'
        '27:AE:41:E4:64:9B:93:4C:A4:95:99:1B:78:52:B8:55',
      );
    });

    test('produces 32 bytes worth of hex', () {
      final fp = fingerprintOfDer(List.filled(64, 7));
      expect(fp.split(':').length, 32);
      expect(fp, fp.toUpperCase());
    });
  });

  group('normalizeFingerprint', () {
    test('uppercases and drops separators', () {
      expect(
        normalizeFingerprint('aa:bb:0c'),
        normalizeFingerprint('AABB0C'),
      );
    });
  });

  group('TofuPolicy', () {
    const pinned =
        'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:'
        'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';

    test('first connection (no pin) learns', () {
      expect(TofuPolicy().decide(pinned), TofuDecision.learn);
    });

    test('matching pin trusts, ignoring case/colon differences', () {
      final policy = TofuPolicy(expectedFingerprint: pinned.toLowerCase());
      expect(policy.decide(pinned), TofuDecision.trust);
    });

    test('tampered fingerprint rejects', () {
      final policy = TofuPolicy(expectedFingerprint: pinned);
      final tampered = pinned.replaceFirst('AA', 'AB');
      expect(policy.decide(tampered), TofuDecision.reject);
    });
  });

  group('MemoryFingerprintStore', () {
    test('write → read → remove (忘记主机)', () async {
      final store = MemoryFingerprintStore();
      const host = '203.0.113.7:8747';
      await store.write(host, 'aa:bb');
      expect(await store.read(host), 'AABB');

      await store.remove(host);
      expect(await store.read(host), isNull); // next connection re-learns
    });

    test('hosts are independent', () async {
      final store = MemoryFingerprintStore();
      await store.write('h1:1', 'aa');
      expect(await store.read('h2:2'), isNull);
    });
  });
}
