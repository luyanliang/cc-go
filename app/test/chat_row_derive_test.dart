/// task 3.1/3.2：行推导纯函数单测 —— 四种条目成行、幂等、主键稳定、
/// 权限卡切断序列、连续 ≥3 次工具调用成组。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cc_go/state/transcript.dart';
import 'package:cc_go/ui/chat/chat_row_model.dart';

TranscriptItem item(
  String id,
  ItemKind kind, {
  String status = '',
  String text = '',
}) =>
    TranscriptItem(
      id: id,
      kind: kind,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      status: status,
      text: text,
    );

TranscriptItem notice(String id, String level) => TranscriptItem(
      id: id,
      kind: ItemKind.notice,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      level: level,
      text: '提示',
    );

/// 行签名：主键 + 行类型（幂等与稳定性断言用）。
(String, Type) sig(ChatRow row) => (row.key, row.runtimeType);

void main() {
  test('四种条目各成行，排队消息附尾', () {
    final rows = deriveChatRows(items: [
      item('u1', ItemKind.user, text: 'hi'),
      item('a1', ItemKind.assistant, status: 'done'),
      item('t1', ItemKind.tool, status: 'done'),
      item('n1', ItemKind.notice),
    ], queuedTexts: ['queued-1']);
    expect(rows.map(sig).toList(), [
      ('u1', UserRow),
      ('a1', AssistantRow),
      ('t1', ToolRow),
      ('n1', NoticeRow),
      ('q0', QueuedRow),
    ]);
  });

  test('待授权工具条目推导为权限卡行', () {
    final rows = deriveChatRows(items: [
      item('t1', ItemKind.tool, status: 'awaiting-permission'),
    ]);
    expect(rows.single, isA<PermissionRow>());
    expect(rows.single.key, 't1');
  });

  test('幂等：同输入两次推导结果一致', () {
    final items = [
      item('u1', ItemKind.user),
      item('t1', ItemKind.tool, status: 'done'),
      item('t2', ItemKind.tool, status: 'done'),
      item('t3', ItemKind.tool, status: 'running'),
      item('a1', ItemKind.assistant, status: 'streaming'),
    ];
    final a = deriveChatRows(items: items, queuedTexts: ['x']);
    final b = deriveChatRows(items: items, queuedTexts: ['x']);
    expect(a.map(sig).toList(), b.map(sig).toList());
  });

  test('主键稳定：同 id 同状态的条目更新后行序列不变', () {
    final before = deriveChatRows(items: [
      item('u1', ItemKind.user, text: '旧'),
      item('a1', ItemKind.assistant, status: 'streaming', text: '半句'),
    ]);
    final after = deriveChatRows(items: [
      item('u1', ItemKind.user, text: '新'),
      item('a1', ItemKind.assistant, status: 'streaming', text: '半句续'),
    ]);
    expect(before.map(sig).toList(), after.map(sig).toList());
  });

  group('工具调用成组', () {
    test('连续 3 次收成一组，组键为组首条目 id', () {
      final rows = deriveChatRows(items: [
        item('t1', ItemKind.tool, status: 'done'),
        item('t2', ItemKind.tool, status: 'done'),
        item('t3', ItemKind.tool, status: 'done'),
      ]);
      expect(rows, hasLength(1));
      final group = rows.single as ToolGroupRow;
      expect(group.count, 3);
      expect(group.key, 'gt1');
    });

    test('2 次不成组，各成一行', () {
      final rows = deriveChatRows(items: [
        item('t1', ItemKind.tool, status: 'done'),
        item('t2', ItemKind.tool, status: 'done'),
      ]);
      expect(rows.map(sig).toList(), [
        ('t1', ToolRow),
        ('t2', ToolRow),
      ]);
    });

    test('4 次仍是一组', () {
      final rows = deriveChatRows(items: List.generate(
        4,
        (i) => item('t$i', ItemKind.tool, status: 'done'),
      ));
      expect(rows.single, isA<ToolGroupRow>());
      expect((rows.single as ToolGroupRow).count, 4);
    });

    test('其他条目打断序列：各自收敛成组', () {
      final rows = deriveChatRows(items: [
        item('t1', ItemKind.tool, status: 'done'),
        item('t2', ItemKind.tool, status: 'done'),
        item('t3', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'done'),
        item('t4', ItemKind.tool, status: 'done'),
        item('t5', ItemKind.tool, status: 'done'),
      ]);
      expect(rows.map(sig).toList(), [
        ('gt1', ToolGroupRow),
        ('a1', AssistantRow),
        ('t4', ToolRow),
        ('t5', ToolRow),
      ]);
    });

    test('权限卡切断成组：前段照常收敛', () {
      final rows = deriveChatRows(items: [
        item('t1', ItemKind.tool, status: 'done'),
        item('t2', ItemKind.tool, status: 'done'),
        item('t3', ItemKind.tool, status: 'awaiting-permission'),
        item('t4', ItemKind.tool, status: 'running'),
      ]);
      expect(rows.map(sig).toList(), [
        ('t1', ToolRow),
        ('t2', ToolRow),
        ('t3', PermissionRow),
        ('t4', ToolRow),
      ]);
    });
  });

  group('回合折叠（task 6.1/6.2）', () {
    test('正常完成轮：工具与中间消息收进折叠行，最终回答在外', () {
      final rows = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '问题'),
        item('m1', ItemKind.assistant, status: 'done', text: '我先看看'),
        item('t1', ItemKind.tool, status: 'done'),
        item('t2', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'done', text: '答案'),
      ]);
      expect(rows.map(sig).toList(), [
        ('u1', UserRow),
        ('tpm1', TurnFoldRow),
        ('a1', AssistantRow),
      ]);
      final fold = rows[1] as TurnFoldRow;
      expect(fold.toolCount, 2);
      expect(fold.messageCount, 1);
      expect(fold.finalAnswer.id, 'a1');
    });

    test('打断轮不折叠：denied 工具、出错工具或流式草稿', () {
      final denied = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '问题'),
        item('t1', ItemKind.tool, status: 'denied'),
        item('a1', ItemKind.assistant, status: 'done', text: '被截断的回答'),
      ]);
      expect(denied.whereType<TurnFoldRow>(), isEmpty, reason: 'denied → 不折叠');

      // 出错的工具调用即便后来恢复并给出回答，也不折叠（spec：出错的
      // 轮次不折叠，失败过程要保持可见）。
      final recovered = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '问题'),
        item('t1', ItemKind.tool, status: 'error'),
        item('t2', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'done', text: '恢复了'),
      ]);
      expect(recovered.whereType<TurnFoldRow>(), isEmpty, reason: 'error 工具 → 不折叠');

      final streaming = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '问题'),
        item('t1', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'streaming', text: '半截'),
      ]);
      expect(streaming.whereType<TurnFoldRow>(), isEmpty, reason: '流式草稿 → 不折叠');
      expect(streaming.map(sig).toList(), [
        ('u1', UserRow),
        ('t1', ToolRow),
        ('a1', AssistantRow),
      ]);
    });

    test('出错轮不折叠：error notice', () {
      final rows = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '问题'),
        item('t1', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'done', text: '部分回答'),
        notice('n1', 'error'),
      ]);
      expect(rows.whereType<TurnFoldRow>(), isEmpty);
    });

    test('无回答或无过程不折叠', () {
      final noAnswer = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '问题'),
        item('t1', ItemKind.tool, status: 'done'),
      ]);
      expect(noAnswer.whereType<TurnFoldRow>(), isEmpty, reason: '没有最终回答');

      final trivial = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '问题'),
        item('a1', ItemKind.assistant, status: 'done', text: '只有回答'),
      ]);
      expect(trivial.whereType<TurnFoldRow>(), isEmpty, reason: '没有可收的过程');
    });

    test('运行中插话切分：前段独立判定，运行段不折叠', () {
      final rows = deriveChatRows(items: [
        item('u1', ItemKind.user, text: '第一个问题'),
        item('t1', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'done', text: '第一段回答'),
        item('u2', ItemKind.user, text: '插话'),
        item('t2', ItemKind.tool, status: 'running'),
        item('a2', ItemKind.assistant, status: 'streaming', text: ''),
      ]);
      expect(rows.map(sig).toList(), [
        ('u1', UserRow),
        ('tpt1', TurnFoldRow),
        ('a1', AssistantRow),
        ('u2', UserRow),
        ('t2', ToolRow),
        ('a2', AssistantRow),
      ]);
    });

    test('foldTurns=false 时整体退回平铺（可摘除性）', () {
      final items = [
        item('u1', ItemKind.user, text: '问题'),
        item('t1', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'done', text: '答案'),
      ];
      final rows = deriveChatRows(items: items, foldTurns: false);
      expect(rows.map(sig).toList(), [
        ('u1', UserRow),
        ('t1', ToolRow),
        ('a1', AssistantRow),
      ]);
    });

    test('折叠路径同样幂等', () {
      final items = [
        item('u1', ItemKind.user, text: '问题'),
        item('t1', ItemKind.tool, status: 'done'),
        item('t2', ItemKind.tool, status: 'done'),
        item('t3', ItemKind.tool, status: 'done'),
        item('a1', ItemKind.assistant, status: 'done', text: '答案'),
      ];
      final a = deriveChatRows(items: items);
      final b = deriveChatRows(items: items);
      expect(a.map(sig).toList(), b.map(sig).toList());
      // 三连工具折进回合后不再单独成组。
      expect(a.whereType<ToolGroupRow>(), isEmpty);
    });
  });
}
