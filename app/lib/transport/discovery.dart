/// mDNS 局域网发现（host-discovery spec / task 5.1）：解析 `_ccgo._tcp`
/// 广播，为配对屏提供「点选自动填参」的候选列表。
///
/// 发现不可用（组播被抑制、超时）时呈现空态——手动配对永不受阻
/// （spec「发现不可用降级」）。
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一台被发现的主机。
@immutable
class DiscoveredDaemon {
  const DiscoveredDaemon({
    required this.name,
    required this.host,
    required this.port,
    this.fingerprint,
  });

  final String name;
  final String host;
  final int port;

  /// daemon 证书指纹（TXT `fp` 字段）；缺失 = 广播方不支持，仍可点选。
  final String? fingerprint;
}

/// 观察局域网内的 cc-go daemon。流持续发出当前快照（主机上下线自动
/// 更新，spec「主机上下线自动更新」）；取消订阅即停止发现。
Stream<List<DiscoveredDaemon>> discoverDaemons() {
  final controller = StreamController<List<DiscoveredDaemon>>();
  final byName = <String, DiscoveredDaemon>{};

  Future(() async {
    final discovery = BonsoirDiscovery(type: '_ccgo._tcp', printLogs: false);
    try {
      await discovery.initialize();
      if (!discovery.isReady) {
        controller.add(const []);
        await controller.close();
        return;
      }
      var stopped = false;
      controller.onCancel = () {
        stopped = true;
        return discovery.stop();
      };
      discovery.eventStream?.listen(
        (event) {
          switch (event) {
            case BonsoirDiscoveryServiceResolvedEvent():
              final service = event.service;
              final host = service.hostAddresses.firstOrNull;
              if (host == null || host.isEmpty) return;
              byName[service.name] = DiscoveredDaemon(
                name: service.name,
                host: host,
                port: service.port,
                fingerprint: service.attributes['fp'],
              );
            case BonsoirDiscoveryServiceLostEvent():
              byName.remove(event.service.name);
            case BonsoirDiscoveryStoppedEvent():
              if (!stopped) {
                // 平台侧自己停了（后台被杀等）：以当前快照收尾。
                controller.add(byName.values.toList());
                controller.close();
              }
            case _:
              return;
          }
          if (!controller.isClosed) controller.add(byName.values.toList());
        },
        onError: (Object _) {
          if (!controller.isClosed) controller.add(byName.values.toList());
        },
      );
      await discovery.start();
    } on Object {
      // 发现引擎起不来（无组播权限等）：空态降级，不阻塞手动配对。
      controller.add(const []);
      await controller.close();
    }
  });

  return controller.stream;
}

/// 配对屏的发现列表 provider；等待 [discoveryGracePeriod] 后至少发出一次
/// （哪怕为空），UI 呈空态提示而手动表单始终可用。
const discoveryGracePeriod = Duration(seconds: 5);

final discoveredDaemonsProvider =
    StreamProvider<List<DiscoveredDaemon>>((ref) => discoverDaemons());
