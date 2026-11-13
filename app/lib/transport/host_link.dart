/// HostLink — the phone-side transport for talking to the cc-go daemon.
///
/// Dart translation of `daemon/test/smoke-client.mjs` (design D4): one
/// WebSocket carrying JSON frames.
///
///  - phone → daemon: `{ id, method, params }` requests
///  - daemon → phone: `{ id, ok, result }` / `{ id, ok, error }` responses,
///    plus `{ type: "event", event }` pushes (see daemon/src/protocol.ts)
///
/// This file covers connection + JSON-RPC + the event stream only. TLS TOFU
/// pinning (task 3.2) plugs in via [HostLink.connect]'s `customClient`;
/// auto-reconnect (task 3.3) layers on top of [HostLink] later.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Decoded frames
// ---------------------------------------------------------------------------

/// A frame from the daemon: either a response to one of our requests or an
/// event push. Produced by [decodeFrame].
sealed class HostFrame {
  const HostFrame();
}

/// Response frame: `{ id, ok, result }` or `{ id, ok: false, error }`.
final class ResponseFrame extends HostFrame {
  const ResponseFrame.ok(this.id, this.result)
      : ok = true,
        errorCode = null,
        errorMessage = null;

  const ResponseFrame.err(this.id, this.errorCode, this.errorMessage)
      : ok = false,
        result = null;

  final String id;
  final bool ok;
  final dynamic result;
  final String? errorCode;
  final String? errorMessage;
}

/// Event push frame: `{ type: "event", event }`.
final class EventFrame extends HostFrame {
  const EventFrame(this.event);
  final Map<String, dynamic> event;
}

// ---------------------------------------------------------------------------
// Frame codec — pure logic, unit tested
// ---------------------------------------------------------------------------

/// Encodes a client request `{ id, method, params }`.
String encodeRequest(String id, String method, Map<String, dynamic> params) =>
    jsonEncode({'id': id, 'method': method, 'params': params});

/// Decodes one incoming frame. Throws [FormatException] on anything that is
/// not a well-formed response or event frame — the protocol has no third
/// shape, so garbage means a broken peer.
HostFrame decodeFrame(String data) {
  final Object? decoded;
  try {
    decoded = jsonDecode(data);
  } on FormatException {
    throw const FormatException('frame is not valid JSON');
  }
  if (decoded is! Map) {
    throw const FormatException('frame is not a JSON object');
  }

  if (decoded['type'] == 'event') {
    final event = decoded['event'];
    if (event is! Map<String, dynamic>) {
      throw const FormatException('event frame without event object');
    }
    return EventFrame(event);
  }

  final id = decoded['id'];
  if (id is! String) {
    throw const FormatException('response frame without string id');
  }
  final ok = decoded['ok'];
  if (ok == true) return ResponseFrame.ok(id, decoded['result']);
  if (ok == false) {
    final error = decoded['error'];
    final code = error is Map ? error['code'] : null;
    final message = error is Map ? error['message'] : null;
    if (code is String && message is String) {
      return ResponseFrame.err(id, code, message);
    }
    throw const FormatException('error frame without {code, message}');
  }
  throw const FormatException('frame is neither event nor response');
}

// ---------------------------------------------------------------------------
// Daemon events
// ---------------------------------------------------------------------------

/// A daemon push event (`DaemonEvent` in protocol.ts).
///
/// The envelope is typed; richer per-event models arrive with the session UI
/// tasks. `raw` keeps the full payload for the debug page (task 3.4).
class DaemonEvent {
  DaemonEvent(this.raw);

  final Map<String, dynamic> raw;

  /// `session` | `sessions.changed` | `permission.request`.
  String get type => raw['type'] as String;

  /// Session this event belongs to (`session`, `permission.request`), `null`
  /// for broadcasts like `sessions.changed`.
  String? get sessionId => raw['sessionId'] as String?;

  /// Item a `permission.request` is about.
  String? get itemId => raw['itemId'] as String?;

  /// Tool name of a `permission.request`.
  String? get toolName => raw['name'] as String?;

  /// Nested session event (`snapshot` / `item.added` / …), when present.
  Map<String, dynamic>? get sessionEvent {
    final nested = raw['event'];
    return nested is Map<String, dynamic> ? nested : null;
  }

  @override
  String toString() => jsonEncode(raw);
}

// ---------------------------------------------------------------------------
// Request correlation — pure logic, unit tested
// ---------------------------------------------------------------------------

/// Error carried by an `ok: false` response.
class RpcException implements Exception {
  const RpcException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RpcException($code): $message';
}

/// A request whose response has not arrived yet.
final class PendingCall {
  PendingCall(this.id, this.completer);
  final String id;
  final Completer<dynamic> completer;
  bool get isCompleted => completer.isCompleted;
}

/// Matches response frames back to the call that produced them, by request id.
class RequestRouter {
  final _pending = <String, PendingCall>{};
  var _nextId = 0;

  bool get hasPending => _pending.isNotEmpty;

  /// Registers a new pending call and returns it; the caller sends the wire
  /// request with `pending.id` and awaits `pending.completer.future`.
  PendingCall reserve() {
    final id = 'r${_nextId++}';
    final pending = PendingCall(id, Completer<dynamic>());
    _pending[id] = pending;
    return pending;
  }

  /// Completes the matching pending call (unknown ids are ignored — a stale
  /// or duplicated response must not crash the link).
  void deliver(ResponseFrame frame) {
    final pending = _pending.remove(frame.id);
    if (pending == null || pending.isCompleted) return;
    if (frame.ok) {
      pending.completer.complete(frame.result);
    } else {
      pending.completer.completeError(
        RpcException(frame.errorCode ?? 'internal', frame.errorMessage ?? ''),
        StackTrace.current,
      );
    }
  }

  /// Fails every still-pending call (connection dropped mid-request).
  void failAll(Object error) {
    final pending = List<PendingCall>.from(_pending.values);
    _pending.clear();
    for (final call in pending) {
      if (!call.isCompleted) call.completer.completeError(error, StackTrace.current);
    }
  }
}

// ---------------------------------------------------------------------------
// The link itself
// ---------------------------------------------------------------------------

/// Thrown when the connection drops before a call is answered.
class HostLinkClosed implements Exception {
  const HostLinkClosed(this.reason);
  final String reason;

  @override
  String toString() => 'HostLinkClosed: $reason';
}

/// Thrown when the daemon closes the socket with code 4003 (hello rejected —
/// unknown/revoked device token). Distinct from [HostLinkClosed] so callers
/// can route to re-pairing instead of blind reconnects.
class AuthRejectedByServer implements Exception {
  const AuthRejectedByServer(this.reason);
  final String reason;

  @override
  String toString() => 'AuthRejectedByServer: $reason';
}

/// What the reconnecting wrapper needs from a link — [HostLink] implements
/// this; tests inject fakes.
abstract class HostLinkBase {
  Stream<DaemonEvent> get events;
  Future<dynamic> call(String method, [Map<String, dynamic> params]);
  Future<void> close({String reason});
}

/// One authenticated WebSocket to the daemon.
///
/// Use [HostLink.connect] to dial, `hello`-authenticate and get a live link;
/// [call] for JSON-RPC requests; [events] for the push stream; [close] to
/// hang up. Reconnection is intentionally out of scope here (task 3.3).
class HostLink implements HostLinkBase {
  HostLink._(this._socket);

  final WebSocket _socket;
  final RequestRouter _router = RequestRouter();
  final StreamController<DaemonEvent> _events = StreamController<DaemonEvent>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  /// Push events from the daemon (broadcast: many listeners allowed).
  @override
  Stream<DaemonEvent> get events => _events.stream;

  /// Connects to `wsUri` (`wss://…/ws` in production) and completes the
  /// `hello` handshake before returning.
  ///
  /// `customClient` is the TLS seam: task 3.2 installs a pinned-cert
  /// [HttpClient] here; passing `null` uses the default context.
  static Future<HostLink> connect({
    required Uri wsUri,
    required String token,
    HttpClient? customClient,
    Duration helloTimeout = const Duration(seconds: 10),
  }) async {
    final socket = await WebSocket.connect(
      wsUri.toString(),
      customClient: customClient,
    );
    final link = HostLink._(socket);
    link._subscription = socket.asBroadcastStream().listen(
          link._onData,
          onError: link._onSocketError,
          onDone: () => link._onSocketDone('closed by peer'),
          cancelOnError: true,
        );
    try {
      await link
          .call('hello', {'token': token})
          .timeout(helloTimeout, onTimeout: () {
        throw TimeoutException('hello handshake timed out', helloTimeout);
      });
    } catch (error) {
      await link.close(reason: 'hello failed');
      rethrow;
    }
    return link;
  }

  /// Sends a request and completes with `result`, or throws [RpcException].
  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    if (_socket.readyState != WebSocket.open) {
      return Future.error(const HostLinkClosed('socket is not open'));
    }
    final pending = _router.reserve();
    _socket.add(encodeRequest(pending.id, method, params));
    return pending.completer.future;
  }

  @override
  Future<void> close({String reason = 'closed locally'}) async {
    await _subscription?.cancel();
    _subscription = null;
    _router.failAll(HostLinkClosed(reason));
    await _events.close();
    await _socket.close();
  }

  void _onData(dynamic data) {
    final HostFrame frame;
    try {
      frame = decodeFrame(data as String);
    } on FormatException catch (error) {
      // One malformed frame must not tear down the stream of working ones.
      _events.addError(error);
      return;
    }
    switch (frame) {
      case EventFrame():
        _events.add(DaemonEvent(frame.event));
      case ResponseFrame():
        _router.deliver(frame);
    }
  }

  void _onSocketError(Object error) {
    _onSocketDone('socket error: $error');
  }

  void _onSocketDone(String reason) {
    final code = _socket.closeCode;
    if (code == 4003) {
      _router.failAll(AuthRejectedByServer(_socket.closeReason ?? 'unauthorized'));
    } else {
      _router.failAll(HostLinkClosed('$reason (code ${code ?? '?'})'));
    }
    _events.close();
  }
}
