/// 状态点：语义状态色的小圆点，配合文字使用 —— 颜色从不单独表达状态
/// （视觉纪律），调用方 MUST 同时展示状态文字，点只是"扫一眼定位"。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/app_style.dart';

class StatusDot extends StatelessWidget {
  const StatusDot(this.status, {super.key, this.size = 8});

  final AppStatus status;

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: status.color,
        shape: BoxShape.circle,
      ),
    );
  }
}
