import 'package:material_ui/material_ui.dart';

/// 贴底跟随（dsh-Go 同款）：跟随中（且这一刻本来就停在末尾）内容高度
/// 一变，**在同一次布局里**把位置放到新的末尾 —— 帧后 postFrame 追底永远
/// 晚一帧，会看到一行旧内容再跳。拖动、惯性滚动中不插手。
class FollowPhysics extends ScrollPhysics {
  const FollowPhysics(this.follows, {super.parent});

  final bool Function() follows;

  @override
  FollowPhysics applyTo(ScrollPhysics? ancestor) =>
      FollowPhysics(follows, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    if (isScrolling || velocity != 0 || !follows()) return adjusted;
    // 上一帧之后可能刚追过底（帧后 jumpTo）：看当前位置，也看大的那个。
    final at = newPosition.pixels > oldPosition.pixels
        ? newPosition.pixels
        : oldPosition.pixels;
    if (oldPosition.maxScrollExtent - at > 1) return adjusted;
    return newPosition.maxScrollExtent;
  }
}
