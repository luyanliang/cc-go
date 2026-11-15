/// 会话空态（chat-visual-system）：时段问候 + 副标题 + 建议卡片。
/// 点击建议卡片把提示词填入输入框（不直接发送——由用户确认后发出）。
/// 与加载态（转圈）形态不同，一眼可区分。
library;

import 'package:material_ui/material_ui.dart';

import 'widgets/whale_tail.dart';
import '../widgets/glass.dart';

/// 按当前时段返回问候语。
String greetingForHour(int hour) {
  if (hour >= 5 && hour < 11) return '早上好';
  if (hour >= 11 && hour < 13) return '中午好';
  if (hour >= 13 && hour < 18) return '下午好';
  if (hour >= 18 && hour < 23) return '晚上好';
  return '夜深了';
}

/// 空态建议：标题 + 一行说明，点击填入输入框。
class EmptySuggestion {
  const EmptySuggestion(this.title, this.hint, this.prompt, this.icon);

  final String title;
  final String hint;

  /// 填入输入框的提示词原文。
  final String prompt;
  final IconData icon;
}

const _defaultSuggestions = <EmptySuggestion>[
  EmptySuggestion('项目导览', '这个项目是做什么的', '介绍一下这个项目：结构、构建方式和主要模块。', Icons.map_outlined),
  EmptySuggestion('跑测试', '总结失败原因', '跑一遍测试，总结失败项与原因。', Icons.science_outlined),
  EmptySuggestion('最近改动', '回顾最近的工作', '最近有哪些改动？按提交概要总结。', Icons.history_outlined),
  EmptySuggestion('新任务', '从这里开始写需求', '帮我实现一个新功能：', Icons.add_circle_outline_outlined),
];

class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({super.key, this.onSuggestion, this.suggestions = _defaultSuggestions});

  /// 点击建议卡片回调（填入输入框）；null = 仅展示。
  final ValueChanged<String>? onSuggestion;
  final List<EmptySuggestion> suggestions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 鲸尾品牌图形（dsh 空态）：still 帧静置，主色着色。
          Center(
            child: WhaleTail(
              still: true,
              color: whaleColorFor(theme.brightness),
              height: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            greetingForHour(DateTime.now().hour),
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '让 Claude 在这台电脑上帮你做事',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            childAspectRatio: 3.2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final s in suggestions)
                _SuggestionCard(
                  suggestion: s,
                  onTap: onSuggestion == null ? null : () => onSuggestion!(s.prompt),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion, this.onTap});

  final EmptySuggestion suggestion;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            Icon(suggestion.icon,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(suggestion.title, style: theme.textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(suggestion.hint,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
