/// 底部弹层标题头：统一 fromLTRB(16, 12, 16, 4) + titleMedium 的头部
/// （此前模型面板、目录选择两处逐字复制）。
library;

import 'package:material_ui/material_ui.dart';

class SheetHeader extends StatelessWidget {
  const SheetHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}
