/// Auto-reconnecting wrapper around a [HostLinkBase] (task 3.3, design D5).
///
/// Owns one link at a time; when it drops, redials with exponential backoff
/// (reset on success). Every reconnect re-runs the `hello` handshake (inside
/// `HostLink.connect`) and re-issues `session.watch` for every session the
/// app asked to watch — snapshots then merge back idempotently by item id
/// (the protocol guarantees wholesale item replacement).
///
/// State changes and daemon events are exposed as long-lived broadcast
/// streams that survive any number of reconnects.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

import 'host_link.dart';

enum LinkState { connecting, connected }

/// Connects and completes the `hello` handshake, or throws.
typedef LinkConnector = Future<HostLinkBase> Function();

class ReconnectingHostLink {
  ReconnectingHostLink({
    required this.connector,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.probeTimeout = const Duration(seconds: 5),
  });

  /// Dials + handshakes a fresh link; throws on failure (the loop retries).
  final LinkConnector connector;
  final Duration baseDelay;
  final Duration maxDelay;

  /// [kick] 在已连接态的探测超时（network-kicks design D2）。
  final Duration probeTimeout;

  // BehaviorSubject：每个新订阅者立即收到当前状态（晚订阅的 UI——
  // 断线横幅、连接角标、生命周期接线——都不该错过最新值）。
  final _states = BehaviorSubject<LinkState>.seeded(LinkState.connecting);
  final _events = StreamController<DaemonEvent>.broadcast();
  final _watchedSessionIds = <String>{};

  HostLinkBase? _current;
  StreamSubscription<DaemonEvent>? _currentSubscription;
  Completer<void>? _dropped;
  var _attempt = 0;
  var _stopped = false;
  // kick 锁存（design D2）：拨号中/探测中到达的 kick 是"值得检查的时刻"，
  // 丢弃即永久丢失加速机会，锁存到本轮失败/探测结束后消费。
  var _kickPending = false;
  var _probing = false;

  /// Connection state transitions (for the UI's offline banner, task 8.4).
  /// New listeners immediately receive the current state.
  Stream<LinkState> get states => _states.stream;

  /// Daemon events, merged across reconnects.
  Stream<DaemonEvent> get events => _events.stream;

  LinkState get state => _states.value;

  /// Session ids to (re-)watch; snapshots arriving as `session` events on
  /// [events] refresh the transcript after every reconnect.
  /// Watch (or keep watching) a session's transcript.
  ///
  /// The daemon returns the snapshot inside the `session.watch` RPC response
  /// (server.ts) — this wrapper re-emits it as a `session`/`ev: snapshot`
  /// [DaemonEvent] on [events], so callers merge first-load and reconnect
  /// refresh through one uniform stream.
  Future<void> watch(String sessionId) async {
    _watchedSessionIds.add(sessionId);
    final link = _current;
    if (link != null) await _watchOn(link, sessionId);
  }

  Future<void> _watchOn(HostLinkBase link, String sessionId) async {
    try {
      final result = await link.call('session.watch', {'sessionId': sessionId});
      final snapshot = result is Map ? result['snapshot'] : null;
      if (snapshot is Map<String, dynamic>) {
        _events.add(DaemonEvent({
          'type': 'session',
          'sessionId': sessionId,
          'event': {'ev': 'snapshot', ...snapshot},
        }));
      }
    } on Object {
      // Dropped mid-call — the reconnect loop re-watches and the snapshot
      // arrives then. A live "not found" answer also lands here; the session
      // list UI drives watch lifecycle, so nothing is retried silently.
    }
  }

  void unwatch(String sessionId) => _watchedSessionIds.remove(sessionId);

  /// 网络切换 / 回前台的主动检查入口（network-kicks design D2）。
  ///
  /// 只加速既有重连机制，不引入并行重连路径：
  /// - 退避等待中：打断等待立即重试，**不重置 `_attempt`**——立即重试语义由
  ///   打断达成，成功后 `_loop` 本就归零；失败则梯子继续爬升，daemon 不可达
  ///   期间连续 kick 不会把重试节奏钉死在 1s；
  /// - 已连接：`host.info` 探测（[probeTimeout] 超时），失败经身份闸只关发起
  ///   探测的那条链路，防误杀探测期间刚重连的新链路；
  /// - 拨号中 / 探测中：锁存（`_kickPending`），本轮失败/探测结束后消费；
  /// - stop 后：忽略（BehaviorSubject.value 在 close 后返回旧值，不可依赖）。
  void kick() {
    if (_stopped) return;
    // 退避等待中的判别式（design D2）：`stop()` 的既有守卫同款写法；
    // 禁止以 `_retryTimer != null` 或裸 `state == connecting` 作判据。
    final backoff = _backoffWait;
    if (backoff != null && !backoff.isCompleted) {
      _kickPending = false; // 这次 kick 的消费就是打断本身
      backoff.complete();
      return;
    }
    final link = _current;
    if (link == null || _probing) {
      _kickPending = true;
      return;
    }
    _probe(link);
  }

  /// 已连接态的存活探测（design D2）：廉价 RPC + 超时，失败判死走既有重连。
  void _probe(HostLinkBase link) {
    _probing = true;
    unawaited(() async {
      try {
        await link.call('host.info').timeout(probeTimeout);
      } on Object {
        if (identical(_current, link)) {
          _kickPending = false; // 判死触发的重连即本次 kick 的消费
          await link.close(reason: 'network kick probe failed');
        }
      } finally {
        _probing = false;
        _kickPending = false;
      }
    }());
  }

  /// Runs a call on the live link.
  ///
  /// While a (re)connect is still pending, waits for it up to
  /// [connectTimeout] instead of failing immediately — callers race the
  /// connection all the time (list refresh right after pairing). If the
  /// wait lapses, throws [HostLinkClosed].
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
    Duration? connectTimeout,
  ]) async {
    var link = _current;
    if (link == null) {
      await untilConnected(timeout: connectTimeout ?? const Duration(seconds: 15));
      link = _current;
      if (link == null) {
        // Connected and dropped again in the same breath.
        throw const HostLinkClosed('reconnecting');
      }
    }
    return link.call(method, params);
  }

  /// Resolves once connected; throws [HostLinkClosed] if [timeout] lapses.
  /// Single source of truth for "wait for the link" (used by [call] and the
  /// tool scripts — don't hand-roll `states.firstWhere` copies).
  Future<void> untilConnected({Duration timeout = const Duration(seconds: 15)}) async {
    if (_current != null) return;
    try {
      await states.firstWhere((s) => s == LinkState.connected).timeout(timeout);
    } on Object {
      throw const HostLinkClosed('not connected in time');
    }
  }

  /// Starts the connect/reconnect loop. Must not be called twice.
  Future<void> start() async {
    unawaited(_loop());
    // Let the caller's `await` mean "loop is running", not "connected".
    await Future<void>.delayed(Duration.zero);
  }

  /// Stops for good: no further reconnects, pending calls fail, streams end.
  Future<void> stop() async {
    _stopped = true;
    // Cut any pending backoff wait short (and cancel its timer).
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!(_backoffWait?.isCompleted ?? true)) _backoffWait!.complete();
    await _currentSubscription?.cancel();
    _currentSubscription = null;
    await _current?.close(reason: 'stopped locally');
    _current = null;
    await _states.close();
    await _events.close();
  }

  Future<void> _loop() async {
    while (!_stopped) {
      _setState(LinkState.connecting);
      try {
        final link = await connector();
        if (_stopped) {
          await link.close(reason: 'stopped locally');
          return;
        }
        _current = link;
        _dropped = Completer<void>();
        _currentSubscription = link.events.listen(
          _events.add,
          onError: (Object error) => _events.addError(error),
          onDone: () => _drop('event stream closed'),
          cancelOnError: false,
        );
        _setState(LinkState.connected);
        _attempt = 0;
        _kickPending = false; // 新链路已建，挂起的 kick 失去意义
        // Re-subscribe: every watched session gets a fresh snapshot,
        // re-emitted on the merged event stream by _watchOn.
        for (final sessionId in List<String>.from(_watchedSessionIds)) {
          unawaited(_watchOn(link, sessionId));
        }
        await _dropped!.future;
      } on Object {
        _current = null;
        if (_stopped) return;
        if (_kickPending) {
          // 拨号挂起期间到达的 kick：网络可能已恢复，跳过退避立即重试
          // （design D2 的锁存消费点）。
          _kickPending = false;
          continue;
        }
        await _waitBackoff(backoffFor(_attempt));
        _attempt++;
      }
    }
  }

  void _setState(LinkState state) {
    if (!_states.isClosed) _states.add(state);
  }

  Timer? _retryTimer;
  Completer<void>? _backoffWait;

  /// Backoff pause that [stop] can interrupt (a stray pending Timer would
  /// otherwise outlive the loop).
  Future<void> _waitBackoff(Duration delay) {
    final done = _backoffWait = Completer<void>();
    _retryTimer = Timer(delay, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  void _drop(String why) {
    _current = null;
    _attempt = 0; // a lived connection resets the ladder (网络抖动 semantics)
    _dropped?.complete();
    _dropped = null;
  }

  @visibleForTesting
  Duration backoffFor(int attempt) {
    var multiples = 1;
    for (var i = 0; i < attempt; i++) {
      multiples *= 2;
      if (baseDelay * multiples > maxDelay) return maxDelay;
    }
    return baseDelay * multiples;
  }
}
