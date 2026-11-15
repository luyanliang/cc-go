import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../theme/motion.dart';
import 'stream_row.dart';

/// 思考标签扫光（dsh-Go 同款节奏）：lead 600ms / sweep 1s / period 4s，
/// `ShaderMask` 三色线性渐变 `[muted, bright, muted]`，**同屏只扫一条**
/// （静态 `_owner` 抢占 —— 在计时器里接手，不在 build 里：停别人的控制
/// 器会标脏别人的子树）。
class ThinkingLabel extends StatefulWidget {
  const ThinkingLabel(this.text, {super.key, this.active = false});

  final String text;
  final bool active;

  static const lead = Duration(milliseconds: 600);
  static const sweep = Duration(seconds: 1);
  static const period = Duration(seconds: 4);

  @override
  State<ThinkingLabel> createState() => _ThinkingLabelState();
}

class _ThinkingLabelState extends State<ThinkingLabel>
    with SingleTickerProviderStateMixin {
  /// 现在归谁扫。
  static _ThinkingLabelState? _owner;

  AnimationController? _sweep;
  Timer? _timer;

  void _sync() {
    final run = widget.active && !AppMotion.reduced(context);
    if (run == (_timer != null)) return;
    if (run) {
      _sweep ??= AnimationController(vsync: this, duration: ThinkingLabel.sweep);
      _timer = Timer(ThinkingLabel.lead, () {
        _timer = Timer.periodic(ThinkingLabel.period, (_) => _play());
        _owner?._sweep?.reset();
        _owner = this;
        _play();
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _sweep?.reset();
      _release();
    }
  }

  void _play() {
    // 接手的那条结束了，轮到还在思考的这条。
    _owner ??= this;
    if (identical(_owner, this)) _sweep!.forward(from: 0);
  }

  void _release() {
    if (identical(_owner, this)) _owner = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ThinkingLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sweep?.dispose();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = StreamRow.label(context);
    final label = Text(widget.text, style: style);
    final sweep = _sweep;
    if (sweep == null || _timer == null) return label;
    final muted = style.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final bright = Theme.of(context).colorScheme.onSurface;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: sweep,
        child: label,
        builder: (context, child) {
          if (!sweep.isAnimating) return child!;
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            // 亮带和标签一样宽，从标签左外走到右外：两头都是静止时的颜色，
            // 起止不跳。
            shaderCallback: (rect) => LinearGradient(
                colors: [muted, bright, muted]).createShader(
                Rect.fromLTWH(
                    (2 * sweep.value - 1) * rect.width, 0, rect.width,
                    rect.height)),
            child: child,
          );
        },
      ),
    );
  }
}

/// 流式思考的实时窗口（dsh-Go 同款）：一段**连续的文字**，窗口恒高三行，
/// 写出来的字从底部进来，写满一行整段匀速往上滑一行。不拆行、不做逐行
/// 动效 —— 相邻两帧不会各画一份文字叠在一起。
///
/// 块高从头到尾不变：流式期间列表不会一行一行地追底，写得再快也不会抖。
/// 不足三行时文字贴在窗口顶上，后面空着，写满就自然开始往上走。
class ThinkingTicker extends StatelessWidget {
  const ThinkingTicker({super.key, required this.text});

  final String text;

  /// 窗口行数（TUI 的 PREVIEW_ROWS）。
  static const rows = 3;

  @override
  Widget build(BuildContext context) {
    final style = StreamRow.detail(context);
    final scaler = MediaQuery.textScalerOf(context);
    final lineHeight =
        scaler.scale(style.fontSize ?? 13) * (style.height ?? 1.3);
    final shown = thinkingTickerText(text);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // 量一遍：窗口高度取「内容高度」和「三行」的较小值。
        final painter = TextPainter(
          text: TextSpan(text: shown, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: width);
        final textHeight = painter.height;
        // 每次发布都量一遍：排版对象持有原生资源，不能等 GC。
        painter.dispose();
        final window = lineHeight * ThinkingTicker.rows;
        // 恒高三行：流式期间块高不变，列表就不会一行一行地追底。
        // 多出来的部分往上推，露出来的永远是最后三行。写满一行时目标只
        // 挪一行，由 AnimatedContainer 平滑推上去 —— 不换内容、不叠字。
        final shift = (textHeight - window).clamp(0.0, double.infinity);
        return SizedBox(
          width: width,
          height: window,
          child: ClipRect(
            child: AnimatedContainer(
              duration: AppMotion.of(context, AppMotion.quick),
              // 匀速上移：每次换行都重新给目标，缓动会在每一行开头重新
              // 缓起、结尾重新缓停，连起来就是一顿一顿的。
              curve: Curves.linear,
              transform: Matrix4.translationValues(0, -shift, 0),
              child: OverflowBox(
                alignment: AlignmentDirectional.topStart,
                minHeight: 0,
                maxHeight: double.infinity,
                child: SizedBox(
                  width: width,
                  child: Text(shown, style: style),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 实时窗口里显示的文字：去掉加粗标记、压掉空行、掐掉首尾空白。
///
/// 只留最后一段：更早的字在窗口外，不必参与排版（思考再长也不会拖慢每帧）。
String thinkingTickerText(String text) {
  var tail = text.trimRight();
  if (tail.length > _tickerChars) {
    tail = tail.substring(tail.length - _tickerChars);
  }
  return tail
      .replaceAll('**', '')
      .replaceAll(_blankRun, '\n')
      .trimLeft();
}

/// 尾部最多排这么多字。
const _tickerChars = 2000;

final _blankRun = RegExp('\n{2,}');
