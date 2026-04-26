/// Build-time config (`flutter run --dart-define=KEY=value`).
///
/// Backend: `docs/DRIVER_HTTP_API_HANDOFF.md`, `DRIVER_CLIENT.md` (Go repo).
import 'package:flutter/foundation.dart' show kIsWeb;

class AppConfig {
  /// Optional override; if empty and [apiBaseUrl] is set, WS URL is derived (https→wss).
  static const wsUrl = String.fromEnvironment('WS_URL', defaultValue: '');

  /// Default production API; override with `--dart-define=API_BASE_URL=...` (no trailing slash).
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://taxi-2r2j.onrender.com',
  );

  /// Force showing the phone/SMS login screen even when a `driver_id` is saved locally.
  /// Useful for web demos / shared machines.
  static const forcePhoneLogin = bool.fromEnvironment('FORCE_PHONE_LOGIN', defaultValue: false);

  /// Native app mode (Android/iOS builds of this Flutter app).
  ///
  /// - Defaults to `true` for mobile builds and `false` for Flutter web.
  /// - Override with `--dart-define=IS_NATIVE_APP=true|false` if needed.
  ///
  /// When true, driver live location is posted to the app-only endpoint `/driver/location/app`.
  static const _isNativeAppDefine = bool.fromEnvironment('IS_NATIVE_APP', defaultValue: true);
  static bool get isNativeApp => _isNativeAppDefine && !kIsWeb;

  /// Extra location debugging: verbose logs + disable some client-side filters/throttles.
  /// Enable with `--dart-define=DEBUG_LOCATION=true`.
  static const debugLocation = bool.fromEnvironment('DEBUG_LOCATION', defaultValue: false);

  /// Native / debug driver auth — sent as `X-Driver-Id` when non-empty.
  static const driverId = String.fromEnvironment('DRIVER_ID', defaultValue: '');

  /// Telegram Web App init data — `X-Telegram-Init-Data` when non-empty.
  static const telegramInitData = String.fromEnvironment('TELEGRAM_INIT_DATA', defaultValue: '');

  /// Optional documented `GET` path on the **same** host as [apiBaseUrl] (must start with `/`)
  /// for wallet-shaped JSON when balances are not in `GET /driver/available-requests`.
  /// Do not set invented Mini paths — only routes the backend actually serves.
  static const driverWalletHttpPath = String.fromEnvironment('DRIVER_WALLET_HTTP_PATH', defaultValue: '');

  /// Dispatch / support line for the app-bar call button (`tel:`). E.164 with leading `+`.
  static const dispatchPhoneE164 = String.fromEnvironment(
    'DISPATCH_PHONE',
    defaultValue: '+998930718446',
  );

  /// OSRM-compatible **routing** base URL (no path), e.g. `https://router.project-osrm.org`.
  /// Set to empty to draw only a straight pickup→drop segment (no extra HTTP).
  /// On **web**, some hosts block CORS — use a proxy you control or a CORS-enabled OSRM instance.
  static const osrmRoutingBaseUrl = String.fromEnvironment(
    'OSRM_ROUTING_BASE_URL',
    defaultValue: 'https://router.project-osrm.org',
  );

  static bool get hasHttpApi => apiBaseUrl.isNotEmpty;

  /// Mirrors server **`ENABLE_DRIVER_HTTP_LIVE_LOCATION`**. Default **true**: native `POST /driver/location/app`
  /// should satisfy `live_location_active` / `last_live_location_at` (~90s) guards.
  ///
  /// Set `--dart-define=ENABLE_DRIVER_HTTP_LIVE_LOCATION=false` only when production is Telegram-live-only
  /// (see `docs/DRIVER_APP.md`). Must match the Go deployment (e.g. Render env).
  static const driverHttpLiveLocationEnabled = bool.fromEnvironment(
    'ENABLE_DRIVER_HTTP_LIVE_LOCATION',
    defaultValue: true,
  );

  /// WebSocket: `GET /ws?trip_id=…` — auth order matches backend: [telegramInitData] → query `init_data`;
  /// else [driverIdForQuery] / [driverId] → query `driver_id`. HTTP uses `X-Telegram-Init-Data` / `X-Driver-Id`.
  /// Uses [wsUrl] if set, else `/ws` on [apiBaseUrl] host.
  ///
  /// Normalizes `https://`/`http://` pasted into [wsUrl] to `wss`/`ws`, and drops **port 0** (which
  /// otherwise stringifies as `https://host:0/...` and breaks the socket handshake).
  static Uri wsUriForTrip(String tripId, {String? driverIdForQuery}) {
    if (apiBaseUrl.isEmpty && wsUrl.isEmpty) return Uri();

    final raw = wsUrl.isNotEmpty ? wsUrl.trim() : apiBaseUrl.trim();
    final parsed = Uri.parse(raw);

    final String wsScheme;
    switch (parsed.scheme.toLowerCase()) {
      case 'https':
      case 'wss':
        wsScheme = 'wss';
        break;
      case 'http':
      case 'ws':
        wsScheme = 'ws';
        break;
      default:
        wsScheme = 'wss';
    }

    String path = '/ws';
    if (wsUrl.isNotEmpty && parsed.path.isNotEmpty && parsed.path != '/') {
      path = parsed.path.startsWith('/') ? parsed.path : '/${parsed.path}';
    }

    final int? port;
    if (!parsed.hasPort) {
      port = null;
    } else {
      final p = parsed.port;
      if (p == 0) {
        port = null;
      } else if (wsScheme == 'wss' && p == 443) {
        port = null;
      } else if (wsScheme == 'ws' && p == 80) {
        port = null;
      } else {
        port = p;
      }
    }

    final base = Uri(
      scheme: wsScheme,
      host: parsed.host,
      port: port,
      path: path,
    );

    final did = (driverIdForQuery ?? driverId).trim();
    return _finalizeWebSocketUri(
      base.replace(
        queryParameters: {
          ...base.queryParameters,
          'trip_id': tripId,
          if (!isNativeApp && telegramInitData.isNotEmpty) 'init_data': telegramInitData,
          if (telegramInitData.isEmpty && did.isNotEmpty) 'driver_id': did,
        },
      ),
    );
  }

  static Uri _finalizeWebSocketUri(Uri u) {
    var scheme = u.scheme.toLowerCase();
    if (scheme == 'https') {
      scheme = 'wss';
    } else if (scheme == 'http') {
      scheme = 'ws';
    }

    final dropPort = !u.hasPort ||
        u.port == 0 ||
        (scheme == 'wss' && u.port == 443) ||
        (scheme == 'ws' && u.port == 80);

    return Uri(
      scheme: scheme,
      host: u.host,
      port: dropPort ? null : u.port,
      path: u.path.isEmpty ? '/ws' : u.path,
      queryParameters: u.queryParameters,
    );
  }

  /// [wsUriForTrip] as a string for `WebSocketChannel.connect`.
  ///
  /// Built manually (`scheme://host/path?query`) so Android/io does not stringify **`https://host:0/…`**
  /// from [Uri.toString] when the implicit TLS port is represented incorrectly.
  static String wsUrlStringForTrip(String tripId, {String? driverIdForQuery}) {
    final u = wsUriForTrip(tripId, driverIdForQuery: driverIdForQuery);
    if (u.host.isEmpty) return '';

    var scheme = u.scheme.toLowerCase();
    if (scheme == 'https' || scheme == 'wss') {
      scheme = 'wss';
    } else {
      scheme = 'ws';
    }

    final path = u.path.isEmpty ? '/ws' : (u.path.startsWith('/') ? u.path : '/${u.path}');
    final qm = u.queryParameters;
    final q = qm.isEmpty ? '' : '?${Uri(queryParameters: qm).query}';

    var host = u.host;
    int? port;
    if (u.hasPort && u.port != 0) {
      port = u.port;
    }
    if (port != null && ((scheme == 'wss' && port == 443) || (scheme == 'ws' && port == 80))) {
      port = null;
    }
    final authority = port != null ? '$host:$port' : host;
    return '$scheme://$authority$path$q';
  }
}

