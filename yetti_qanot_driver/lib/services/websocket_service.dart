import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService {
  WebSocketService({required this.url});

  final String url;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _controller.stream;

  Future<void> connect() async {
    if (url.isEmpty) return; // mock mode
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
        debugPrint('[yetti_driver] WS connect url=$normalized');
      }
      final ch = IOWebSocketChannel.connect(normalized);
      _channel = ch;
      _sub = ch.stream.listen(
        (event) {
          try {
            final decoded = json.decode(event as String);
            if (decoded is Map<String, dynamic>) _controller.add(decoded);
          } catch (_) {
            // ignore bad messages
          }
        },
        onError: (Object e, StackTrace st) {
          debugPrint('WebSocket stream error: $e');
        },
        cancelOnError: false,
      );
      // Completes with handshake errors if the server does not upgrade — must be awaited or they become unhandled async errors.
      await ch.ready.catchError((Object e, StackTrace st) {
        debugPrint('WebSocket handshake failed: $e');
      });
    } catch (e, st) {
      debugPrint('WebSocket connect failed: $e\n$st');
    }
  }

  void sendJson(Map<String, dynamic> data) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(json.encode(data));
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
    await _channel?.sink.close();
  }
}

