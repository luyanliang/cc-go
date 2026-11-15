/// 玻璃胶囊顶栏（chat-visual-system）：会话键 + 标题胶囊 + 模型胶囊 +
/// 新对话键 —— 不再是整条 AppBar 色带。空间不够时按固定顺序逐级让出
/// （宽度协商，见 [planHeaderSpace]）：先收用量 chip、再让标题截短
/// （ellipsis 连续收缩）、再截模型名；模型入口与新对话键任何一级都保留。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/session_models.dart';
import '../../state/sessions.dart';
import '../theme/app_style.dart';
import '../widgets/glass.dart';
import '../widgets/pill_badge.dart';
import '../widgets/status_dot.dart';
import 'chat_screen.dart';
import 'usage_chip.dart';

/// 让出等级：full（全展示）→ hideUsage（用量 chip 收起）→ shrinkModel
/// （模型名截短到下限）。标题截短不走独立等级 —— 标题永远 Flexible +
/// ellipsis，空间一紧就连续收缩，正对应"标题先于模型名让出"。
enum HeaderSpaceStep { full, hideUsage, shrinkModel }

/// 协商结果。
class HeaderSpacePlan {
  const HeaderSpacePlan({required this.step, this.maxModelWidth});

  final HeaderSpaceStep step;

  /// 模型胶囊文字最大宽度；null = 自然宽度（不截）。
  final double? maxModelWidth;
}

/// 宽度协商纯函数：给定可用宽与各段自然宽，输出让出等级。
/// 固定件（两颗功能键 + 间距）与标题下限在任何等级都保留。
HeaderSpacePlan planHeaderSpace({
  required double maxWidth,
  required double titleWidth,
  required double modelWidth,
  required double usageWidth,
  required double fixedWidth,
  required double minTitleWidth,
}) {
  final free = maxWidth - fixedWidth;
  final titleCapsulePad = 24.0; // 标题胶囊左右 padding
  final modelCapsulePad = 24.0 + 16.0; // 模型胶囊 padding + 下拉箭头

  if (free >= titleWidth + titleCapsulePad + modelWidth + modelCapsulePad + usageWidth) {
    return const HeaderSpacePlan(step: HeaderSpaceStep.full);
  }
  // 收用量 chip 后放得下完整标题与模型名。
  if (free >= titleWidth + titleCapsulePad + modelWidth + modelCapsulePad) {
    return const HeaderSpacePlan(step: HeaderSpaceStep.hideUsage);
  }
  // 标题（Flexible 截短）+ 完整模型名。
  if (free >= minTitleWidth + titleCapsulePad + modelWidth + modelCapsulePad) {
    return const HeaderSpacePlan(step: HeaderSpaceStep.hideUsage);
  }
  // 模型名也要截：模型胶囊留"图标 + 省略号"下限。
  final modelMin = 40.0 + modelCapsulePad;
  final modelMax = (free - minTitleWidth - titleCapsulePad)
      .clamp(modelMin, modelWidth + modelCapsulePad);
  return HeaderSpacePlan(
      step: HeaderSpaceStep.shrinkModel, maxModelWidth: modelMax);
}

double _textWidth(String text, TextStyle? style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  return tp.width;
}

/// 玻璃胶囊顶栏。会话/模型操作由外部注入（导航与 provider 装配留在
/// ChatScreen），本 widget 只管形态与协商。
class ChatHeader extends ConsumerStatefulWidget {
  const ChatHeader({
    required this.title,
    required this.phase,
    required this.summary,
    required this.onPickModel,
    super.key,
  });

  final String title;
  final SessionPhase phase;
  final SessionSummary? summary;

  /// 打开模型选择弹层（装配在 ChatScreen）。
  final VoidCallback onPickModel;

  @override
  ConsumerState<ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends ConsumerState<ChatHeader> {
  Future<void> _createSession() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final summary = await ref.read(sessionsProvider.notifier).create();
      if (!mounted) return;
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(sessionId: summary.id, title: summary.title),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('新建失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usage = widget.summary?.usage;
    final model = widget.summary?.model;

    return LayoutBuilder(builder: (context, constraints) {
      final titleStyle =
          theme.textTheme.titleMedium ?? const TextStyle(fontSize: 16);
      final modelStyle = theme.textTheme.labelMedium;
      final plan = planHeaderSpace(
        maxWidth: constraints.maxWidth,
        titleWidth: _textWidth(widget.title, titleStyle),
        modelWidth: _textWidth(model ?? '模型', modelStyle),
        usageWidth: usage == null ? 0 : 72, // UsageChip 估宽（成本 + ctx）
        fixedWidth: 40 + 40 + 12 * 3, // 两颗键 + 三段间距
        minTitleWidth: 72,
      );

      return Row(
        children: [
          _HeaderKey(
            icon: Icons.arrow_back_ios_new,
            tooltip: '返回',
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 12),
          // 标题胶囊：标题 +（用量 chip）在第一行，状态行在第二行。
          Expanded(
            child: GlassPill(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          style: titleStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (usage != null && plan.step == HeaderSpaceStep.full) ...[
                        const SizedBox(width: 6),
                        UsageChip(usage: usage),
                      ],
                    ],
                  ),
                  // 状态行（2.2）：状态点 + 一句人话，颜色不单独表达状态。
                  Row(
                    children: [
                      StatusDot(_phaseStatus(widget.phase), size: 6),
                      const SizedBox(width: 4),
                      Text(
                        switch (widget.phase) {
                          SessionPhase.idle => '已就绪',
                          SessionPhase.running => '生成中',
                          SessionPhase.awaitingPermission => '等待权限',
                        },
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 模型胶囊：点击打开选择面板；shrinkModel 等级截短到计划宽度。
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: widget.onPickModel,
            child: plan.maxModelWidth == null
                ? PillBadge.capsule(
                    model ?? '模型',
                    color: scheme.surfaceContainerHighest,
                    onColor: scheme.onSurface,
                    icon: Icons.arrow_drop_down,
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: plan.maxModelWidth! - 24),
                    child: PillBadge.capsule(
                      model ?? '模型',
                      color: scheme.surfaceContainerHighest,
                      onColor: scheme.onSurface,
                      icon: Icons.arrow_drop_down,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          // 新对话键：compose 铅笔字形（dsh 同款）。
          _HeaderKey(
              icon: Icons.edit_square, tooltip: '新对话', onTap: _createSession),
        ],
      );
    });
  }

  AppStatus _phaseStatus(SessionPhase phase) => switch (phase) {
        SessionPhase.idle => AppStatus.neutral,
        SessionPhase.running => AppStatus.active,
        SessionPhase.awaitingPermission => AppStatus.waiting,
      };
}

/// 40dp 圆形功能键（返回 / 新对话）。
class _HeaderKey extends StatelessWidget {
  const _HeaderKey({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPill(
      padding: const EdgeInsets.all(8),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Icon(icon, size: 20, color: scheme.onSurface),
      ),
    );
  }
}
