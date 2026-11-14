import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/pair_qr.dart';

void main() {
  group('parsePairQr', () {
    test('完整载荷（含指纹）', () {
      final payload = parsePairQr(
        'ccgo://pair?host=192.168.1.10&port=8747&code=654321&fingerprint=AA%3ABB%3ACC',
      );
      expect(payload, isNotNull);
      expect(payload!.host, '192.168.1.10');
      expect(payload.port, 8747);
      expect(payload.code, '654321');
      expect(payload.fingerprint, 'AA:BB:CC');
    });

    test('无指纹（--no-tls 模式）', () {
      final payload = parsePairQr('ccgo://pair?host=127.0.0.1&port=8747&code=123456');
      expect(payload!.fingerprint, isNull);
      expect(payload.code, '123456');
    });

    test('非 ccgo://pair 内容 → null（不改表单）', () {
      expect(parsePairQr('https://example.com/pair?host=x'), isNull);
      expect(parsePairQr('ccgo://other?host=x&port=1&code=2'), isNull);
      expect(parsePairQr('随便什么文本'), isNull);
    });

    test('缺字段或非法端口 → null', () {
      expect(parsePairQr('ccgo://pair?port=8747&code=654321'), isNull); // 无 host
      expect(parsePairQr('ccgo://pair?host=h&port=abc&code=654321'), isNull);
      expect(parsePairQr('ccgo://pair?host=h&port=70000&code=654321'), isNull);
      expect(parsePairQr('ccgo://pair?host=h&port=8747'), isNull); // 无 code
    });
  });
}
