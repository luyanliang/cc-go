/// 工具定制视图（task 4.2/4.3）：按工具名注册视图构建器，未命中回退
/// 通用折叠行（调用方处理）。所有视图只从 `input`/`summary` 取数 ——
/// 将来协议扩展出原始 result 字段时只改各视图的取数处（design D6）。
library;

import 'package:material_ui/material_ui.dart';

import '../../state/transcript.dart';
import 'render/diff.dart';

/// 单工具展开内容视图的构建器；返回 null 表示"本条没有可画的内容"，
/// 调用方回退通用展示。
typedef ToolViewBuilder = Widget? Function(TranscriptItem item);

/// 工具名 → 展开内容视图。键用 Claude Code 的规范工具名。
final Map<String, ToolViewBuilder> _detailBuilders = {
  'Bash': buildBashToolView,
  'Read': buildReadToolView,
  'Write': buildWriteToolView,
  'Edit': buildEditToolView,
  'Grep': buildGrepToolView,
  'Glob': buildGlobToolView,
  'TodoWrite': buildTodoToolView,
};

/// 按条目实例缓存的 diff 结果（key = TranscriptItem）。条目被 item.updated
/// 整体替换时实例变化，缓存自然失效；同实例在流式期间反复重建时命中，
/// 不必每帧重算 LCS。
final _diffCache = Expando<List<DiffLine>>('toolDiff');

/// 工具名 → 折叠行副标题（一行概览）。未命中返回 null（调用方用 summary）。
final Map<String, String? Function(TranscriptItem)> _subtitleBuilders = {
  'Bash': (item) => _firstLine(item.toolInput?['command']),
  'Read': (item) => item.toolInput?['file_path'] as String?,
  'Write': (item) => item.toolInput?['file_path'] as String?,
  'Edit': (item) => item.toolInput?['file_path'] as String?,
  'Grep': (item) => _patternPath(item, 'pattern'),
  'Glob': (item) => _patternPath(item, 'pattern'),
};

/// 展开内容的定制视图；null = 回退通用展示（JSON 输入 + 结果摘要）。
Widget? toolDetailFor(TranscriptItem item) {
  final builder = _detailBuilders[item.toolName ?? ''];
  return builder?.call(item);
}

/// 折叠行副标题；null = 用 summary 或不显示。
String? toolSubtitleFor(TranscriptItem item) {
  final builder = _subtitleBuilders[item.toolName ?? ''];
  return builder?.call(item);
}

String? _firstLine(Object? value) {
  if (value is! String) return null;
  final line = value.split('\n').first;
  return line.isEmpty ? null : line;
}

String? _patternPath(TranscriptItem item, String patternKey) {
  final input = item.toolInput;
  if (input == null) return null;
  final pattern = input[patternKey];
  final path = input['path'];
  if (pattern is! String) return path is String ? path : null;
  return path is String ? '$path · $pattern' : pattern;
}

// ---------------------------------------------------------------------------
// 通用小件
// ---------------------------------------------------------------------------

/// 等宽内容块（命令 / 路径等键值对）。
class _MonoBlock extends StatelessWidget {
  const _MonoBlock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

/// 标签 + 值的紧凑行。
class _FieldRow extends StatelessWidget {
  const _FieldRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

// ---------------------------------------------------------------------------
// Bash
// ---------------------------------------------------------------------------

/// Bash：命令（等宽）+ 输出摘要。
Widget buildBashToolView(TranscriptItem item) {
  final command = item.toolInput?['command'];
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionLabel('命令'),
      _MonoBlock(command is String ? command : ''),
      if (item.summary != null && item.summary!.isNotEmpty) ...[
        const SizedBox(height: 6),
        const _SectionLabel('输出'),
        Text(item.summary!, style: const TextStyle(fontSize: 12)),
      ],
    ],
  );
}

// ---------------------------------------------------------------------------
// Read / Grep / Glob
// ---------------------------------------------------------------------------

/// Read：路径与读取窗口 + 内容摘要。
Widget buildReadToolView(TranscriptItem item) {
  final input = item.toolInput ?? const {};
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (input['file_path'] is String) _FieldRow('路径', input['file_path'] as String),
      if (input['offset'] != null) _FieldRow('起始行', '${input['offset']}'),
      if (input['limit'] != null) _FieldRow('行数', '${input['limit']}'),
      if (item.summary != null && item.summary!.isNotEmpty) ...[
        const SizedBox(height: 4),
        const _SectionLabel('内容'),
        Text(item.summary!, style: const TextStyle(fontSize: 12)),
      ],
    ],
  );
}

/// Grep：模式与范围 + 命中摘要。
Widget buildGrepToolView(TranscriptItem item) {
  final input = item.toolInput ?? const {};
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (input['pattern'] is String) _FieldRow('模式', input['pattern'] as String),
      if (input['path'] is String) _FieldRow('范围', input['path'] as String),
      if (input['output_mode'] is String) _FieldRow('输出', input['output_mode'] as String),
      if (item.summary != null && item.summary!.isNotEmpty) ...[
        const SizedBox(height: 4),
        const _SectionLabel('命中'),
        Text(item.summary!, style: const TextStyle(fontSize: 12)),
      ],
    ],
  );
}

/// Glob：模式与范围。
Widget buildGlobToolView(TranscriptItem item) {
  final input = item.toolInput ?? const {};
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (input['pattern'] is String) _FieldRow('模式', input['pattern'] as String),
      if (input['path'] is String) _FieldRow('范围', input['path'] as String),
      if (item.summary != null && item.summary!.isNotEmpty) ...[
        const SizedBox(height: 4),
        const _SectionLabel('结果'),
        Text(item.summary!, style: const TextStyle(fontSize: 12)),
      ],
    ],
  );
}

// ---------------------------------------------------------------------------
// Edit / Write（diff 视图）
// ---------------------------------------------------------------------------

/// diff 视图最多展示的行数，超出折叠为提示。
const kDiffViewMaxLines = 200;

/// diff 行着色渲染。
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.lines});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final shown = lines.length > kDiffViewMaxLines ? lines.sublist(0, kDiffViewMaxLines) : lines;
    final adds = lines.where((l) => l.kind == DiffLineKind.add).length;
    final removes = lines.where((l) => l.kind == DiffLineKind.remove).length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('+$adds −$removes', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          for (final line in shown)
            Text(
              '${line.kind == DiffLineKind.add ? '+' : line.kind == DiffLineKind.remove ? '−' : ' '} ${line.text}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: switch (line.kind) {
                  DiffLineKind.add => Colors.green.shade800,
                  DiffLineKind.remove => Colors.red.shade800,
                  DiffLineKind.same => Theme.of(context).colorScheme.onSurfaceVariant,
                },
              ),
            ),
          if (lines.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '… 另有 ${lines.length - shown.length} 行未展示',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// Edit：old_string/new_string 的行级 diff（按条目实例缓存）。
Widget buildEditToolView(TranscriptItem item) {
  final input = item.toolInput ?? const {};
  final oldString = input['old_string'];
  final newString = input['new_string'];
  final cached = _diffCache[item];
  final lines = cached ??
      diffLines(
        oldString is String ? oldString.split('\n') : const [],
        newString is String ? newString.split('\n') : const [],
      );
  if (cached == null) _diffCache[item] = lines;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (input['file_path'] is String) _FieldRow('路径', input['file_path'] as String),
      if (input['replace_all'] == true) const _FieldRow('替换', '全部匹配'),
      const SizedBox(height: 4),
      DiffView(lines: lines),
    ],
  );
}

/// Write：整文件内容按全新增渲染（新文件本身就是一次"从无到有"的
/// diff）。超长内容先截断 —— 不为只展示 200 行的大文件物化十万行对象。
Widget buildWriteToolView(TranscriptItem item) {
  final input = item.toolInput ?? const {};
  final content = input['content'];
  final allLines =
      content is String ? content.split('\n') : const <String>[];
  final truncated = allLines.length > kDiffViewMaxLines;
  final shown = truncated ? allLines.sublist(0, kDiffViewMaxLines) : allLines;
  final cached = _diffCache[item];
  final lines = cached ?? diffLines(const [], shown);
  if (cached == null) _diffCache[item] = lines;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (input['file_path'] is String) _FieldRow('路径', input['file_path'] as String),
      const SizedBox(height: 4),
      DiffView(lines: lines),
      if (truncated)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '… 内容超长，仅显示前 200 行',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// TodoWrite
// ---------------------------------------------------------------------------

/// TodoWrite：待办清单（完成/进行中/待办三种状态图标）。输入畸形
/// （todos 缺失/非列表/无有效条目）时返回 null，走通用 JSON 回退 ——
/// 空白展开比原始输入更没用。
Widget? buildTodoToolView(TranscriptItem item) {
  final rawTodos = item.toolInput?['todos'];
  final todos = rawTodos is List ? rawTodos : const [];
  final rows = <Widget>[];
  for (final raw in todos) {
    if (raw is! Map) continue;
    final content = raw['content'];
    if (content is! String) continue;
    final status = raw['status'];
    final (icon, color) = switch (status) {
      'completed' => (Icons.check_circle, Colors.green),
      'in_progress' => (Icons.play_circle, Colors.blue),
      _ => (Icons.radio_button_unchecked, Colors.grey),
    };
    rows.add(Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              content,
              style: TextStyle(
                fontSize: 13,
                decoration: status == 'completed' ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    ));
  }
  if (rows.isEmpty) return null;
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
}
