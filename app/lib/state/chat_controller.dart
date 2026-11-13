/// 每会话聊天控制器（task 6.1/6.3/6.4）：订阅该会话的 session 事件流，
/// 维护转录状态；发送（空闲新轮 / 运行中排队显示）、打断。
library;

import 'dart:async';

import 'session_models.dart';
import 'transcript.dart';
import '../transport/host_link.dart';
import '../transport/reconnecting_link.dart';

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

  final List<String> _queuedTexts = [];
  List<String> get queuedTexts => List.unmodifiable(_queuedTexts);

  bool _busy = false;
  bool get busy => _busy;

  bool get running => _transcript.phase == SessionPhase.running;

  void dispose() {
    unawaited(_eventsSub?.cancel());
    unawaited(_changes.close());
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
    }
    _notify();
  }

  /// 发送：空闲直接开新轮；运行中仅入队显示（不打扰当前轮）。
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || link == null || _busy) return;
    if (running) {
      _queuedTexts.add(trimmed);
      _notify();
      return;
    }
    _busy = true;
    _notify();
    try {
      await _prompt(trimmed);
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 逐条送出（每次 idle 边沿只送一条，保持"停止即停"的控制感）。
  Future<void> _dispatchNextQueued() async {
    if (_busy || _queuedTexts.isEmpty || link == null) return;
    final text = _queuedTexts.first;
    _busy = true;
    _notify();
    try {
      await _prompt(text);
      _queuedTexts.remove(text); // daemon 已接受，user 条目随后到达
    } on Object {
      // 保留在队列里，等下一个 idle 边沿重试
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _prompt(String text) {
    return link!.call('session.prompt', {
      'sessionId': sessionId,
      'text': text,
      'mode': 'queue',
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
  }

  /// 清空本地排队显示（打断后 daemon 丢弃队列，快照不会含它们）。
  void clearQueued() {
    if (_queuedTexts.isEmpty) return;
    _queuedTexts.clear();
    _notify();
  }
}
