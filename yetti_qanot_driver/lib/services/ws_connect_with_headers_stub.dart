import 'package:web_socket_channel/web_socket_channel.dart';

/// Web / non-IO: custom headers cannot be attached to the upgrade request, so driver
/// auth travels in the query string instead (see `AppConfig.wsUriForTrip`).
///
/// Must not import `package:web_socket_channel/io.dart` — that library pulls in
/// `dart:io` and breaks the web build, which defeats this conditional import.
Future<WebSocketChannel> connectWithOptionalHeaders(
  String url,
  Map<String, String> headers,
) async =>
    WebSocketChannel.connect(Uri.parse(url));
