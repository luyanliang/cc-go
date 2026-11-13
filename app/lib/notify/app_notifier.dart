/// 本地通知装配（task 8.2/8.3）：权限请求（高优先级）与轮次结束两条
/// 渠道，可独立静音；点按携带 sessionId 回传导航。
library;

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_policy.dart';

final appNotifierProvider = Provider<AppNotifier>((ref) => AppNotifier());

class AppNotifier {
  static const _permissionChannel = AndroidNotificationChannel(
    'cc_go_permissions',
    '权限请求',
    description: 'Claude 请求工具权限时提醒（高优先级）',
    importance: Importance.high,
  );
  static const _turnChannel = AndroidNotificationChannel(
    'cc_go_turns',
    '轮次结束',
    description: '后台等待的一轮任务完成时提醒',
    importance: Importance.defaultImportance,
  );

  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<String>.broadcast();
  bool _initialized = false;

  /// 通知点按（payload = sessionId）。
  Stream<String> get taps => _taps.stream;

  /// 冷启动时由哪条通知拉起（null = 非通知启动）。
  Future<String?> launchPayload() async {
    await ensureInitialized();
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.notificationResponse?.payload;
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) _taps.add(payload);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_permissionChannel);
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_turnChannel);
    _initialized = true;
  }

  /// Android 13+ 运行时通知权限。
  Future<bool> requestPermission() async {
    await ensureInitialized();
    final granted = await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    return granted ?? false;
  }

  Future<void> show(NotifyIntent intent) async {
    await ensureInitialized();
    final (channel, title, body) = switch (intent.kind) {
      NotifyKind.permissionRequest => (
          _permissionChannel,
          '权限请求：${intent.toolName ?? "工具"}',
          '「${intent.title}」等待你授权 ${intent.toolName ?? "工具"}'
        ),
      NotifyKind.turnDone => (
          _turnChannel,
          '轮次结束',
          '「${intent.title}」已完成本轮任务'
        ),
    };
    await _plugin.show(
      id: intent.sessionId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: intent.kind == NotifyKind.permissionRequest
              ? Priority.high
              : Priority.defaultPriority,
          category: intent.kind == NotifyKind.permissionRequest
              ? AndroidNotificationCategory.alarm
              : AndroidNotificationCategory.status,
        ),
      ),
      payload: intent.sessionId,
    );
  }
}
