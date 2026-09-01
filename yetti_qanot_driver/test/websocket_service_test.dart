import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/websocket_service.dart';

/// Minimal in-process WebSocket server so the close/reconnect contract is exercised
/// against a real socket rather than a mock.
class _TestWsServer {
  _TestWsServer._(this._server, this.port);

  final HttpServer _server;
  final int port;
  final _sockets = <WebSocket>[];

  static Future<_TestWsServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _TestWsServer._(server, server.port);
    unawaited(s._accept());
    return s;
  }

  Future<void> _accept() async {
    await for (final req in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        continue;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _sockets.add(ws);
      ws.listen((_) {}, onDone: () {}, onError: (_) {});
    }
  }

  void send(String data) {
    for (final ws in _sockets) {
      ws.add(data);
    }
  }

  Future<void> closeClients() async {
    for (final ws in List<WebSocket>.from(_sockets)) {
      await ws.close();
    }
    _sockets.clear();
  }

  Future<void> dispose() async {
    await closeClients();
    await _server.close(force: true);
  }
}

void main() {
  test('decodes JSON frames onto the message stream', () async {
    final server = await _TestWsServer.start();
    addTearDown(server.dispose);

    final svc = WebSocketService(url: 'ws://127.0.0.1:${server.port}/ws');
    await svc.connect();
    expect(svc.hasActiveChannel, isTrue);

    final first = svc.messages.first;
    server.send('{"type":"dispatch_changed"}');
    expect((await first)['type'], 'dispatch_changed');

    await svc.dispose();
  });

  test('ignores malformed frames without killing the stream', () async {
    final server = await _TestWsServer.start();
    addTearDown(server.dispose);

    final svc = WebSocketService(url: 'ws://127.0.0.1:${server.port}/ws');
    await svc.connect();

    final first = svc.messages.first;
    server.send('not json');
    server.send('[1,2,3]'); // valid JSON, wrong shape
    server.send('{"type":"trip_started"}');
    expect((await first)['type'], 'trip_started');

    await svc.dispose();
  });

  // Regression: the peer closing used to leave `hasActiveChannel == true` and never
  // complete `messages`, so callers sat on a dead socket and never reconnected.
  test('peer close flips hasActiveChannel and completes the stream', () async {
    final server = await _TestWsServer.start();
    addTearDown(server.dispose);

    final svc = WebSocketService(url: 'ws://127.0.0.1:${server.port}/ws');
    await svc.connect();
    expect(svc.hasActiveChannel, isTrue);

    var done = false;
    svc.messages.listen((_) {}, onDone: () => done = true);

    await server.closeClients();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(svc.hasActiveChannel, isFalse, reason: 'must report the socket is gone');
    expect(done, isTrue, reason: 'listeners must be told so they can reconnect');
  });

  test('failed handshake leaves the service inactive', () async {
    // Nothing is listening on this port.
    final svc = WebSocketService(url: 'ws://127.0.0.1:1/ws');
    await svc.connect();
    expect(svc.hasActiveChannel, isFalse);
    await svc.dispose();
  });

  test('empty url is a no-op (mock mode)', () async {
    final svc = WebSocketService(url: '');
    await svc.connect();
    expect(svc.hasActiveChannel, isFalse);
    await svc.dispose();
  });

  test('dispose is idempotent', () async {
    final server = await _TestWsServer.start();
    addTearDown(server.dispose);

    final svc = WebSocketService(url: 'ws://127.0.0.1:${server.port}/ws');
    await svc.connect();
    await svc.dispose();
    await svc.dispose();
    expect(svc.hasActiveChannel, isFalse);
  });

  test('sendJson after close does not throw', () async {
    final svc = WebSocketService(url: 'ws://127.0.0.1:1/ws');
    await svc.connect();
    expect(() => svc.sendJson({'type': 'driver_location'}), returnsNormally);
  });
}
