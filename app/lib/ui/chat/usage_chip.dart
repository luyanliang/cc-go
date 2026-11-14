/// 会话用量/成本 chip（task 3.5）：聊天页头部展示累计成本与最近一次
/// 的上下文量级；无数据不渲染（由调用方判空）。
library;

import 'package:material_ui/material_ui.dart';

import '../../state/session_models.dart';
import '../widgets/pill_badge.dart';

/// '123' / '1.2k' / '43k' / '1.05m' —— 与上下文窗口报价同一套单位。
String formatTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1000 * 1000) {
    final k = n / 1000;
    return '${k >= 100 ? k.round() : k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
  }
  final m = n / (1000 * 1000);
  return '${m >= 10 ? m.round() : m.toStringAsFixed(2)}m';
}

String formatCost(double usd) {
  if (usd >= 1) return '\$${usd.toStringAsFixed(2)}';
  if (usd >= 0.01) return '\$${usd.toStringAsFixed(2)}';
  return '\$${usd.toStringAsFixed(3)}';
}

class UsageChip extends StatelessWidget {
  const UsageChip({super.key, required this.usage});

  final SessionUsage usage;

  @override
  Widget build(BuildContext context) {
    return PillBadge(
      '${formatCost(usage.costUsd)} · ${formatTokens(usage.contextTokens)} ctx',
    );
  }
}
