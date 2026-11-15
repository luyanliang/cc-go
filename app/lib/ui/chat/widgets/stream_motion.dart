import 'package:material_ui/material_ui.dart';

import '../../../theme/motion.dart';

/// 按压反馈：按下缩到 0.97，松手回到 1（不越过 1）。
///
/// 走手势竞技场里的点按识别（不是裸指针）：在列表里滑动时不会每次手指一
/// 碰就缩；里面的 InkWell、按钮更深，点按照常归它们，这里只跟着缩放。
class StreamPress extends StatefulWidget {
  const StreamPress({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<StreamPress> createState() => _StreamPressState();
}

class _StreamPressState extends State<StreamPress> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 只给反馈：点击归子件（无障碍也是）。
      excludeFromSemantics: true,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration:
            AppMotion.of(context, _down ? AppMotion.press : AppMotion.quick),
        curve: AppMotion.std,
        child: widget.child,
      ),
    );
  }
}

/// 第一次出现：淡入 + 上移 8，高度从 0 长到全高，只播一次；[index] 每项
/// 晚 30ms（最多 8 项）。[enabled] 为 false 时直接是终态。
///
/// 高度也跟着长：贴底跟随时，上面的内容随之平滑上移，而不是新行一出现
/// 整列"顿"地跳上去一截（卡片、整段回复尤其明显）。
///
/// [rise]：刚发出的气泡。灵动档下它从输入框方向弹着升起来，高度还是原来
/// 的节奏。
class StreamFadeIn extends StatefulWidget {
  const StreamFadeIn(
      {super.key,
      required this.child,
      this.enabled = true,
      this.index = 0,
      this.rise = false});

  final Widget child;
  final bool enabled;
  final int index;
  final bool rise;

  @override
  State<StreamFadeIn> createState() => _StreamFadeInState();
}

class _StreamFadeInState extends State<StreamFadeIn>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _t;

  /// 升起的进度，会超过 1；不升起时是 null，整棵树都不多这一层。
  Animation<double>? _lift;

  /// 气泡升起的距离，大约从输入框到列表底。
  static const _riseBy = 36.0;
  static const _riseScale = 0.94;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null || !widget.enabled || AppMotion.reduced(context)) {
      return;
    }
    final delay = Duration(milliseconds: 30 * widget.index.clamp(0, 7));
    final rise = widget.rise && AppMotion.fluid(context);
    final total =
        delay + (rise ? AppMotion.riseCurve.duration : AppMotion.standard);
    final controller = AnimationController(vsync: this, duration: total);
    _controller = controller;
    final start = delay.inMicroseconds / total.inMicroseconds;
    if (rise) {
      _lift = CurvedAnimation(
        parent: controller,
        curve: Interval(start, 1, curve: AppMotion.riseCurve),
      );
    }
    _t = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start,
        // 高度和透明度还是原来那么长，只有升起的弹簧走完全程。
        rise ? (delay + AppMotion.standard).inMicroseconds / total.inMicroseconds : 1,
        // 与输入条上胶囊的升降同一条曲线：新行长高、胶囊收回同时发生时
        // 内容只朝一个方向走，不会先顶上去再落回来。
        curve: AppMotion.std,
      ),
    );
    controller.forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) return widget.child;
    return AnimatedBuilder(
      animation: t,
      child: widget.child,
      builder: (context, child) {
        // 动画前后包同样的壳：换成裸 child 会重建行、丢状态（展开的工具
        // 行、气泡"发送中"的缓动）。静止时它们不画任何多余的东西。
        final v = t.value.clamp(0.0, 1.0);
        final lift = _lift?.value;
        return ClipRect(
          // 升起的气泡从下面露出来，不能被自己正在长高的行裁掉。
          clipBehavior: v < 1 && lift == null ? Clip.hardEdge : Clip.none,
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: v,
            // Align 放松了整行宽度；还回去，窄行（用户气泡）才不会漂到中间。
            child: SizedBox(
              width: double.infinity,
              child: Opacity(
                opacity: v,
                child: lift == null
                    ? Transform.translate(
                        offset: Offset(0, 8 * (1 - v)), child: child)
                    : Transform.translate(
                        offset: Offset(0, _riseBy * (1 - lift)),
                        child: Transform.scale(
                          scale: _riseScale + (1 - _riseScale) * lift,
                          alignment: AlignmentDirectional.bottomEnd,
                          child: child,
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
