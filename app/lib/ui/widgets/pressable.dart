// 概念源自 PiPilot (https://github.com/CikeSeven/pi_pilot), MIT,
// Copyright (c) 2026 CikeSeven（经 dsh-Go 间接引入）。

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/motion.dart';

/// 任意可点内容的按压反馈：按住缩到 [AppMotion.pressScale]（0.97）、松手
/// 回到 1（不越过），走能从任意状态掉头的按压弹簧。在可滚动内容里，按压
/// 会先等 [AppMotion.press] 再显现（滚动不闪路过的东西）；显现后至少停留
/// 同样时长（快速点击看得见）。
///
/// 两种用法：
///
/// - **自管点击**：传 [onTap] / [onLongPress]，自带轻触感反馈与按钮语义。
/// - **只给反馈**：两个都留 null，包住一个自己处理点击的子件（如
///   InkWell）。只监听裸指针，不进手势竞技场；指针滑过 touch slop（滚动）
///   即取消。
///
/// "减少动画"时缩放恒为 1。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = AppMotion.pressScale,
    this.haptic = true,
    this.enabled = true,
    this.semanticLabel,
    this.behavior = HitTestBehavior.deferToChild,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 按住时的缩放。
  final double scale;

  /// 点击时的轻触感反馈（仅 [onTap] 自管时）。
  final bool haptic;

  /// false：不缩放、不回调（子件仍绘制）。
  final bool enabled;

  /// [Pressable] 自管点击时，代替子件自身文本的语义读法。
  final String? semanticLabel;

  /// 只给反馈时哪些指针算数。
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  // 不设上界：灵动档松手可以越过静息值一点。
  late final AnimationController _press =
      AnimationController.unbounded(vsync: this);

  Offset? _downAt;

  /// 滚动内容里按压等待显现的计时。
  Timer? _delay;

  /// 按压已显现后强制停留的计时。
  Timer? _hold;
  bool _lifted = false;

  bool get _ownsTap => widget.onTap != null || widget.onLongPress != null;

  @override
  void didUpdateWidget(Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 按压中途被禁用：松手不再到达手势回调。
    if (oldWidget.enabled && !widget.enabled) _cancel();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _hold?.cancel();
    _press.dispose();
    super.dispose();
  }

  void _down([Offset? at]) {
    if (!widget.enabled || AppMotion.reduced(context)) return;
    _downAt = at;
    _lifted = false;
    _delay?.cancel();
    // 自管点击时，有滚动竞争的话 onTapDown 本来就在 kPressTimeout(100ms)
    // 之后才来（或滚动赢了一直不来）。
    if (at != null && Scrollable.maybeOf(context) != null) {
      _delay = Timer(AppMotion.press, _show);
    } else {
      _show();
    }
  }

  void _show() {
    _delay = null;
    _hold?.cancel();
    _hold = Timer(AppMotion.press, () {
      _hold = null;
      if (_lifted) _settle(0);
    });
    _settle(1);
  }

  /// 手指在点击位置抬起：即使太快没等到等待期，也要闪一下。
  void _up() {
    _downAt = null;
    if (_delay case final delay?) {
      delay.cancel();
      _show();
    }
    _lifted = true;
    if (_hold == null) _settle(0);
  }

  /// 滚动或系统接管了指针：不闪。
  void _cancel() {
    _downAt = null;
    _delay?.cancel();
    _delay = null;
    _hold?.cancel();
    _hold = null;
    _settle(0);
  }

  void _settle(double target) {
    if (_press.value == target && !_press.isAnimating) return;
    if (target == 0 && AppMotion.fluid(context)) {
      _press.animateWith(SpringSimulation(
        AppMotion.releaseSpring,
        _press.value,
        0,
        _press.velocity,
        snapToEnd: true,
        tolerance: const Tolerance(distance: 0.002, velocity: 0.02),
      ));
      return;
    }
    _press.animateWith(
        AppMotion.settle(AppMotion.pressSpring, _press.value, target, _press.velocity));
  }

  void _move(PointerMoveEvent event) {
    final at = _downAt;
    if (at == null) return;
    // 与上层滚动判定一致：Android 上明显小于 kTouchSlop。
    final slop =
        MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? kTouchSlop;
    if ((event.position - at).distance > slop) _cancel();
  }

  void _tap() {
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    // enabled 与否同一棵树，子件状态不丢。
    final child = ScaleTransition(
      scale: Tween(begin: 1.0, end: widget.scale).animate(_press),
      child: widget.child,
    );
    if (!_ownsTap) {
      return Listener(
        behavior: widget.behavior,
        onPointerDown: (e) => _down(e.position),
        onPointerMove: _move,
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _cancel(),
        child: child,
      );
    }
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      // 语义标签代替可见文本，而不是重复它。
      excludeSemantics: widget.semanticLabel != null,
      onTap: enabled && widget.onTap != null ? _tap : null,
      onLongPress: enabled ? widget.onLongPress : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (d) => _down() : null,
        onTapUp: enabled ? (_) => _up() : null,
        onTapCancel: enabled ? _cancel : null,
        onTap: enabled && widget.onTap != null ? _tap : null,
        onLongPress: enabled && widget.onLongPress != null
            ? () {
                _up();
                widget.onLongPress!();
              }
            : null,
        child: child,
      ),
    );
  }
}
