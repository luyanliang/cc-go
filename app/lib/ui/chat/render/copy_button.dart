/// 复制按钮（task 1.3 + dsh 规格）：点按写入剪贴板，图标**原地交叉淡变**
/// 为对勾 1200ms。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class CopyIconButton extends StatefulWidget {
  const CopyIconButton({
    super.key,
    required this.text,
    this.tooltip = '复制',
    this.size = 16,
    this.color,
  });

  final String text;
  final String tooltip;
  final double size;
  final Color? color;

  @override
  State<CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<CopyIconButton> {
  bool _copied = false;
  Timer? _copiedReset;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return SizedBox(
      height: size + 18,
      width: size + 18,
      child: IconButton(
        tooltip: widget.tooltip,
        onPressed: _copy,
        padding: EdgeInsets.zero,
        // 图标原地交叉淡变（不换尺寸、不闪布局）。
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: Icon(
            _copied ? Icons.check : Icons.copy,
            key: ValueKey(_copied),
            size: size,
          ),
        ),
        color: widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
