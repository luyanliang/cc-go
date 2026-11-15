import 'package:material_ui/material_ui.dart';

/// 没东西可动画时就地让路的 [AnimatedSize]。
///
/// "减少动画"开启时 `AppMotion.of` 发出 [Duration.zero]：零时长
/// `AnimatedSize` 会在自己的 performLayout 里同步跑完控制器、再弄脏自己，
/// 触发断言（"RenderAnimatedSize was mutated in its own performLayout"）。
/// 这里 [duration] 为零时直接摆放子件，尺寸一步到位。
class SmoothSize extends StatelessWidget {
  const SmoothSize({
    super.key,
    required this.duration,
    this.curve = Curves.linear,
    this.alignment = Alignment.center,
    this.clipBehavior = Clip.hardEdge,
    this.child,
  });

  final Duration duration;
  final Curve curve;
  final AlignmentGeometry alignment;
  final Clip clipBehavior;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (duration == Duration.zero) return child ?? const SizedBox.shrink();
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: alignment,
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}
