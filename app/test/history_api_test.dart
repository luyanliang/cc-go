/// multi-project-history 4.1：HistoryApi 的方法名/参数/响应解析。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/history_api.dart';

/// 记录每次调用、按需返回预置结果的假底层 call。
class _RecordingCaller {
  final calls = <(String, Map<String, dynamic>)>[];
  final results = <String, Future<dynamic> Function(Map<String, dynamic> params)>{};

  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    calls.add((method, params));
    final handler = results[method];
    if (handler == null) {
      throw StateError('unexpected method: $method');
    }
    return handler(params);
  }
}

void main() {
  late _RecordingCaller caller;
  late HistoryApi api;

  setUp(() {
    caller = _RecordingCaller();
    api = HistoryApi(caller.call);
  });

  test('projects.list：无参数，解析 projects 数组', () async {
    caller.results['projects.list'] = (_) async => {
          'projects': [
            {
              'path': '/home/luke/work/cc-go',
              'name': 'cc-go',
              'available': true,
              'sessionCount': 3,
            },
            {
              'path': '/gone/dir',
              'name': 'dir',
              'available': false,
              'sessionCount': 0,
            },
          ],
        };
    final projects = await api.listProjects();
    // record 的 == 对 Map 字段是恒等比较，故拆开断言（expect 对 Map 走深度相等）。
    expect(caller.calls.single.$1, 'projects.list');
    expect(caller.calls.single.$2, <String, dynamic>{});
    expect(projects, hasLength(2));
    expect(projects[0].path, '/home/luke/work/cc-go');
    expect(projects[0].name, 'cc-go');
    expect(projects[0].available, isTrue);
    expect(projects[0].sessionCount, 3);
    expect(projects[1].available, isFalse, reason: '失效目录标记保留');
  });

  test('projects.register：params 带原始 path，解析单个 project', () async {
    caller.results['projects.register'] = (p) async => {
          'project': {
            'path': p['path'],
            'name': 'newproj',
            'available': true,
            'sessionCount': 0,
          },
        };
    final project = await api.registerProject('/tmp/newproj');
    expect(caller.calls.single.$1, 'projects.register');
    expect(caller.calls.single.$2, {'path': '/tmp/newproj'});
    expect(project.path, '/tmp/newproj');
    expect(project.name, 'newproj');
  });

  test('sessions.discover：params 带 cwd，解析 DiscoveredSession 全字段', () async {
    caller.results['sessions.discover'] = (_) async => {
          'sessions': [
            {
              'claudeSessionId': 'cs-1',
              'title': '修一下构建',
              'lastActiveAt': 1731500000000,
              'messageCount': 12,
              'managed': false,
              'ccGoSessionId': null,
            },
            {
              'claudeSessionId': 'cs-2',
              'title': '已接管的',
              'lastActiveAt': 1731500001000,
              'messageCount': 2,
              'managed': true,
              'ccGoSessionId': 's-9',
            },
          ],
        };
    final sessions = await api.discoverSessions('/home/luke/work');
    expect(caller.calls.single.$1, 'sessions.discover');
    expect(caller.calls.single.$2, {'cwd': '/home/luke/work'});
    expect(sessions, hasLength(2));
    expect(sessions[0].claudeSessionId, 'cs-1');
    expect(sessions[0].managed, isFalse);
    expect(sessions[0].ccGoSessionId, isNull);
    expect(sessions[1].managed, isTrue);
    expect(sessions[1].ccGoSessionId, 's-9');
    expect(sessions[1].lastActiveAt.millisecondsSinceEpoch, 1731500001000);
  });

  test('session.history：首页不带 cursor；翻页带 beforeLine 与 limit', () async {
    caller.results['session.history'] = (p) async => {
          'items': [
            {
              'kind': 'user',
              'id': 'hist-cs-1-u1',
              'text': '你好',
              'createdAt': 1,
            },
          ],
          'nextBeforeLine': p['beforeLine'] == null ? 42 : null,
        };

    final first = await api.sessionHistory(claudeSessionId: 'cs-1', cwd: '/w');
    expect(caller.calls.single.$1, 'session.history');
    expect(caller.calls.single.$2, {
      'claudeSessionId': 'cs-1',
      'cwd': '/w',
    }, reason: '首页不携带 beforeLine/limit（daemon 默认 100）');
    expect(first.items.single.text, '你好');
    expect(first.nextBeforeLine, 42);
    expect(first.hasMore, isTrue);

    final older = await api.sessionHistory(
      claudeSessionId: 'cs-1',
      cwd: '/w',
      beforeLine: 42,
      limit: 50,
    );
    expect(caller.calls.last.$1, 'session.history');
    expect(caller.calls.last.$2, {
      'claudeSessionId': 'cs-1',
      'cwd': '/w',
      'beforeLine': 42,
      'limit': 50,
    });
    expect(older.nextBeforeLine, isNull, reason: '取尽后 cursor 为 null');
    expect(older.hasMore, isFalse);
  });

  test('session.import：三个参数；title 缺省不传', () async {
    caller.results['session.import'] = (_) async => {
          'summary': {
            'id': 's-new',
            'title': '接管的会话',
            'cwd': '/w',
            'phase': 'idle',
            'createdAt': 1,
            'updatedAt': 2,
            'claudeSessionId': 'cs-1',
            'model': null,
            'permissionMode': 'default',
            'origin': 'imported',
          },
        };

    final summary = await api.importSession(
      claudeSessionId: 'cs-1',
      cwd: '/w',
      title: '修一下构建',
    );
    expect(caller.calls.single.$1, 'session.import');
    expect(caller.calls.single.$2, {
      'claudeSessionId': 'cs-1',
      'cwd': '/w',
      'title': '修一下构建',
    });
    expect(summary.id, 's-new');
    expect(summary.imported, isTrue, reason: '导入会话带 origin: imported');

    await api.importSession(claudeSessionId: 'cs-1', cwd: '/w');
    expect(caller.calls.last.$2.containsKey('title'), isFalse,
        reason: 'title 缺省时不出现在 params');
  });
}
