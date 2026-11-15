/// 小圆角标签（pill）：统一“弱底色 + labelSmall + 圆角 8 + padding
/// 8/2”的小徽标。此前 5 处各自手写（padding/圆角/底色各异），现都走
/// 这里：来源标识、已托管、用量、模型、失效目录标记。
library;

import 'package:material_ui/material_ui.dart';

class PillBadge extends StatelessWidget {
  /// 默认徽标：secondaryContainer 底。
  const PillBadge(this.label, {super.key, this.icon})
      : color = null,
        onColor = null,
        capsule = false;

  /// 自定底色徽标：`color`/`onColor` 成对给（如 primaryContainer +
  /// onPrimaryContainer、disabledColor 淡底 + disabledColor 文字）。
  const PillBadge.tinted(
    this.label, {
    super.key,
    required this.color,
    required this.onColor,
    this.icon,
  }) : capsule = false;

  /// 胶囊变体：全圆角（Stadium）、加大 padding —— 顶栏模型 chip、
  /// 权限胶囊等"一眼是一枚胶囊"的场合（视觉纪律与 GlassPill 同族，
  /// 但不挂模糊、铺语义色底）。
  const PillBadge.capsule(
    this.label, {
    super.key,
    this.icon,
    this.color,
    this.onColor,
  }) : capsule = true;

  final String label;

  /// null = secondaryContainer。
  final Color? color;

  /// 文字与图标的颜色；null = onSecondaryContainer。
  final Color? onColor;

  /// 可选尾随图标（如模型 chip 的下拉箭头）。
  final IconData? icon;

  /// 胶囊形态（全圆角 + 大 padding）；false = 默认小徽标（圆角 8）。
  final bool capsule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = onColor ?? scheme.onSecondaryContainer;
    return Container(
      padding: capsule
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color ?? scheme.secondaryContainer,
        borderRadius: capsule
            ? BorderRadius.circular(999)
            : BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Flexible + ellipsis：被外层 ConstrainedBox 收紧时文字省略
          // （如顶栏模型胶囊的截短等级），小徽标场景不受影响。
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: on),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (icon != null) Icon(icon, size: 16, color: on),
        ],
      ),
    );
  }
}
