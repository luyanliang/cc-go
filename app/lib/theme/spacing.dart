/// 间距 token：页面留白、轮次节奏、阅读列宽的单一来源。界面代码不手写
/// 零散 EdgeInsets 常量做布局节奏 —— 从这里取。
library;

/// 间距阶梯（dsh-Go 同款）。
abstract final class AppSpace {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;

  /// 页面水平留白。
  static const gutter = 16.0;

  /// 同一轮内：工具行 ↔ 正文。
  static const inTurn = 8.0;

  /// 换轮。
  static const betweenTurns = 24.0;

  /// 正文最大阅读宽度（平板/宽屏居中）。
  static const readingWidth = 720.0;

  /// 浮层与阅读列两边的距离。
  static const floatInset = 12.0;

  /// 浮层（输入条、斜杠面板）在宽屏下的宽度。
  static const floatingWidth = readingWidth - 2 * floatInset;
}
