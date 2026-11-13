import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/host_link.dart';

void main() {
  group('encodeRequest', () {
    test('produces {id, method, params}', () {
      final json = jsonDecode(encodeRequest('r0', 'session.prompt', {
        'sessionId': 's1',
        'text': 'hi',
      })) as Map<String, dynamic>;
      expect(json['id'], 'r0');
      expect(json['method'], 'session.prompt');
      expect(json['params'], {'sessionId': 's1', 'text': 'hi'});
    });

    test('empty params still serialize as {}', () {
      final json = jsonDecode(encodeRequest('r1', 'host.info', {}))
          as Map<String, dynamic>;
      expect(json['params'], isEmpty);
    });
  });

  group('decodeFrame', () {
    test('decodes an ok response', () {
      final frame = decodeFrame('{"id":"r0","ok":true,"result":{"answer":42}}');
      final response = frame as ResponseFrame;
      expect(response.id, 'r0');
      expect(response.ok, isTrue);
      expect((response.result as Map)['answer'], 42);
    });

    test('decodes an error response', () {
      final frame =
          decodeFrame('{"id":"r1","ok":false,"error":{"code":"not_found","message":"no such session"}}');
      final response = frame as ResponseFrame;
      expect(response.ok, isFalse);
      expect(response.errorCode, 'not_found');
      expect(response.errorMessage, 'no such session');
    });

    test('decodes an event push', () {
      final frame = decodeFrame(jsonEncode({
        'type': 'event',
        'event': {
          'type': 'permission.request',
          'sessionId': 's1',
          'itemId': 'i9',
          'name': 'Write',
        },
      }));
      final event = (frame as EventFrame).event;
      expect(event['type'], 'permission.request');
      expect(event['sessionId'], 's1');
    });

    test('rejects garbage', () {
      expect(() => decodeFrame('not json'), throwsFormatException);
      expect(() => decodeFrame('[1,2]'), throwsFormatException);
      expect(() => decodeFrame('{"ok":true}'), throwsFormatException); // no id
      expect(() => decodeFrame('{"id":"r0"}'), throwsFormatException); // no ok
      expect(
        () => decodeFrame('{"id":"r0","ok":false,"error":{"code":"x"}}'),
        throwsFormatException, // error without message
      );
      expect(() => decodeFrame('{"type":"event"}'), throwsFormatException); // no event
    });
  });

  group('DaemonEvent accessors', () {
    test('typed envelope over raw payload', () {
      final event = DaemonEvent({
        'type': 'session',
        'sessionId': 's1',
        'event': {'ev': 'phase', 'phase': 'running'},
      });
      expect(event.type, 'session');
      expect(event.sessionId, 's1');
      expect(event.sessionEvent?['ev'], 'phase');
      expect(event.itemId, isNull);
    });

    test('broadcasts carry no sessionId', () {
      final event = DaemonEvent({'type': 'sessions.changed'});
      expect(event.sessionId, isNull);
      expect(event.sessionEvent, isNull);
    });
  });

  group('RequestRouter pairing', () {
    test('ok response completes the matching call', () async {
      final router = RequestRouter();
      final pending = router.reserve();
      final result = await Future.wait([
        Future.sync(() => pending.completer.future),
        Future.sync(() {
          router.deliver(ResponseFrame.ok(pending.id, {'hello': 'host'}));
        }).then((_) => null),
      ]);
      expect((result.first as Map)['hello'], 'host');
      expect(router.hasPending, isFalse);
    });

    test('error response fails the matching call with RpcException', () async {
      final router = RequestRouter();
      final pending = router.reserve();
      router.deliver(ResponseFrame.err(pending.id, 'unauthorized', 'bad token'));
      await expectLater(
        pending.completer.future,
        throwsA(isA<RpcException>().having((e) => e.code, 'code', 'unauthorized')),
      );
    });

    test('responses arrive in any order and pair by id', () async {
      final router = RequestRouter();
      final first = router.reserve();
      final second = router.reserve();
      expect(first.id, isNot(second.id));

      router.deliver(ResponseFrame.ok(second.id, 'second-answer'));
      router.deliver(ResponseFrame.ok(first.id, 'first-answer'));

      expect(await first.completer.future, 'first-answer');
      expect(await second.completer.future, 'second-answer');
    });

    test('unknown id is ignored, not a crash', () {
      final router = RequestRouter();
      final pending = router.reserve();
      router.deliver(ResponseFrame.ok('no-such-id', null));
      expect(router.hasPending, isTrue);
      expect(pending.isCompleted, isFalse);
    });

    test('failAll fails every pending call', () async {
      final router = RequestRouter();
      final calls = [router.reserve(), router.reserve()];
      router.failAll(const HostLinkClosed('closed by peer'));
      for (final call in calls) {
        await expectLater(
          call.completer.future,
          throwsA(isA<HostLinkClosed>()),
        );
      }
      expect(router.hasPending, isFalse);
    });
  });
}
