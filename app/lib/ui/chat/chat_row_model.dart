/// 行推导模型（task 3.1/3.2）：条目列表 → 展示行的纯函数推导。纯 Dart、
/// 无 Flutter 依赖 —— 分组等结构决策全部在这层完成，widget 层只认行。
/// 结构思路借鉴 dsh-Go 的 deriveRows（只读参考，本项目独立实现）。
library;

import '../../state/transcript.dart';

/// 一条展示行。key 是稳定主键（列表 diff / 视口锚定用），派生自条目 id。
sealed class ChatRow {
  const ChatRow();

  String get key;
}

class UserRow extends ChatRow {
  const UserRow(this.item);

  final TranscriptItem item;

  @override
  String get key => item.id;
}

class AssistantRow extends ChatRow {
  const AssistantRow(this.item);

  final TranscriptItem item;

  @override
  String get key => item.id;
}

class NoticeRow extends ChatRow {
  const NoticeRow(this.item);

  final TranscriptItem item;

  @override
  String get key => item.id;
}

/// 待授权的工具条目（渲染为内联权限卡片）。它自成一行并切断成组序列：
/// 权限卡必须显眼，不能被折叠进组里。
class PermissionRow extends ChatRow {
  const PermissionRow(this.item);

  final TranscriptItem item;

  @override
  String get key => item.id;
}

class ToolRow extends ChatRow {
  const ToolRow(this.item);

  final TranscriptItem item;

  @override
  String get key => item.id;
}

/// 连续 [toolGroupThreshold] 次及以上工具调用收成一组。
class ToolGroupRow extends ChatRow {
  const ToolGroupRow(this.tools);

  final List<TranscriptItem> tools;

  @override
  String get key => 'g${tools.first.id}';

  int get count => tools.length;
}

/// 本机排队中的消息（item 之外，接在末尾）。
class QueuedRow extends ChatRow {
  const QueuedRow({required this.index, required this.text});

  final int index;
  final String text;

  @override
  String get key => 'q$index';
}

/// 回合折叠行（task 6.1/6.2）：一条用户消息之后的过程条目（工具调用与
/// 中间助手消息）收成一行，最终回答（[finalAnswer]）留在折叠行外面。
class TurnFoldRow extends ChatRow {
  const TurnFoldRow({required this.process, required this.finalAnswer});

  /// 收进折叠行的过程条目（保持原序）。
  final List<TranscriptItem> process;

  /// 留在外面的最终回答条目。
  final TranscriptItem finalAnswer;

  @override
  String get key => 'tp${process.first.id}';

  int get toolCount => process.where((t) => t.kind == ItemKind.tool).length;

  int get messageCount =>
      process.where((t) => t.kind == ItemKind.assistant && t.text.trim().isNotEmpty).length;
}

/// 回合折叠判定（design D4，从严）：一段 = 两条用户消息之间的条目。
/// 只有"明确正常完成"的段才折叠 —— 无 error 级 notice、无出错/denied/
/// 待授权/仍运行中的工具、最后一条条目是 `done` 且有正文的助手消息，
/// 且过程里有值得收起来的内容。任何歧义（流式草稿、无回答、只有一条
/// 中间消息）一律不折叠，返回 null。
TurnFoldRow? assessTurnFold(List<TranscriptItem> segment) {
  if (segment.isEmpty) return null;
  TranscriptItem? lastAssistant;
  for (final item in segment) {
    switch (item.kind) {
      case ItemKind.notice:
        if (item.level == 'error') return null;
      case ItemKind.tool:
        // denied = 打断/拒绝留下的痕迹；error = 出错的调用（spec：出错
        // 的轮次不折叠，即便 Claude 后来恢复并给出回答）；running /
        // awaiting-permission 与完成回答矛盾，一并视为歧义。
        if (item.status == 'denied' ||
            item.status == 'error' ||
            item.status == 'running' ||
            item.status == 'awaiting-permission') {
          return null;
        }
      case ItemKind.assistant:
        lastAssistant = item;
      case ItemKind.user:
        break; // 段内不应出现，防御性忽略
    }
  }
  final answer = lastAssistant;
  // 回答必须是段的最后一条条目（正常流的收尾形态），且已完成、有正文。
  if (answer == null || answer.status != 'done' || answer.text.trim().isEmpty) return null;
  if (!identical(segment.last, answer)) return null;

  final process = segment.take(segment.length - 1).toList(growable: false);
  final hasTool = process.any((t) => t.kind == ItemKind.tool);
  final messages =
      process.where((t) => t.kind == ItemKind.assistant && t.text.trim().isNotEmpty).length;
  // 没有工具调用且中间消息不足两条时，折叠只是把内容藏起来，不值。
  if (!hasTool && messages < 2) return null;
  return TurnFoldRow(process: process, finalAnswer: answer);
}

const toolGroupThreshold = 3;

/// 条目列表 → 行列表。行序即条目序；回合按用户消息分段，可折叠的段
/// （assessTurnFold）收成 TurnFoldRow + 最终回答；不可折叠的段内连续
/// ≥3 次工具调用（中间没有其他条目或权限卡）收成一组；排队消息依次
/// 附在末尾。纯函数：同输入必同输出。
List<ChatRow> deriveChatRows({
  required List<TranscriptItem> items,
  List<String> queuedTexts = const [],
  bool foldTurns = true,
}) {
  final rows = <ChatRow>[];
  var segment = <TranscriptItem>[];

  /// 把"不折叠"的段按条目原样成行（含工具成组与权限卡分发）。
  void emitFlat(List<TranscriptItem> items) {
    var run = <TranscriptItem>[];
    void flushRun() {
      if (run.isEmpty) return;
      if (run.length >= toolGroupThreshold) {
        rows.add(ToolGroupRow(List.unmodifiable(run)));
      } else {
        rows.addAll(run.map(ToolRow.new));
      }
      run = <TranscriptItem>[];
    }

    for (final item in items) {
      switch (item.kind) {
        case ItemKind.tool:
          if (item.status == 'awaiting-permission') {
            flushRun();
            rows.add(PermissionRow(item));
          } else {
            run.add(item);
          }
        case ItemKind.user:
          flushRun();
          rows.add(UserRow(item));
        case ItemKind.assistant:
          flushRun();
          rows.add(AssistantRow(item));
        case ItemKind.notice:
          flushRun();
          rows.add(NoticeRow(item));
      }
    }
    flushRun();
  }

  /// 收尾当前段：可折叠 → 折叠行 + 最终回答；否则原样成行。
  void emitSegment() {
    if (segment.isEmpty) return;
    final fold = foldTurns ? assessTurnFold(segment) : null;
    if (fold != null) {
      rows.add(fold);
      rows.add(AssistantRow(fold.finalAnswer));
    } else {
      emitFlat(segment);
    }
    segment = <TranscriptItem>[];
  }

  for (final item in items) {
    if (item.kind == ItemKind.user) {
      emitSegment();
      rows.add(UserRow(item));
    } else {
      segment.add(item);
    }
  }
  emitSegment();
  for (var i = 0; i < queuedTexts.length; i++) {
    rows.add(QueuedRow(index: i, text: queuedTexts[i]));
  }
  return rows;
}
