import 'dart:io' show WebSocket;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// IO (Android/iOS/desktop): pass driver auth headers on the WebSocket upgrade.
Future<WebSocketChannel> connectWithOptionalHeaders(String url, Map<String, String> headers) async {
  if (headers.isEmpty) {
    return IOWebSocketChannel.connect(url);
  }
  final socket = await WebSocket.connect(url, headers: headers);
  return IOWebSocketChannel(socket);
}
