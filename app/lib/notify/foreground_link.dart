/// 前台服务装配（task 8.1）：保活进程（连带 HostLink 连接），
/// 常驻通知如实展示连接状态（已连接/连接中/断开）。
library;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final foregroundLinkProvider = Provider<ForegroundLink>((ref) => ForegroundLink());

class ForegroundLink {
  var _started = false;
  bool get isRunning => _started;

  Future<void> _initOnce() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cc_go_connection',
        channelName: '连接状态',
        channelDescription: 'cc-go 与电脑的连接状态（常驻）',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),

    );
  }

  /// App 已配对并建立连接时启动；通知文案随连接状态更新（8.1）。
  Future<void> start(String hostName) async {
    await _initOnce();
    if (await FlutterForegroundTask.isRunningService) {
      await update(connected: true, hostName: hostName);
      _started = true;
      return;
    }
    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'cc-go',
      notificationText: '已连接 $hostName',
    );
    _started = true;
  }

  /// 连接状态变化时刷新常驻通知文案。
  Future<void> update({required bool connected, required String hostName}) async {
    if (!_started) return;
    await FlutterForegroundTask.updateService(
      notificationText: connected ? '已连接 $hostName' : '连接中…（$hostName）',
    );
  }

  /// 忘记主机/解绑时停止。
  Future<void> stop() async {
    if (!_started) return;
    await FlutterForegroundTask.stopService();
    _started = false;
  }
}
