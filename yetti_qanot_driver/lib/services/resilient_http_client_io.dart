// Native-only (dart:io). Sticky, failover-aware connections for hosts that
// publish several A records.
//
// Why: the backend's Render/Cloudflare edge resolves to two IPv4 addresses and,
// on some networks (observed from Uzbekistan, exiting via Cloudflare's Moscow
// PoP), one of them is silently blackholed for minutes at a time — SYNs or TLS
// handshakes vanish, no RST. A plain `HttpClient` walks the resolver-ordered
// list under one shared `connectionTimeout`, so every request is a coin toss
// and the app reports "server unreachable" while the other address is fine.
//
// Fix: pick ONE address per connection, remember the last one that worked for
// that host, and rotate away from an address as soon as a connect fails. A dead
// edge IP then costs one timeout, not one timeout per request.
//
// Web builds never import this file (see `resilient_transport.dart`); browsers
// own their sockets.
import 'dart:async';
import 'dart:io';

/// Per-host address bookkeeping. Pure logic, unit-tested; opens no sockets.
class EdgeAddressSelector {
  EdgeAddressSelector({
    this.badTtl = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long a failed address is avoided before it gets another chance.
  final Duration badTtl;
  final DateTime Function() _now;

  /// host → address that most recently connected successfully.
  final Map<String, String> _preferred = {};

  /// host → address → time of the most recent connect failure.
  final Map<String, Map<String, DateTime>> _failedAt = {};

  /// The address to try first for [host] among [candidates] (non-empty).
  InternetAddress pick(String host, List<InternetAddress> candidates) =>
      order(host, candidates).first;

  /// All [candidates] in the order they should be raced: the address that
  /// last worked, then the others that have not failed recently (resolver
  /// order), then recently failed ones, least recent failure first.
  List<InternetAddress> order(String host, List<InternetAddress> candidates) {
    assert(candidates.isNotEmpty);
    final now = _now();
    final failed = _failedAt[host] ?? const <String, DateTime>{};
    bool isBad(InternetAddress a) {
      final t = failed[a.address];
      return t != null && now.difference(t) < badTtl;
    }

    final pref = _preferred[host];
    final head = <InternetAddress>[];
    final healthy = <InternetAddress>[];
    final bad = <InternetAddress>[];
    for (final a in candidates) {
      if (a.address == pref && !isBad(a)) {
        head.add(a);
      } else if (isBad(a)) {
        bad.add(a);
      } else {
        healthy.add(a);
      }
    }
    bad.sort(
      (x, y) => (failed[x.address] ?? now).compareTo(failed[y.address] ?? now),
    );
    return [...head, ...healthy, ...bad];
  }

  /// True when [a] is the address that last connected successfully for [host].
  bool isPreferred(String host, InternetAddress a) =>
      _preferred[host] == a.address;

  void markGood(String host, InternetAddress a) {
    _preferred[host] = a.address;
    _failedAt[host]?.remove(a.address);
  }

  void markBad(String host, InternetAddress a) {
    (_failedAt[host] ??= {})[a.address] = _now();
    if (_preferred[host] == a.address) _preferred.remove(host);
  }
}

final EdgeAddressSelector _selector = EdgeAddressSelector();

/// The process-wide selector (diagnostics / tests).
EdgeAddressSelector get edgeAddressSelector => _selector;

/// Test/diagnostics hook: called with the address chosen for each connection.
void Function(String host, InternetAddress chosen)? debugOnPick;

/// Test/diagnostics hook: a chosen address failed to connect.
void Function(String host, InternetAddress chosen, Object error)?
debugOnConnectError;

/// An [HttpClient] whose connections go through [EdgeAddressSelector].
///
/// Only the socket choice differs from a default client; timeouts, TLS
/// verification (SNI + certificate against the real host name) and everything
/// else are the SDK's own.
HttpClient createResilientHttpClient() {
  final client = HttpClient();
  client.connectionFactory = _connect;
  return client;
}

/// Shared client for `WebSocket.connect(customClient: …)`, so the dispatch
/// socket benefits from the same address stickiness as HTTP.
final HttpClient resilientWebSocketHttpClient = createResilientHttpClient();

/// Start the next address this long after the previous one if it has not
/// connected yet. A healthy edge completes TCP + TLS in ~0.5 s from Uzbekistan;
/// a blackholed one never answers.
const Duration _stagger = Duration(milliseconds: 600);

/// When the first candidate is the address that worked last time, give it longer
/// before racing a second TLS handshake (which cannot be cancelled once TCP is
/// up): a merely slow link should not pay for two handshakes per connection.
const Duration _staggerPreferred = Duration(milliseconds: 1500);

/// Upper bound for the whole race (all addresses). Kept at/below the Dio
/// `connectTimeout` so the request fails with the usual transport error.
const Duration _budget = Duration(seconds: 8);

Future<ConnectionTask<Socket>> _connect(
  Uri url,
  String? proxyHost,
  int? proxyPort,
) async {
  // Behind a proxy the SDK builds the TLS tunnel itself; just reach the proxy.
  if (proxyHost != null && proxyPort != null) {
    return Socket.startConnect(proxyHost, proxyPort);
  }
  final host = url.host;
  final secure = url.scheme == 'https' || url.scheme == 'wss';
  // `Uri.port` only knows the defaults for http/https: for `ws`/`wss` it is 0,
  // and `WebSocket.connect` copies that 0 into the `https` URL it hands us.
  final port = url.port == 0 ? (secure ? 443 : 80) : url.port;

  List<InternetAddress> addrs = const [];
  try {
    addrs = await InternetAddress.lookup(host);
  } catch (_) {
    // Fall through: the SDK's own connect will surface the lookup error.
  }
  if (addrs.length < 2) {
    return secure
        ? SecureSocket.startConnect(host, port)
        : Socket.startConnect(host, port);
  }

  final ordered = _selector.order(host, addrs);
  debugOnPick?.call(host, ordered.first);

  // Happy-eyeballs across the A records: `ConnectionTask` cannot be composed by
  // user code, so the race happens here and the winning task is handed back.
  // `a.host` is the looked-up name, so SNI and certificate verification still
  // use the real host name, not the IP literal.
  final winner = Completer<ConnectionTask<Socket>>();
  final pending = <ConnectionTask<Socket>>{};
  var started = 0;
  var failed = 0;
  Object? lastError;

  // A pending connect is cancelled; one that (already or later) connected is
  // closed, so a losing or late attempt can never leak a socket.
  void discard(ConnectionTask<Socket> t) {
    t.cancel();
    unawaited(t.socket.then((s) => s.destroy(), onError: (_) {}));
  }

  void finishLosers(ConnectionTask<Socket> keep) {
    for (final t in pending) {
      if (!identical(t, keep)) discard(t);
    }
    pending.clear();
  }

  void noteFailure(InternetAddress a, Object e) {
    failed++;
    lastError = e;
    if (winner.isCompleted) return;
    _selector.markBad(host, a);
    debugOnConnectError?.call(host, a, e);
    if (failed >= ordered.length) winner.completeError(e);
  }

  Future<void> attempt(InternetAddress a) async {
    started++;
    late final ConnectionTask<Socket> task;
    try {
      task = secure
          ? await SecureSocket.startConnect(a, port)
          : await Socket.startConnect(a, port);
    } catch (e) {
      noteFailure(a, e);
      return;
    }
    if (winner.isCompleted) {
      discard(task);
      return;
    }
    pending.add(task);
    unawaited(
      task.socket.then(
        (socket) {
          if (winner.isCompleted) {
            // Late arrival after a winner or after the budget expired: neither
            // a preference signal nor a socket anyone will use.
            pending.remove(task);
            socket.destroy();
            return;
          }
          _selector.markGood(host, a);
          pending.remove(task);
          finishLosers(task);
          winner.complete(task);
        },
        onError: (Object e) {
          pending.remove(task);
          noteFailure(a, e);
        },
      ),
    );
  }

  final deadline = DateTime.now().add(_budget);
  for (var i = 0; i < ordered.length; i++) {
    final a = ordered[i];
    unawaited(attempt(a));
    if (winner.isCompleted) break;
    final stagger = (i == 0 && _selector.isPreferred(host, a))
        ? _staggerPreferred
        : _stagger;
    try {
      return await winner.future.timeout(stagger);
    } on TimeoutException {
      // Not yet — start the next candidate.
    }
  }
  final left = deadline.difference(DateTime.now());
  try {
    return await winner.future.timeout(left.isNegative ? Duration.zero : left);
  } on TimeoutException {
    final err = SocketException(
      'All $started address(es) for $host timed out within $_budget'
      '${lastError == null ? '' : ' (last error: $lastError)'}',
    );
    if (!winner.isCompleted) {
      // Settle the race so late completions are discarded, not adopted.
      winner.completeError(err);
      winner.future.ignore();
    }
    for (final t in pending) {
      discard(t);
    }
    pending.clear();
    // Everything we tried is now suspect for this host.
    for (final a in ordered) {
      _selector.markBad(host, a);
    }
    throw err;
  }
}
