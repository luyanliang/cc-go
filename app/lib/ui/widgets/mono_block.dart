/// 等宽内容块容器：统一“surfaceContainerHighest 半透明底 + 圆角 8 +
/// padding 8”的配方（此前权限卡/工具行/工具视图 3 处逐字复制）。
/// 内容给 [text]（可选中的等宽文本）或 [child]（diff 列表、滚动输出
/// 等自定义内容）。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/app_style.dart';

class MonoBlock extends StatelessWidget {
  const MonoBlock({super.key, this.text, this.child, this.constraints})
      : assert((text == null) != (child == null), 'text 与 child 二选一');

  const MonoBlock.text(String this.text, {super.key, this.constraints})
      : child = null;

  final String? text;

  final Widget? child;

  /// 可选尺寸约束（如 ANSI 输出限高滚动 maxHeight: 320）。
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: constraints,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child ?? SelectableText(text!, style: AppMono.dense),
    );
  }
}
