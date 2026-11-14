/// 网络切换 / 回前台的「kick」事件源（network-kicks design D1）。
///
/// 只在值得重新检查远端连接的时刻发事件：
/// - 订阅后的首次 connectivity 回调只是初始状态，不发（`_last == null` 跳过）；
/// - 结果含 `none`（纯掉线）不发——半开判死由 WS 心跳（host_link 的
///   pingInterval）与既有断线检测兜底；
/// - 回前台由 lifecycle_host 的 resumed 分支经 [NetworkKicks.resume] 注入。
///
/// 已知盲区（design D1 如实记录）：connectivity_plus 只报告传输类型且自带
/// 去重，Wi-Fi ↔ Wi-Fi 同类型切换不产生事件——同样靠 WS 心跳兜底。
///
/// kick 只加速既有重连机制（见 `ReconnectingHostLink.kick`），不引入并行路径。
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// 合并 connectivity 切换与回前台两个信号源的 kick 流。
class NetworkKicks {
  /// [changes] 注入点：测试传假流（枚举值即普通数据，无需真插件），生产缺省接真插件。
  NetworkKicks({Stream<List<ConnectivityResult>>? changes}) {
    _changesSub = (changes ?? Connectivity().onConnectivityChanged).listen(
      _onChanges,
      // 掉线探测失败等插件错误不值得炸掉 kick 流：下一轮 connectivity 事件
      // 或 WS 心跳仍会把连接带回正轨。
      onError: (Object _) {},
    );
  }

  // sync 广播：消费端 link.kick() 同步安全；sync:false 的取消要靠事件循环
  // 的 Timer 收尾，FakeAsync 测试（pumpAndSettle 不推进空闲时钟）里会悬挂。
  final _controller = StreamController<void>.broadcast(sync: true);
  StreamSubscription<List<ConnectivityResult>>? _changesSub;
  List<ConnectivityResult>? _last;

  /// kick 事件流（广播）。
  Stream<void> get stream => _controller.stream;

  /// App 回到前台（lifecycle_host 的 resumed 分支调用）。
  void resume() {
    if (!_controller.isClosed) _controller.add(null);
  }

  void _onChanges(List<ConnectivityResult> results) {
    final previous = _last;
    _last = results;
    if (previous == null) return; // 首次回调只是初始状态（去重）
    if (results.contains(ConnectivityResult.none)) return; // 纯掉线不触发
    if (!_controller.isClosed) _controller.add(null);
  }

  Future<void> dispose() async {
    final sub = _changesSub;
    _changesSub = null;
    try {
      await sub?.cancel();
    } on Object {
      // 插件不可用的环境（如 widget 测试）里 EventChannel 的取消会以错误
      // 收场：dispose 必须总能完成，否则 AppLink.stop() 卡死清凭据流程。
    }
    await _controller.close();
  }
}
