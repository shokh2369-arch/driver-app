import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_connect_with_headers.dart' as ws_hdr;

/// Thin JSON WebSocket wrapper.
///
/// The socket is **single-use**: once the peer closes (or the handshake fails) the
/// service reports [hasActiveChannel] == false and [messages] completes, so callers
/// can dispose it and build a fresh one. Doze / OEM battery savers drop these sockets
/// routinely, so silently keeping a dead channel around is not an option — the driver
/// would stop receiving trip and dispatch events for the rest of the session.
class WebSocketService {
  WebSocketService({
    required this.url,
    this.connectHeaders,
  });

  final String url;

  /// Optional HTTP headers for the WebSocket upgrade (IO only; native driver auth).
  final Map<String, String>? connectHeaders;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  bool _closed = false;

  /// Completes (via `onDone`) as soon as the underlying socket ends — normally,
  /// with an error, or on [dispose].
  Stream<Map<String, dynamic>> get messages => _controller.stream;

  /// True only while the socket is actually open.
  bool get hasActiveChannel => !_closed && _channel != null && _sub != null;

  /// Query strings carry `driver_id` / `init_data`; never log them.
  static String _redactQuery(String u) {
    final i = u.indexOf('?');
    return i < 0 ? u : '${u.substring(0, i)}?<redacted>';
  }

  Future<void> connect() async {
    if (url.isEmpty || _closed) return; // mock mode / already torn down
    try {
      // Defensive: some Android paths stringify bad URIs (`https://…:0/…#`) before connect.
      var normalized = url.trim();
      normalized = normalized
          .replaceFirst(RegExp(r'^https://', caseSensitive: false), 'wss://')
          .replaceFirst(RegExp(r'^http://', caseSensitive: false), 'ws://');
      normalized = normalized.replaceAll(RegExp(r':0(?=/|\?|#|$)'), '');
      if (normalized.endsWith('#')) {
        normalized = normalized.substring(0, normalized.length - 1);
      }
      if (kDebugMode) {
        debugPrint(
          '[yetti_driver] WS connect url=${_redactQuery(normalized)} '
          'headers=${connectHeaders?.keys.join(",") ?? "—"}',
        );
      }

      final ch = await ws_hdr.connectWithOptionalHeaders(
        normalized,
        connectHeaders ?? const <String, String>{},
      );
      _channel = ch;
      _sub = ch.stream.listen(
        (event) {
          if (event is! String) return;
          try {
            final decoded = json.decode(event);
            if (decoded is Map<String, dynamic>) _controller.add(decoded);
          } catch (_) {
            // ignore bad messages
          }
        },
        onError: (Object e, StackTrace st) {
          debugPrint('WebSocket stream error: $e');
          // Treat as terminal: the caller reconnects rather than sitting on a dead socket.
          unawaited(_markClosed());
        },
        onDone: () => unawaited(_markClosed()),
        cancelOnError: false,
      );
      // Completes with handshake errors if the server does not upgrade — must be awaited
      // or they surface as unhandled async errors.
      await ch.ready.catchError((Object e, StackTrace st) async {
        debugPrint('WebSocket handshake failed: $e');
        await _markClosed();
      });
    } catch (e, st) {
      debugPrint('WebSocket connect failed: $e\n$st');
      await _markClosed();
    }
  }

  /// Tear the socket down and notify listeners exactly once.
  Future<void> _markClosed() async {
    if (_closed) return;
    _closed = true;
    final sub = _sub;
    final ch = _channel;
    _sub = null;
    _channel = null;
    await sub?.cancel();
    try {
      await ch?.sink.close();
    } catch (_) {}
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void sendJson(Map<String, dynamic> data) {
    if (!hasActiveChannel) return;
    try {
      _channel!.sink.add(json.encode(data));
    } catch (e) {
      debugPrint('WebSocket send failed: $e');
      unawaited(_markClosed());
    }
  }

  Future<void> dispose() => _markClosed();
}
