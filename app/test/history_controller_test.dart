/// multi-project-history 4.4：HistoryController 的回放合并、分页 cursor、
/// 去重与接管调用。纯 Dart。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/history_api.dart';
import 'package:cc_go/state/history_controller.dart';
import 'package:cc_go/transport/host_link.dart';

class _FakeLink implements HostLinkBase {
  final eventsController = StreamController<DaemonEvent>.broadcast();
  final calls = <(String, Map<String, dynamic>)>[];

  /// session.history 的页序列（调用一次弹出一页）。
  List<Map<String, dynamic>> historyPages = [];
  Object? historyError;

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (method == 'session.history') {
      if (historyError != null) throw historyError!;
      assert(historyPages.isNotEmpty, '未预置页');
      return historyPages.removeAt(0);
    }
    if (method == 'session.import') {
      return {
        'summary': {
          'id': 's-imp',
          'title': 't',
          'cwd': params['cwd'],
          'phase': 'idle',
          'createdAt': 1,
          'updatedAt': 1,
          'claudeSessionId': params['claudeSessionId'],
          'model': null,
          'permissionMode': 'default',
          'origin': 'imported',
        },
      };
    }
    return {};
  }

  @override
  Future<void> close({String reason = ''}) async => eventsController.close();
}

HistoryController _boot(_FakeLink fake) =>
    HistoryController(claudeSessionId: 'cs-1', cwd: '/w', api: HistoryApi(fake.call));

Map<String, dynamic> _page(List<String> texts, int? next) => {
      'items': [
        for (final (i, text) in texts.indexed)
          {
            'kind': 'user',
            'id': 'hist-cs-1-$i-${text.hashCode.abs()}',
            'text': text,
            'createdAt': 1000 + i,
          },
      ],
      'nextBeforeLine': next,
    };

void main() {
  test('构造即拉首页；hasMore 随 nextBeforeLine', () async {
    final fake = _FakeLink()
      ..historyPages = [_page(['新'], 7)];
    final controller = _boot(fake);
    await Future<void>.delayed(Duration.zero);
    expect(controller.loading, isFalse);
    expect(controller.items.map((i) => i.text), ['新']);
    expect(controller.hasMore, isTrue);
    expect(fake.calls.single.$2['beforeLine'], isNull,
        reason: '首页不带 cursor');
    controller.dispose();
  });

  test('loadOlder：带 cursor 前插更早页；取尽后 hasMore=false 且 no-op', () async {
    final fake = _FakeLink()
      ..historyPages = [_page(['新'], 7), _page(['旧1', '旧2'], null)];
    final controller = _boot(fake);
    await Future<void>.delayed(Duration.zero);

    final started = await controller.loadOlder();
    expect(started, isTrue);
    expect(fake.calls.last.$2['beforeLine'], 7);
    expect(controller.items.map((i) => i.text), ['旧1', '旧2', '新'],
        reason: '更早条目前插，保持时间正序');

    final again = await controller.loadOlder();
    expect(again, isFalse, reason: 'cursor 取尽后不再请求');
    expect(fake.calls.where((c) => c.$1 == 'session.history'), hasLength(2));
    controller.dispose();
  });

  test('分页重放幂等：重复 id 不重复插入', () async {
    // daemon 侧边界情况：第二页重带了第一页的条目（同 id）。
    final fake = _FakeLink()
      ..historyPages = [
        {
          'items': [
            {'kind': 'user', 'id': 'same', 'text': '同一条', 'createdAt': 1},
          ],
          'nextBeforeLine': 5,
        },
        {
          'items': [
            {'kind': 'user', 'id': 'same', 'text': '同一条', 'createdAt': 1},
          ],
          'nextBeforeLine': null,
        },
      ];
    final controller = _boot(fake);
    await Future<void>.delayed(Duration.zero);
    await controller.loadOlder();
    expect(controller.items, hasLength(1), reason: '按 id 去重');
    controller.dispose();
  });

  test('首页失败暴露 error；重试成功恢复', () async {
    final fake = _FakeLink()..historyError = const RpcException('not_found', '会话文件不存在');
    final controller = _boot(fake);
    await Future<void>.delayed(Duration.zero);
    expect(controller.items, isEmpty);
    expect(controller.error, isA<RpcException>());

    fake.historyError = null;
    fake.historyPages = [_page(['恢复了'], null)];
    await controller.loadInitial();
    expect(controller.error, isNull);
    expect(controller.items.single.text, '恢复了');
    controller.dispose();
  });

  test('importSession：参数完整（title 可选），返回 imported 摘要', () async {
    final fake = _FakeLink()..historyPages = [_page(['新'], null)];
    final controller = _boot(fake);
    await Future<void>.delayed(Duration.zero);

    final summary = await controller.importSession();
    final call = fake.calls.singleWhere((c) => c.$1 == 'session.import');
    expect(call.$2, {'claudeSessionId': 'cs-1', 'cwd': '/w'});
    expect(summary.id, 's-imp');
    expect(summary.imported, isTrue);

    await controller.importSession(title: '终端会话');
    expect(fake.calls.last.$2, {'claudeSessionId': 'cs-1', 'cwd': '/w', 'title': '终端会话'});
    controller.dispose();
  });
}
