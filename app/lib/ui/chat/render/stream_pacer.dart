/// 流式匀速吐出（chat-streaming-rendering）：字符预算器 —— 成块到达的
/// 增量按平滑速率渲染；落后时加速追赶，积压超过上限的部分直接放行
/// （不无限延迟）。纯 Dart 核心，时间由调用方喂（渲染层用帧时间戳，
/// 测试用假时钟），可测且不依赖任何调度器。
library;

/// 用法：流式增量到达时 [setTotal]（只增不减）；每个渲染帧 [tick] 取
/// 得应显示的截断长度（0..total）；回合完成时 [releaseAll] 全量放行，
/// 保证与服务端最终全文一致，不留残余。
class StreamPacer {
  StreamPacer({
    this.charsPerSecond = 600,
    this.catchUpFactor = 2,
    this.maxBacklogChars = 1800,
  });

  /// 目标速率：600 字/秒 —— 中文阅读上限附近，大块增量不闪跳。
  final int charsPerSecond;

  /// 落后时的追赶倍率。
  final int catchUpFactor;

  /// 积压上限（字符）：落后超过该值的部分一次性放行。
  final int maxBacklogChars;

  int _total = 0;
  int _released = 0;
  int? _lastMs;

  /// 总字符数（当前目标全文长度）。
  int get total => _total;

  /// 已放行字符数。
  int get released => _released;

  /// 目标全文更新（流式增量到达）。
  void setTotal(int total) {
    if (total > _total) _total = total;
  }

  /// 推进到 [nowMs]（单调毫秒），返回本帧应显示的截断长度。
  int tick(int nowMs) {
    if (_total <= _released) {
      _lastMs = nowMs;
      return _released;
    }
    final last = _lastMs;
    _lastMs = nowMs;
    final floor = _total - maxBacklogChars;
    if (last == null) {
      // 首帧：积压超上限的部分立即放行（floor），其余从 0 开始匀速。
      if (_released < floor) _released = floor.clamp(_released, _total);
      return _released;
    }
    final dtMs = (nowMs - last).clamp(0, 1000); // 长间隔不积巨量预算
    // 本帧预算 = dt × 速率 × 追赶倍率；积压超过上限的部分直接放行。
    var budget = (dtMs * charsPerSecond * catchUpFactor / 1000).round();
    if (_released + budget < floor) budget = floor - _released;
    _released = (_released + budget).clamp(_released, _total);
    return _released;
  }

  /// 完成时全量放行（与最终全文对齐）。
  int releaseAll() {
    _released = _total;
    return _released;
  }
}
