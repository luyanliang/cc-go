/// 转录模型与合并逻辑（task 6.1）：条目按 id 整体替换，快照与实时流
/// 合并且幂等（协议保证 item.updated 携带完整条目）。纯 Dart。
library;

import 'session_models.dart';

/// 用户消息携带的图片附件（transcript-data-protocol 2.4 回显用）。
class TranscriptAttachment {
  const TranscriptAttachment({
    required this.name,
    required this.mimeType,
    required this.dataBase64,
  });

  factory TranscriptAttachment.fromJson(Map<String, dynamic> json) => TranscriptAttachment(
        name: json['name'] as String? ?? 'image',
        mimeType: json['mimeType'] as String? ?? 'image/jpeg',
        dataBase64: json['dataBase64'] as String? ?? '',
      );

  final String name;
  final String mimeType;
  final String dataBase64;
}

/// 四种条目（protocol.ts 的 Item 判别联合）。用扁平字段 + kind 区分，
/// 而非 sealed union：条目来自 JSON 且总是被整体替换，扁平模型让
/// fromJson/缓存/widgets 都简单。
class TranscriptItem {
  const TranscriptItem({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.text = '',
    this.thinking = '',
    this.status = '',
    this.toolName,
    this.toolInput,
    this.summary,
    this.level = 'info',
    this.resultText,
    this.resultTruncated = false,
    this.resultImages = const [],
    this.attachments = const [],
  });

  factory TranscriptItem.fromJson(Map<String, dynamic> json) {
    return TranscriptItem(
      id: json['id'] as String,
      kind: switch (json['kind']) {
        'assistant' => ItemKind.assistant,
        'tool' => ItemKind.tool,
        'notice' => ItemKind.notice,
        _ => ItemKind.user,
      },
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num).toInt()),
      text: json['text'] as String? ?? '',
      thinking: json['thinking'] as String? ?? '',
      status: json['status'] as String? ?? '',
      toolName: json['name'] as String?,
      toolInput: json['input'] is Map<String, dynamic> ? json['input'] as Map<String, dynamic> : null,
      summary: json['summary'] as String?,
      level: json['level'] as String? ?? 'info',
      resultText: json['resultText'] as String?,
      resultTruncated: json['resultTruncated'] as bool? ?? false,
      resultImages: [
        if (json['resultImages'] is List)
          for (final raw in json['resultImages'] as List)
            if (raw is Map<String, dynamic>)
              TranscriptAttachment.fromJson(raw),
      ],
      attachments: [
        if (json['attachments'] is List)
          for (final raw in json['attachments'] as List)
            if (raw is Map<String, dynamic>)
              TranscriptAttachment.fromJson(raw),
      ],
    );
  }

  final String id;
  final ItemKind kind;
  final DateTime createdAt;

  /// user / assistant / notice 的正文。
  final String text;

  /// assistant 的思考段（暂不单独渲染，保留数据）。
  final String thinking;

  /// assistant: streaming|done；tool: running|awaiting-permission|done|error|denied。
  final String status;

  /// tool 条目的工具名。
  final String? toolName;
  final Map<String, dynamic>? toolInput;

  /// tool 条目的结果摘要。
  final String? summary;

  /// notice: info|warn|error。
  final String level;

  /// tool 条目的完整结果文本（3.2 升级渲染用）。
  final String? resultText;

  /// resultText 是否被截断。
  final bool resultTruncated;

  /// tool 结果携带的图片（dataBase64）。
  final List<TranscriptAttachment> resultImages;

  /// user 条目的附件。
  final List<TranscriptAttachment> attachments;

  bool get isStreamingAssistant =>
      kind == ItemKind.assistant && status == 'streaming';
}

enum ItemKind { user, assistant, tool, notice }

/// 快照里的待权限请求（权限卡片第 7 节用，先承载字段）。
class PendingPermission {
  const PendingPermission({required this.itemId, required this.name, required this.input});

  factory PendingPermission.fromJson(Map<String, dynamic> json) => PendingPermission(
        itemId: json['itemId'] as String,
        name: json['name'] as String,
        input: json['input'] as Map<String, dynamic>? ?? const {},
      );

  final String itemId;
  final String name;
  final Map<String, dynamic> input;
}

/// 一个会话的转录状态（条目 + 阶段 + 待权限）。
class TranscriptState {
  const TranscriptState({
    this.items = const [],
    this.phase = SessionPhase.idle,
    this.pendingPermission,
    this.loaded = false,
  });

  /// 解析 session 事件（ev: snapshot/item.added/item.updated/phase）。
  /// 幂等：同一事件重放结果不变；未知 id 的 updated 防御性追加。
  TranscriptState applySessionEvent(Map<String, dynamic> event) {
    switch (event['ev']) {
      case 'snapshot':
        final rawItems = (event['items'] as List<dynamic>? ?? const []);
        final byId = <String, TranscriptItem>{};
        for (final raw in rawItems) {
          final item = TranscriptItem.fromJson(raw as Map<String, dynamic>);
          byId[item.id] = item;
        }
        return TranscriptState(
          items: List.unmodifiable(byId.values),
          phase: parsePhase(event['phase']),
          pendingPermission: event['pendingPermission'] is Map
              ? PendingPermission.fromJson(event['pendingPermission'] as Map<String, dynamic>)
              : null,
          loaded: true,
        );
      case 'item.added':
      case 'item.updated':
        final item =
            TranscriptItem.fromJson((event['item'] as Map<String, dynamic>).cast<String, dynamic>());
        final byId = <String, TranscriptItem>{};
        for (final existing in items) {
          byId[existing.id] = existing;
        }
        byId[item.id] = item; // 整体替换；added 对既有 id 亦幂等
        return copyWith(items: List.unmodifiable(byId.values));
      case 'phase':
        return copyWith(phase: parsePhase(event['phase']));
      default:
        return this;
    }
  }

  final List<TranscriptItem> items;
  final SessionPhase phase;
  final PendingPermission? pendingPermission;

  /// 收到过快照（区分"加载中"与"真空转录"）。
  final bool loaded;

  TranscriptState copyWith({
    List<TranscriptItem>? items,
    SessionPhase? phase,
    PendingPermission? pendingPermission,
    bool? loaded,
    bool clearPending = false,
  }) {
    return TranscriptState(
      items: items ?? this.items,
      phase: phase ?? this.phase,
      pendingPermission:
          clearPending ? null : (pendingPermission ?? this.pendingPermission),
      loaded: loaded ?? this.loaded,
    );
  }
}

SessionPhase parsePhase(Object? raw) => switch (raw) {
      'running' => SessionPhase.running,
      'awaiting-permission' => SessionPhase.awaitingPermission,
      _ => SessionPhase.idle,
    };
