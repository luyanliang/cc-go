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

import 'host_link.dart';

enum LinkState { connecting, connected }

/// Connects and completes the `hello` handshake, or throws.
typedef LinkConnector = Future<HostLinkBase> Function();

class ReconnectingHostLink {
  ReconnectingHostLink({
    required this.connector,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
  });

  /// Dials + handshakes a fresh link; throws on failure (the loop retries).
  final LinkConnector connector;
  final Duration baseDelay;
  final Duration maxDelay;

  // 新订阅者立即收到当前状态（晚订阅的 UI 不该永远停在 connecting）。
  late final StreamController<LinkState> _states = StreamController<LinkState>.broadcast(
    onListen: () {
      if (_lastState != null && !_states.isClosed) _states.add(_lastState!);
    },
  );
  final _events = StreamController<DaemonEvent>.broadcast();
  final _watchedSessionIds = <String>{};

  HostLinkBase? _current;
  StreamSubscription<DaemonEvent>? _currentSubscription;
  Completer<void>? _dropped;
  LinkState? _lastState;
  var _attempt = 0;
  var _stopped = false;

  /// Connection state transitions (for the UI's offline banner, task 8.4).
  /// New listeners immediately receive the current state.
  Stream<LinkState> get states => _states.stream;

  /// Daemon events, merged across reconnects.
  Stream<DaemonEvent> get events => _events.stream;

  LinkState get state => _lastState ?? LinkState.connecting;

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

  /// Runs a call on the live link; throws [HostLinkClosed] while down (the
  /// caller decides whether to retry — reconnects are automatic, call
  /// re-sends are not, so nothing is silently swallowed).
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    final link = _current;
    if (link == null) {
      return Future.error(const HostLinkClosed('reconnecting'));
    }
    return link.call(method, params);
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
        // Re-subscribe: every watched session gets a fresh snapshot,
        // re-emitted on the merged event stream by _watchOn.
        for (final sessionId in List<String>.from(_watchedSessionIds)) {
          unawaited(_watchOn(link, sessionId));
        }
        await _dropped!.future;
      } on Object {
        _current = null;
        if (_stopped) return;
        await _waitBackoff(backoffFor(_attempt));
        _attempt++;
      }
    }
  }

  void _setState(LinkState state) {
    _lastState = state;
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
