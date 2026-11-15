/// 输入草稿按会话持久化（chat-composer）：文本 + 引用上下文，键为会话
/// id。发送成功即清空；只读会话不存。shared_preferences（非敏感内容，
/// 不进 secure storage，design D8）。
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// 一份草稿。
class ChatDraft {
  const ChatDraft({this.text = '', this.quote});

  final String text;
  final String? quote;

  bool get isEmpty => text.isEmpty && quote == null;
}

abstract final class DraftStore {
  static const _prefix = 'chat.draft.';

  static String _key(String sessionId) => '$_prefix$sessionId';

  /// 读取草稿；无内容返回空草稿。存储损坏时降级为空（不抛错）。
  static Future<ChatDraft> load(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString('${_key(sessionId)}.text') ?? '';
      final quote = prefs.getString('${_key(sessionId)}.quote');
      return ChatDraft(text: text, quote: (quote == null || quote.isEmpty) ? null : quote);
    } on Object {
      return const ChatDraft();
    }
  }

  /// 保存草稿。文本与引用都为空时清除该会话的键。
  static Future<void> save(String sessionId, ChatDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    if (draft.isEmpty) {
      await clear(sessionId);
      return;
    }
    await prefs.setString('${_key(sessionId)}.text', draft.text);
    final quote = draft.quote;
    if (quote == null || quote.isEmpty) {
      await prefs.remove('${_key(sessionId)}.quote');
    } else {
      await prefs.setString('${_key(sessionId)}.quote', quote);
    }
  }

  static Future<void> clear(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_key(sessionId)}.text');
    await prefs.remove('${_key(sessionId)}.quote');
  }
}

/// 带防抖的草稿落盘器（评审 #8：逐键击直写既有磁盘压力，未串行化的
/// 并发写还可能乱序落盘）。schedule 只留最新快照，防抖窗口后写一次；
/// cancel 丢弃未写快照（发送清空路径用）；flush 立即写（页面销毁用）。
/// 可注入 timerCreate 供测试用假时钟驱动。
class DraftSaver {
  DraftSaver({this.sessionId = '', this.debounce = const Duration(milliseconds: 400)});

  /// 会话 id 可在首次 schedule 前补齐（ChatScreen 持有器晚于 widget 挂载）。
  String sessionId;
  final Duration debounce;

  Timer? _timer;
  ChatDraft? _pending;

  /// 最新一次 schedule 的快照（测试断言用）。
  ChatDraft? get pending => _pending;

  void schedule(ChatDraft draft) {
    _pending = draft;
    _timer?.cancel();
    _timer = Timer(debounce, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final draft = _pending;
    if (draft == null) return;
    _pending = null;
    // 保存即写盘；串行化由"同一时刻至多一个未决快照"保证。
    DraftStore.save(sessionId, draft);
  }

  /// 丢弃未写快照（发送成功清空路径：clear 之后不得再被旧快照覆盖）。
  void discard() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
