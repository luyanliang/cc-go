import 'dart:async';

import 'package:cc_go/transport/network_kicks.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('订阅后的首次 connectivity 回调是初始状态，不发事件', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final kicks = NetworkKicks(changes: changes.stream);
    final fired = <void>[];
    final sub = kicks.stream.listen(fired.add);

    changes.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty);

    await sub.cancel();
    await kicks.dispose();
    await changes.close();
  });

  test('纯掉线（含 none）不发事件', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final kicks = NetworkKicks(changes: changes.stream);
    final fired = <void>[];
    final sub = kicks.stream.listen(fired.add);

    changes.add([ConnectivityResult.wifi]); // 初始状态
    await Future<void>.delayed(Duration.zero);
    changes.add([ConnectivityResult.none]); // 掉线
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty);

    await sub.cancel();
    await kicks.dispose();
    await changes.close();
  });

  test('回到在线（none → wifi）发一次事件', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final kicks = NetworkKicks(changes: changes.stream);
    final fired = <void>[];
    final sub = kicks.stream.listen(fired.add);

    changes.add([ConnectivityResult.none]); // 初始状态
    await Future<void>.delayed(Duration.zero);
    changes.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    expect(fired, hasLength(1));

    await sub.cancel();
    await kicks.dispose();
    await changes.close();
  });

  test('网络切换（wifi → mobile）发事件', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final kicks = NetworkKicks(changes: changes.stream);
    final fired = <void>[];
    final sub = kicks.stream.listen(fired.add);

    changes.add([ConnectivityResult.wifi]); // 初始状态
    await Future<void>.delayed(Duration.zero);
    changes.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(Duration.zero);
    expect(fired, hasLength(1));

    await sub.cancel();
    await kicks.dispose();
    await changes.close();
  });

  test('resume()（回前台）发事件，且广播给多个订阅者', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final kicks = NetworkKicks(changes: changes.stream);
    final a = <void>[];
    final b = <void>[];
    final subA = kicks.stream.listen(a.add);
    final subB = kicks.stream.listen(b.add);

    kicks.resume();
    await Future<void>.delayed(Duration.zero);
    expect(a, hasLength(1));
    expect(b, hasLength(1));

    await subA.cancel();
    await subB.cancel();
    await kicks.dispose();
    await changes.close();
  });

  test('dispose 后 resume 不抛错', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final kicks = NetworkKicks(changes: changes.stream);
    await kicks.dispose();
    kicks.resume();
    await changes.close();
  });
}
