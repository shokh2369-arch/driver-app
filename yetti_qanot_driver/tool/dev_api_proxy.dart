// Dev-only reverse proxy for Flutter **web** testing on networks where one of the
// Render/Cloudflare edge IPs is silently blackholed (see
// lib/services/resilient_http_client_io.dart). Chrome cannot choose which IP it
// connects to and sits on a dead one for minutes; this proxy can. Chrome talks to
// http://localhost:<port>, the proxy reaches the backend with the app's racing /
// sticky transport, and forwards HTTP (incl. CORS preflights) and WebSockets.
//
// Run from the package root:
//   dart --packages=.dart_tool/package_config.json tool/dev_api_proxy.dart \
//        https://taxi-2866.onrender.com 8787
//   flutter run -d web-server --web-port=8765 \
//        --dart-define=API_BASE_URL=http://localhost:8787
//
// Never ship this; it is a local development aid only.
import 'dart:async';
import 'dart:io';

import 'package:yetti_qanot_driver/services/resilient_http_client_io.dart';

const _hopByHop = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};

Future<void> main(List<String> args) async {
  final target = Uri.parse(
    args.isNotEmpty ? args[0] : 'https://taxi-2866.onrender.com',
  );
  final port = args.length > 1 ? int.parse(args[1]) : 8787;
  final client = createResilientHttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..autoUncompress = true;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('dev proxy: http://localhost:$port  ->  $target');
  await for (final req in server) {
    unawaited(_handle(req, client, target));
  }
}

Future<void> _handle(HttpRequest req, HttpClient client, Uri target) async {
  final started = DateTime.now();
  if (WebSocketTransformer.isUpgradeRequest(req)) {
    await _relayWebSocket(req, target);
    return;
  }
  final upstreamUri = target.replace(
    path: req.uri.path,
    query: req.uri.hasQuery ? req.uri.query : null,
  );
  try {
    final out = await client.openUrl(req.method, upstreamUri);
    out.followRedirects = false;
    req.headers.forEach((name, values) {
      final n = name.toLowerCase();
      // Never forward the browser's Accept-Encoding: Cloudflare would answer
      // with Brotli, which HttpClient cannot decode; the client negotiates
      // gzip on its own and decompresses it (autoUncompress).
      if (_hopByHop.contains(n) ||
          n == 'host' ||
          n == 'content-length' ||
          n == 'accept-encoding') {
        return;
      }
      for (final v in values) {
        out.headers.add(name, v);
      }
    });
    out.headers.set(HttpHeaders.hostHeader, target.host);
    await out.addStream(req);
    final res = await out.close();
    final down = req.response;
    down.statusCode = res.statusCode;
    res.headers.forEach((name, values) {
      final n = name.toLowerCase();
      // Body arrives decompressed (autoUncompress) → drop framing/encoding headers.
      if (_hopByHop.contains(n) ||
          n == 'content-length' ||
          n == 'content-encoding') {
        return;
      }
      for (final v in values) {
        down.headers.add(name, v);
      }
    });
    await down.addStream(res);
    await down.close();
    _log(req, res.statusCode, started);
  } catch (e) {
    try {
      req.response.statusCode = HttpStatus.badGateway;
      req.response.headers.contentType = ContentType.text;
      req.response.write('dev proxy: $e');
      await req.response.close();
    } catch (_) {}
    _log(req, 502, started, error: e);
  }
}

Future<void> _relayWebSocket(HttpRequest req, Uri target) async {
  final started = DateTime.now();
  final wsUri = target.replace(
    scheme: target.scheme == 'https' ? 'wss' : 'ws',
    path: req.uri.path,
    query: req.uri.hasQuery ? req.uri.query : null,
  );
  try {
    final origin = req.headers.value('origin');
    final upstream = await WebSocket.connect(
      wsUri.toString(),
      customClient: resilientWebSocketHttpClient,
      headers: {'Origin': ?origin},
    );
    final downstream = await WebSocketTransformer.upgrade(req);
    downstream.listen(
      upstream.add,
      onDone: () => upstream.close(),
      onError: (_) => upstream.close(),
      cancelOnError: true,
    );
    upstream.listen(
      downstream.add,
      onDone: () => downstream.close(),
      onError: (_) => downstream.close(),
      cancelOnError: true,
    );
    _log(req, 101, started);
  } catch (e) {
    try {
      req.response.statusCode = HttpStatus.badGateway;
      await req.response.close();
    } catch (_) {}
    _log(req, 502, started, error: e);
  }
}

void _log(HttpRequest req, int status, DateTime started, {Object? error}) {
  final ms = DateTime.now().difference(started).inMilliseconds;
  stdout.writeln(
    '${req.method} ${req.uri.path} -> $status ${ms}ms'
    '${error == null ? '' : '  ($error)'}',
  );
}
