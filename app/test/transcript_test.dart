import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/session_models.dart';
import 'package:cc_go/state/transcript.dart';

Map<String, dynamic> itemJson(
  String id,
  String kind, {
  String text = '',
  String status = 'done',
  String name = '',
}) =>
    {
      'kind': kind,
      'id': id,
      'text': text,
      'status': status,
      'name': name,
      'createdAt': 1730000000000,
    };

void main() {
  group('TranscriptState 合并幂等（task 6.1：反复进出不重不漏）', () {
    test('snapshot 建立全量', () {
      final state = const TranscriptState().applySessionEvent({
        'ev': 'snapshot',
        'items': [itemJson('a', 'user', text: '问题'), itemJson('b', 'assistant', text: '回答')],
        'phase': 'idle',
        'pendingPermission': null,
      });
      expect(state.loaded, isTrue);
      expect(state.items.map((i) => i.id), ['a', 'b']);
      expect(state.phase, SessionPhase.idle);
    });

    test('item.added 追加；同 id 重复 added 整体替换不重复', () {
      var state = const TranscriptState().applySessionEvent({
        'ev': 'snapshot',
        'items': [itemJson('a', 'user', text: 'v1')],
        'phase': 'idle',
      });
      state = state.applySessionEvent(
        {'ev': 'item.added', 'item': itemJson('b', 'assistant', text: '流式', status: 'streaming')},
      );
      expect(state.items.map((i) => i.id), ['a', 'b']);

      // 快照重放 + 已有条目再次 added → 仍只有两条
      state = state.applySessionEvent({
        'ev': 'snapshot',
        'items': [itemJson('a', 'user', text: 'v1'), itemJson('b', 'assistant', text: '完成', status: 'done')],
        'phase': 'idle',
      });
      state = state.applySessionEvent(
        {'ev': 'item.added', 'item': itemJson('b', 'assistant', text: '完成', status: 'done')},
      );
      expect(state.items.length, 2);
      expect(state.items.last.text, '完成');
      expect(state.items.last.status, 'done');
    });

    test('item.updated 原位替换，顺序不变；未知 id 防御性追加', () {
      var state = const TranscriptState().applySessionEvent({
        'ev': 'snapshot',
        'items': [itemJson('a', 'user'), itemJson('b', 'assistant', status: 'streaming')],
        'phase': 'running',
      });
      state = state.applySessionEvent(
        {'ev': 'item.updated', 'item': itemJson('b', 'assistant', text: '完整回答', status: 'done')},
      );
      expect(state.items.map((i) => i.id), ['a', 'b']);
      expect(state.items[1].status, 'done');

      state = state.applySessionEvent(
        {'ev': 'item.updated', 'item': itemJson('zz', 'notice')},
      );
      expect(state.items.map((i) => i.id), ['a', 'b', 'zz']);
    });

    test('同一事件序列重放两遍，结果一致（幂等）', () {
      List<Map<String, dynamic>> events() => [
            {
              'ev': 'snapshot',
              'items': [itemJson('a', 'user', text: 'hi')],
              'phase': 'idle',
            },
            {'ev': 'item.added', 'item': itemJson('b', 'assistant', status: 'streaming')},
            {'ev': 'item.updated', 'item': itemJson('b', 'assistant', text: 'ok', status: 'done')},
            {'ev': 'phase', 'phase': 'idle'},
            {'ev': 'item.added', 'item': itemJson('c', 'tool', name: 'Write')},
          ];
      var once = const TranscriptState();
      var twice = const TranscriptState();
      for (final e in events()) {
        once = once.applySessionEvent(e);
      }
      for (final e in [...events(), ...events()]) {
        twice = twice.applySessionEvent(e);
      }
      expect(twice.items.map((i) => i.id).toList(), once.items.map((i) => i.id).toList());
      expect(twice.items.map((i) => i.text).toList(), once.items.map((i) => i.text).toList());
    });

    test('phase 与 pendingPermission', () {
      var state = const TranscriptState().applySessionEvent({'ev': 'phase', 'phase': 'running'});
      expect(state.phase, SessionPhase.running);
      state = state.applySessionEvent({
        'ev': 'snapshot',
        'items': const [],
        'phase': 'awaiting-permission',
        'pendingPermission': {
          'itemId': 't1',
          'name': 'Write',
          'input': {'file_path': '/tmp/x'},
        },
      });
      expect(state.phase, SessionPhase.awaitingPermission);
      expect(state.pendingPermission?.name, 'Write');
      expect(state.pendingPermission?.input['file_path'], '/tmp/x');
    });

    test('四种条目字段解析', () {
      final state = const TranscriptState().applySessionEvent({
        'ev': 'snapshot',
        'items': [
          itemJson('u', 'user', text: '问题'),
          itemJson('a', 'assistant', text: '答', status: 'streaming'),
          itemJson('t', 'tool', name: 'Bash', status: 'running'),
          {'kind': 'notice', 'id': 'n', 'level': 'warn', 'text': '注意', 'createdAt': 1},
        ],
        'phase': 'idle',
      });
      final items = state.items;
      expect(items[0].kind, ItemKind.user);
      expect(items[1].isStreamingAssistant, isTrue);
      expect(items[2].toolName, 'Bash');
      expect(items[3].kind, ItemKind.notice);
      expect(items[3].level, 'warn');
    });
  });
}
