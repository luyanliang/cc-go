/// multi-project-history 4.1：会话按 cwd 分组的归并逻辑（含 origin 标记、
/// 空分组、失效目录、未注册 cwd 兜底）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/project_models.dart';
import 'package:cc_go/state/session_models.dart';

SessionSummary _session(
  String id,
  String cwd, {
  SessionPhase phase = SessionPhase.idle,
  int updatedMinutesAgo = 5,
  String origin = 'created',
}) {
  final now = DateTime.now();
  return SessionSummary(
    id: id,
    title: '会话 $id',
    cwd: cwd,
    phase: phase,
    createdAt: now.subtract(const Duration(hours: 2)),
    updatedAt: now.subtract(Duration(minutes: updatedMinutesAgo)),
    origin: origin,
  );
}

ProjectInfo _project(String path, {bool available = true}) => ProjectInfo(
      path: path,
      name: dirBasename(path),
      available: available,
      sessionCount: 0,
    );

void main() {
  group('groupSessionsByProject', () {
    test('会话落入同 cwd 的项目组，组内待权限置顶 + 最近更新倒序', () {
      final groups = groupSessionsByProject(
        [_project('/w/a'), _project('/w/b')],
        [
          _session('a1', '/w/a', updatedMinutesAgo: 30),
          _session('a2', '/w/a', phase: SessionPhase.awaitingPermission, updatedMinutesAgo: 99),
          _session('b1', '/w/b', updatedMinutesAgo: 1),
        ],
      );
      final groupA = groups.singleWhere((g) => g.path == '/w/a');
      expect(groupA.sessions.map((s) => s.id), ['a2', 'a1'],
          reason: '待权限置顶，其余按更新倒序');
      final groupB = groups.singleWhere((g) => g.path == '/w/b');
      expect(groupB.sessions.single.id, 'b1');
    });

    test('空项目分组保留可见（spec：空项目呈现），垫后按名称排', () {
      final groups = groupSessionsByProject(
        [_project('/w/empty-zzz'), _project('/w/used')],
        [_session('u1', '/w/used')],
      );
      expect(groups, hasLength(2));
      expect(groups.first.path, '/w/used', reason: '有会话的组在前');
      expect(groups.last.path, '/w/empty-zzz');
      expect(groups.last.sessions, isEmpty);
    });

    test('未注册且无会话的兜底组隐藏（session-group-interactions）', () {
      final groups = groupSessionsByProject(
        [_project('/w/used')],
        [
          _session('u1', '/w/used'),
          _session('orphan1', '/w/orphan-with-sessions'),
        ],
      );
      // 未注册但有会话 → 保留；未注册且无会话 → 不产生该组。
      expect(groups.singleWhere((g) => g.name == 'orphan-with-sessions').sessions,
          isNotEmpty);
      expect(groups.where((g) => g.name == 'some-empty-orphan'), isEmpty);
      expect(groups.any((g) => !g.registered && g.sessions.isEmpty), isFalse,
          reason: '未注册空组不得出现在结果里');
    });

    test('失效项目照常成组，available=false 交给 UI 置灰', () {
      final groups = groupSessionsByProject(
        [_project('/gone', available: false)],
        [_session('g1', '/gone')],
      );
      expect(groups.single.available, isFalse);
      expect(groups.single.sessions.single.id, 'g1',
          reason: '失效目录的既有会话不丢');
    });

    test('未注册 cwd 的会话进兜底组，组名取 basename，不同 cwd 各一组', () {
      final groups = groupSessionsByProject(
        [_project('/w/known')],
        [
          _session('k1', '/w/known'),
          _session('o1', '/other/alpha'),
          _session('o2', '/other/alpha'),
          _session('o3', '/other/beta'),
        ],
      );
      final alpha = groups.singleWhere((g) => g.name == 'alpha');
      expect(alpha.registered, isFalse);
      expect(alpha.sessions.map((s) => s.id), unorderedEquals(['o1', 'o2']));
      expect(groups.any((g) => g.name == 'beta'), isTrue);
    });

    test('组间按组内最近活动倒序', () {
      final groups = groupSessionsByProject(
        [_project('/w/old'), _project('/w/new')],
        [
          _session('old1', '/w/old', updatedMinutesAgo: 120),
          _session('new1', '/w/new', updatedMinutesAgo: 3),
        ],
      );
      expect(groups.map((g) => g.path), ['/w/new', '/w/old']);
    });

    test('导入会话保留在分组中且 origin 标记随会话携带（UI 据此显示来源）', () {
      final groups = groupSessionsByProject(
        [_project('/w/a')],
        [
          _session('c1', '/w/a', origin: 'created'),
          _session('i1', '/w/a', origin: 'imported'),
        ],
      );
      final sessions = groups.single.sessions;
      expect(
        sessions.where((s) => s.imported).map((s) => s.id),
        ['i1'],
        reason: 'imported 标记区分来源，归并不改动它',
      );
    });
  });

  group('dirBasename', () {
    test('常规/尾斜杠/根路径', () {
      expect(dirBasename('/home/luke/work/cc-go'), 'cc-go');
      expect(dirBasename('/home/luke/work/cc-go/'), 'cc-go');
      expect(dirBasename('/'), '');
      expect(dirBasename('rel'), 'rel');
    });
  });

  group('DiscoveredSession.fromJson', () {
    test('缺省字段的宽容解析（managed/ccGoSessionId 可缺省）', () {
      final s = DiscoveredSession.fromJson({
        'claudeSessionId': 'cs',
        'title': '标题',
        'lastActiveAt': 5,
        'messageCount': 1,
      });
      expect(s.managed, isFalse);
      expect(s.ccGoSessionId, isNull);
    });
  });
}
