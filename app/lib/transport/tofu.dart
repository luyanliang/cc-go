/// TLS trust-on-first-use for the daemon's self-signed certificate
/// (design D3, spec secure-transport "客户端 TOFU 指纹锁定").
///
/// Trust model, mirroring `daemon/test/smoke-client.mjs`:
///  - first connection: learn the cert's SHA-256 fingerprint, hand it to the
///    caller to persist (pairing writes it next to the device token);
///  - later connections: fingerprint match → proceed, mismatch → refuse to
///    send anything (the TLS handshake fails closed);
///  - "forget host": clear the stored fingerprint, next connection re-learns.
///
/// `badCertificateCallback` is synchronous, so the comparison is pure
/// in-memory work — no dialogs, no async — which is why one fingerprint per
/// host is stored at pairing time.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Normalizes a fingerprint for comparison: uppercase hex, no separators —
/// accepts `aa:bb:…`, `AABB…`, etc.
String normalizeFingerprint(String fingerprint) =>
    fingerprint.replaceAll(':', '').toUpperCase();

/// `AA:BB:CC:…` uppercase hex, the openssl `x509 -fingerprint -sha256` shape
/// the daemon prints in its startup banner.
String fingerprintOfDer(List<int> der) {
  final digest = sha256.convert(der);
  return digest.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// Pure TOFU decision logic — unit tested.
enum TofuDecision { trust, learn, reject }

class TofuPolicy {
  TofuPolicy({String? expectedFingerprint})
      : expected = expectedFingerprint == null
            ? null
            : normalizeFingerprint(expectedFingerprint);

  /// The pinned fingerprint (normalized), `null` while still learning.
  final String? expected;

  /// What to do with a live cert fingerprint.
  TofuDecision decide(String liveFingerprint) {
    final live = normalizeFingerprint(liveFingerprint);
    if (expected == null) return TofuDecision.learn;
    return live == expected ? TofuDecision.trust : TofuDecision.reject;
  }
}

/// Per-host fingerprint storage. The pairing flow writes; every later
/// connection reads. Implementations: [MemoryFingerprintStore] (tests,
/// in-process), secure storage (task 4.2).
abstract class FingerprintStore {
  Future<String?> read(String host);
  Future<void> write(String host, String fingerprint);
  /// "忘记主机" — clears the pin, the next connection re-learns.
  Future<void> remove(String host);
}

class MemoryFingerprintStore implements FingerprintStore {
  final _byHost = <String, String>{};

  @override
  Future<String?> read(String host) async => _byHost[host];

  @override
  Future<void> write(String host, String fingerprint) async {
    _byHost[host] = normalizeFingerprint(fingerprint);
  }

  @override
  Future<void> remove(String host) async => _byHost.remove(host);
}

/// Builds the [HttpClient] that enforces TOFU for both plain HTTPS requests
/// (pairing) and WebSocket connects (pass as `HostLink.connect.customClient`).
///
/// If no fingerprint is pinned for this host yet, the first certificate is
/// accepted and reported through [onFingerprintLearned] — the caller persists
/// it. A pinned, non-matching certificate rejects the handshake (returns
/// false): the connection dies before any token or payload is sent.
HttpClient tofuHttpClient({
  required TofuPolicy policy,
  void Function(String learnedFingerprint)? onFingerprintLearned,
}) {
  final client = HttpClient();
  client.badCertificateCallback = (X509Certificate cert, String host, int port) {
    final live = fingerprintOfDer(cert.der);
    switch (policy.decide(live)) {
      case TofuDecision.trust:
        return true;
      case TofuDecision.learn:
        onFingerprintLearned?.call(live);
        return true;
      case TofuDecision.reject:
        return false;
    }
  };
  return client;
}

/// Thrown when the certificate does not match the pinned fingerprint.
class TofuRejectedException implements Exception {
  const TofuRejectedException(this.host);
  final String host;

  @override
  String toString() =>
      'certificate fingerprint mismatch for $host — connection refused '
      '(reinstall? use "forget host" to re-pair)';
}

// ---------------------------------------------------------------------------
// Pairing (order per D3: TLS connect + TOFU learn → /pair → persist both)
// ---------------------------------------------------------------------------

/// `/pair` + `/info` results the pairing screen needs.
class PairSuccess {
  const PairSuccess({
    required this.token,
    required this.deviceId,
    required this.fingerprint,
    required this.hostName,
  });

  final String token;
  final String deviceId;
  /// The cert fingerprint learned during this pairing (TOFU).
  final String fingerprint;
  final String hostName;
}

/// Pairs with the daemon over TLS.
///
/// Uses (and does not close) [client] so the caller can reuse the very same
/// TOFU-pinned client for the WebSocket right after — the certificate is
/// verified once per client, and [HostLink.connect] accepts it unchanged.
Future<PairSuccess> pairWithDaemon({
  required InternetAddress host,
  required int port,
  required String code,
  required TofuPolicy policy,
  void Function(String learnedFingerprint)? onFingerprintLearned,
  HttpClient? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  var learned = <String>[];
  final http = client ??
      tofuHttpClient(
        policy: policy,
        onFingerprintLearned: (fp) {
          learned.add(fp);
          onFingerprintLearned?.call(fp);
        },
      );
  final uri = Uri(scheme: 'https', host: host.address, port: port, path: '/pair');

  final request = await http.postUrl(uri).timeout(
        timeout,
        onTimeout: () => throw TimeoutException('pairing timed out', timeout),
      );
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode({'code': code, 'name': 'cc-go phone'}));

  final HttpClientResponse response;
  try {
    response = await request.close().timeout(
      timeout,
      onTimeout: () => throw TimeoutException('pairing timed out', timeout),
    );
  } on HandshakeException {
    // badCertificateCallback refused the cert — surface the TOFU error.
    throw TofuRejectedException('${host.address}:$port');
  }

  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode == 403) {
    throw const PairingFailedException('配对码不正确');
  }
  if (response.statusCode != 200) {
    throw PairingFailedException('daemon 返回 ${response.statusCode}: $body');
  }
  final decoded = jsonDecode(body) as Map<String, dynamic>;
  return PairSuccess(
    token: decoded['token'] as String,
    deviceId: decoded['deviceId'] as String,
    // First pairing learned it above; an already-pinned policy knows it.
    fingerprint: learned.isNotEmpty ? learned.first : (policy.expected ?? ''),
    hostName: ((decoded['host'] as Map)['name'] ?? '') as String,
  );
}

/// Pairing failed with an error the user can act on.
class PairingFailedException implements Exception {
  const PairingFailedException(this.message);
  final String message;

  @override
  String toString() => message;
}
