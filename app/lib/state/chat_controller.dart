/// 每会话聊天控制器（task 6.1/6.3/6.4）：订阅该会话的 session 事件流，
/// 维护转录状态；发送（空闲新轮 / 运行中排队显示）、打断。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'attachment.dart';
import 'session_models.dart';
import 'transcript.dart';
import '../transport/host_link.dart';
import '../transport/reconnecting_link.dart';

/// 斜杠指令条目（session.commands 下发；名称不带前导斜杠）。
class SlashCommand {
  const SlashCommand({required this.name, this.description});

  final String name;
  final String? description;
}

/// 纯 Dart 控制器（ChangeNotifier 属 Flutter，会拖 dart:ui 进 CLI 工具）。
/// UI 经 [changes] 流订阅重建；provider 装配在 chat_controller_provider.dart。
class ChatController {
  ChatController({required this.sessionId, required this.link}) {
    if (link != null) {
      _eventsSub = link!.events.listen(_onEvent);
      unawaited(link!.watch(sessionId)); // 快照经 wrapper 规范化成事件到达
    }
  }

  final String sessionId;
  final ReconnectingHostLink? link;
  StreamSubscription<DaemonEvent>? _eventsSub;

  final _changes = StreamController<void>.broadcast();

  /// 每次状态变化（转录/排队/busy）后发出一个信号。
  Stream<void> get changes => _changes.stream;

  TranscriptState _transcript = const TranscriptState();
  TranscriptState get transcript => _transcript;

  final List<_QueuedSend> _queued = [];
  List<String> get queuedTexts => List.unmodifiable(_queued.map((q) => q.text));

  bool _busy = false;
  bool get busy => _busy;

  bool get running => _transcript.phase == SessionPhase.running;

  /// 外部填入草稿的通道（空态建议卡片、引用追问等）：Composer 监听并
  /// 取走文本；null 表示无待填内容。
  final ValueNotifier<String?> draftFill = ValueNotifier<String?>(null);

  /// 请求把 [text] 填进输入框（不直接发送）。
  void fillDraft(String text) => draftFill.value = text;

  /// 引用追问的引文（chat-message-interactions）：非 null 时输入区显示
  /// 引用胶囊，随下一次发送以 blockquote 前缀并入并清除。
  final ValueNotifier<String?> quoteText = ValueNotifier<String?>(null);

  void setQuote(String text) => quoteText.value = text;

  void clearQuote() => quoteText.value = null;

  /// 撤回排队消息（仅未送出条目；已送出的不在队列里）。
  void removeQueuedAt(int index) {
    if (index < 0 || index >= _queued.length) return;
    _queued.removeAt(index);
    _notify();
  }

  /// 编辑排队消息后重发（替换队列原文）。
  void editQueuedAt(int index, String text) {
    if (index < 0 || index >= _queued.length) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final old = _queued[index];
    _queued[index] = _QueuedSend(trimmed, old.wire);
    _notify();
  }

  void dispose() {
    unawaited(_eventsSub?.cancel());
    unawaited(_changes.close());
    draftFill.dispose();
    quoteText.dispose();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _onEvent(DaemonEvent event) {
    if (event.type != 'session' || event.sessionId != sessionId) return;
    final nested = event.sessionEvent;
    if (nested == null) return;

    final wasRunning = _transcript.phase == SessionPhase.running;
    final next = _transcript.applySessionEvent(nested);
    if (identical(next, _transcript)) return;
    _transcript = next;

    // daemon 的 cancel() 不清它自己的队列——为满足"打断即停"（task 6.4），
    // 排队消息只存手机侧：phase running→idle 边沿时逐条送出。
    if (wasRunning && next.phase == SessionPhase.idle) {
      unawaited(_dispatchNextQueued());
      // 轮次结束 = 本轮 init 已发生：顺手刷新指令目录（新技能可能出现）。
      unawaited(loadSlashCommands());
    }
    _notify();
  }

  /// 发送：空闲直接开新轮；运行中仅入队显示（不打扰当前轮）。
  /// 附件（若有）与文本同条消息送出。
  Future<void> send(String text, {List<PendingAttachment> attachments = const []}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || link == null || _busy) return;
    final wire = [for (final a in attachments.take(kAttachmentMaxCount)) a.toWire()];
    if (running) {
      _queued.add(_QueuedSend(trimmed, wire));
      _notify();
      return;
    }
    _busy = true;
    _notify();
    try {
      await _prompt(trimmed, wire);
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 逐条送出（每次 idle 边沿只送一条，保持"停止即停"的控制感）。
  Future<void> _dispatchNextQueued() async {
    if (_busy || _queued.isEmpty || link == null) return;
    final next = _queued.first;
    _busy = true;
    _notify();
    try {
      await _prompt(next.text, next.wire);
      _queued.removeAt(0); // daemon 已接受，user 条目随后到达
    } on Object {
      // 保留在队列里，等下一个 idle 边沿重试
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _prompt(String text, [List<Map<String, dynamic>> attachments = const []]) {
    return link!.call('session.prompt', {
      'sessionId': sessionId,
      'text': text,
      'mode': 'queue',
      if (attachments.isNotEmpty) 'attachments': attachments,
    });
  }

  /// 打断当前轮（未决权限由 daemon 一并拒绝）。先清本地排队显示——
  /// 用户意图是立即停止；RPC 失败（掉线）不上抛，离线状态另有呈现。
  Future<void> cancel() async {
    clearQueued();
    if (link == null) return;
    try {
      await link!.call('session.cancel', {'sessionId': sessionId});
    } on Object {
      // 掉线时打断送不出去；重连后 phase 快照会带回真实状态。
    }
  }

  /// 斜杠指令目录（session.commands：init 捕获、终端专属已过滤）。
  /// 打开会话时取一次；daemon 侧随每次 init 保持新鲜。
  List<SlashCommand> _slashCommands = const [];
  List<SlashCommand> get slashCommands => _slashCommands;

  Future<void> loadSlashCommands() async {
    if (link == null) return;
    try {
      final raw = await link!.call('session.commands', {'sessionId': sessionId})
          as Map<String, dynamic>;
      _slashCommands = [
        for (final c in (raw['commands'] as List<dynamic>? ?? <dynamic>[]))
          if (c is Map<String, dynamic> && c['name'] is String)
            SlashCommand(
              name: c['name'] as String,
              description: c['description'] as String?,
            ),
      ];
    } on Object {
      _slashCommands = const []; // 旧 daemon：不出面板
    }
    _notify();
  }

  /// 拉取模型目录（host.models：缓存 → 活查询 → 探测 → 空）。
  Future<Map<String, dynamic>> models() async {
    if (link == null) return {'models': <dynamic>[], 'current': null};
    return await link!.call('host.models', {}) as Map<String, dynamic>;
  }

  /// 切换模型（经既有 session.configure，摘要随后回显）。
  Future<void> configureModel(String model) async {
    if (link == null) return;
    await link!.call('session.configure', {
      'sessionId': sessionId,
      'model': model,
    });
  }

  /// 应答权限请求（task 7.1）：允许/拒绝，可勾选本会话同类工具免问。
  /// 应答后 daemon 更新工具条目状态，卡片自动转为最终状态工具行。
  Future<void> respondPermission(
    String itemId,
    bool allow, {
    bool allowToolForSession = false,
  }) async {
    if (link == null) return;
    await link!.call('permission.respond', {
      'sessionId': sessionId,
      'itemId': itemId,
      'allow': allow,
      'allowToolForSession': allowToolForSession,
    });
    // 免问成功 → 客户端记录（自动允许胶囊的状态展示；撤销需 daemon
    // 撤销协议，不在本 change 范围——见 proposal 不做清单）。
    if (allow && allowToolForSession) {
      final item = _transcript.items
          .where((i) => i.id == itemId && i.kind == ItemKind.tool)
          .firstOrNull;
      final tool = item?.toolName;
      if (tool != null && tool.isNotEmpty && !_sessionAllowedTools.contains(tool)) {
        _sessionAllowedTools.add(tool);
        _notify();
      }
    }
  }

  /// 本会话已勾选免问的工具类别（客户端镜像，仅作状态展示）。
  final Set<String> _sessionAllowedTools = {};
  Set<String> get sessionAllowedTools => Set.unmodifiable(_sessionAllowedTools);

  /// 清空本地排队显示（打断后 daemon 丢弃队列，快照不会含它们）。
  void clearQueued() {
    if (_queued.isEmpty) return;
    _queued.clear();
    _notify();
  }
}

/// 运行中排队的完整发送（文本 + 附件载荷），单一记录防两个平行列表失步。
class _QueuedSend {
  const _QueuedSend(this.text, this.wire);

  final String text;
  final List<Map<String, dynamic>> wire;
}
