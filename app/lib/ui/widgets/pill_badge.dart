/// 小圆角标签（pill）：统一“弱底色 + labelSmall + 圆角 8 + padding
/// 8/2”的小徽标。此前 5 处各自手写（padding/圆角/底色各异），现都走
/// 这里：来源标识、已托管、用量、模型、失效目录标记。
library;

import 'package:material_ui/material_ui.dart';

class PillBadge extends StatelessWidget {
  /// 默认徽标：secondaryContainer 底。
  const PillBadge(this.label, {super.key, this.icon})
      : color = null,
        onColor = null;

  /// 自定底色徽标：`color`/`onColor` 成对给（如 primaryContainer +
  /// onPrimaryContainer、disabledColor 淡底 + disabledColor 文字）。
  const PillBadge.tinted(
    this.label, {
    super.key,
    required this.color,
    required this.onColor,
    this.icon,
  });

  final String label;

  /// null = secondaryContainer。
  final Color? color;

  /// 文字与图标的颜色；null = onSecondaryContainer。
  final Color? onColor;

  /// 可选尾随图标（如模型 chip 的下拉箭头）。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = onColor ?? scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color ?? scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: on)),
          if (icon != null) Icon(icon, size: 16, color: on),
        ],
      ),
    );
  }
}
