/// 根部生命周期接线（第 8 节）：前后台检测 → 通知前台抑制；
/// appLink 事件/会话列表 → NotificationPolicy → 本地通知；
/// 通知点按 → 直达对应会话聊天页；前台服务随连接启停；
/// 首次后台启用时电池优化豁免引导（可跳过，task 8.4）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/app_notifier.dart';
import '../notify/foreground_link.dart';
import '../notify/notification_policy.dart';
import '../state/app_link.dart';
import '../state/app_link_provider.dart';
import '../state/providers.dart';
import '../state/sessions.dart';
import '../transport/host_link.dart';
import '../transport/reconnecting_link.dart';
import 'chat/chat_screen.dart';

/// 挂在 MaterialApp home 外层的哑组件：不渲染任何 UI（对话框/导航除外）。
class LifecycleHost extends ConsumerStatefulWidget {
  const LifecycleHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LifecycleHost> createState() => _LifecycleHostState();
}

/// 电池豁免引导"已跳过"的持久化键：一旦点过跳过（或已豁免），之后所有
/// 进程生命周期都不再弹 —— 之前是内存变量，进程被杀重启就再弹一次。
const _kBatterySkipKey = 'battery.prompt.skipped';

class _LifecycleHostState extends ConsumerState<LifecycleHost>
    with WidgetsBindingObserver {
  final _policy = NotificationPolicy();
  StreamSubscription<DaemonEvent>? _eventsSub;
  StreamSubscription<LinkState>? _stateSub;
  StreamSubscription<String>? _tapSub;
  Object? _wiredLinkIdentity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tapSub = ref.read(appNotifierProvider).taps.listen(_openSessionFromTap);
    unawaited(_handleColdStartFromNotification());
  }

  /// 进程被杀后由通知点按冷启动：launch payload 里的 sessionId 直达会话。
  Future<void> _handleColdStartFromNotification() async {
    final notifier = ref.read(appNotifierProvider);
    final launch = await notifier.launchPayload();
    if (launch != null && launch.isNotEmpty) {
      _openSessionFromTap(launch);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_eventsSub?.cancel());
    unawaited(_stateSub?.cancel());
    unawaited(_tapSub?.cancel());
    super.dispose();
  }

  // AppLifecycleState（resumed 之外均视为后台：8.2/8.3 的前台抑制）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _policy.setBackground(state != AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      // 回前台 = 值得检查连接的时刻（Android 可能冻结过 socket；
      // network-kicks design D3：UI 层只递事件，消费在 AppLink/链接层）。
      ref.read(appLinkProvider).value?.kicks.resume();
    }
    if (state == AppLifecycleState.paused) {
      unawaited(_maybePromptBatteryOptimization());
    }
  }

  void _openSessionFromTap(String sessionId) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    final title = _policy.titleOf(sessionId) ?? '会话';
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(sessionId: sessionId, title: title),
    ));
  }

  /// 电池豁免引导（8.4，对齐 dsh-Go 的克制策略）：
  /// 1. 已豁免（isIgnoringBatteryOptimizations）→ 永不弹；
  /// 2. 用户点过「跳过」→ 持久化，之后所有进程生命周期都不再弹；
  /// 3. 「去设置」直接弹系统豁免确认框（少一步；无该 Action 回退列表页）。
  Future<void> _maybePromptBatteryOptimization() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kBatterySkipKey) ?? false) return;
    bool exempt;
    try {
      exempt = await const MethodChannel('cc_go/android')
              .invokeMethod<bool>('isBatteryExempt') ??
          true;
    } on PlatformException {
      return; // 查不到状态就不打扰。
    }
    if (exempt || !mounted) return;
    final go = await showDialog<bool>(
      context: rootNavigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('提高后台存活'),
        content: const Text(
          '为让锁屏后仍能收到权限与轮次通知，建议允许 cc-go 忽略电池优化'
          '（华为等厂商 ROM 还有各自的启动管理开关，路径略有差异）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('跳过'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (go == true) {
      try {
        await const MethodChannel('cc_go/android')
            .invokeMethod<void>('requestIgnoreBatteryOptimizations');
      } on PlatformException {
        // 无该 Action 的 ROM 直接吞掉；用户可自行去设置。
      }
    }
    // 无论选哪个都持久化：引导对每个安装最多弹一次，绝不循环打扰
    // （豁免与否由系统状态决定，未豁免时锁屏后收不到通知是 ROM 行为）。
    await prefs.setBool(_kBatterySkipKey, true);
  }

  @override
  Widget build(BuildContext context) {
    // 连接生命周期：随凭据出现/消失启停前台服务与事件接线
    ref.listen(appLinkProvider, (_, next) {
      final appLink = next.value;
      if (appLink == null) return;
      _wireLink(appLink);
    });
    final existing = ref.read(appLinkProvider).value;
    if (existing != null) _wireLink(existing);


    ref.listen(credentialsProvider, (previous, next) {
      next.whenData((creds) {
        if (creds == null) {
          _wiredLinkIdentity = null;
          unawaited(_eventsSub?.cancel());
          unawaited(_stateSub?.cancel());
          unawaited(ref.read(foregroundLinkProvider).stop());
        }
      });
    });

    // 会话列表 → running→idle 边沿（轮次结束通知）
    ref.listen(sessionsProvider, (_, next) {
      next.whenData((sessions) {
        for (final intent in _policy.onSessions(sessions)) {
          unawaited(ref.read(appNotifierProvider).show(intent));
        }
      });
    });

    return widget.child;
  }

  void _wireLink(AppLink appLink) {
    if (identical(_wiredLinkIdentity, appLink)) return; // build 重跑不重接线
    _wiredLinkIdentity = appLink;
    unawaited(_eventsSub?.cancel());
    unawaited(_stateSub?.cancel());

    final credentials = ref.read(credentialsProvider).value;
    final hostName = credentials?.hostName ?? '电脑';
    final foreground = ref.read(foregroundLinkProvider);
    unawaited(foreground.start(hostName));
    // Android 13+ 的通知运行时权限（首次连接时请求一次）
    unawaited(ref.read(appNotifierProvider).requestPermission());

    _eventsSub = appLink.link.events.listen((event) {
      for (final intent in _policy.onDaemonEvent(event)) {
        unawaited(ref.read(appNotifierProvider).show(intent));
      }
    });

    _stateSub = appLink.link.states.listen((state) {
      unawaited(foreground.update(
        connected: state == LinkState.connected,
        hostName: hostName,
      ));
    });
  }
}

/// 通知点按 deep-link 用的全局 navigator key。
final rootNavigatorKey = GlobalKey<NavigatorState>();
