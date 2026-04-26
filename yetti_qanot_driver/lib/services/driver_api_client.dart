import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_error_parser.dart';
import 'config.dart';

typedef DriverForbiddenHandler = void Function(DioException error);
typedef DriverSessionRevokedHandler = void Function();

/// HTTP client for YettiQanot driver API — backend `docs/DRIVER_HTTP_API_HANDOFF.md`, `DRIVER_CLIENT.md`, `AUTH.md`.
/// Only public driver routes on the Go service — no `/mini/`, `/api/v1/`, etc., unless backend registers them.
///
/// Auth: [X-Driver-Id] (digits); optional [X-Driver-Session] (native phone login); optional [X-Telegram-Init-Data]. Do not log init data.
class DriverApiClient {
  DriverApiClient({
    required this.resolveDriverId,
    this.resolveSessionToken,
    this.onForbidden,
    this.onSessionRevoked,
    Dio? dio,
  }) : _dio = dio ?? _createDio(resolveDriverId, resolveSessionToken, onForbidden, onSessionRevoked);

  final String Function() resolveDriverId;
  final String Function()? resolveSessionToken;
  final DriverForbiddenHandler? onForbidden;
  final DriverSessionRevokedHandler? onSessionRevoked;

  final Dio _dio;

  static Dio _createDio(
    String Function() resolveDriverId,
    String Function()? resolveSessionToken,
    DriverForbiddenHandler? onForbidden,
    DriverSessionRevokedHandler? onSessionRevoked,
  ) {
    final base = AppConfig.apiBaseUrl;
    final dio = Dio(
      BaseOptions(
        baseUrl: base.endsWith('/') ? base.substring(0, base.length - 1) : base,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          var id = resolveDriverId().trim();
          if (id.isEmpty) id = AppConfig.driverId.trim();
          if (id.isNotEmpty) {
            options.headers['X-Driver-Id'] = id;
          }
          final session = resolveSessionToken?.call().trim() ?? '';
          if (session.isNotEmpty) {
            options.headers['X-Driver-Session'] = session;
          }
          final init = AppConfig.telegramInitData;
          // Native app flow must not send Telegram init data; backend uses TelegramUserID==0 to
          // bypass pickup proximity checks for "Yetib keldim".
          if (!AppConfig.isNativeApp && init.isNotEmpty) {
            options.headers['X-Telegram-Init-Data'] = init;
          }
          handler.next(options);
        },
        onError: (DioException e, handler) {
          if (isLegalAcceptanceRequired(e)) {
            onForbidden?.call(e);
          }
          if (isSessionRevokedError(e)) {
            onSessionRevoked?.call();
          }
          handler.next(e);
        },
      ),
    );
    return dio;
  }

  /// `GET /health` — optional connectivity (plain body, often `OK`).
  Future<String> getHealth() async {
    final res = await _dio.get<String>(
      '/health',
      options: Options(responseType: ResponseType.plain),
    );
    return (res.data ?? '').trim();
  }

  /// `GET /driver/available-requests`
  Future<Map<String, dynamic>> getAvailableRequests() async {
    final res = await _dio.get<Map<String, dynamic>>('/driver/available-requests');
    return res.data ?? {};
  }

  /// `GET /driver/promo-program` — dashboard promo JSON.
  Future<Map<String, dynamic>> getDriverPromoProgram() async {
    final res = await _dio.get<Map<String, dynamic>>('/driver/promo-program');
    return res.data ?? {};
  }

  /// `GET /driver/referral-status` — referral JSON.
  Future<Map<String, dynamic>> getDriverReferralStatus() async {
    final res = await _dio.get<Map<String, dynamic>>('/driver/referral-status');
    return res.data ?? {};
  }

  /// `GET /driver/referral-link` — link string or JSON with `link` / `url`.
  Future<String?> getDriverReferralLink() async {
    final res = await _dio.get<dynamic>('/driver/referral-link');
    final data = res.data;
    if (data is String) return data.trim().isEmpty ? null : data.trim();
    if (data is Map) {
      final link = data['link'] ?? data['url'] ?? data['referral_link'];
      final s = link?.toString().trim();
      return (s == null || s.isEmpty) ? null : s;
    }
    return null;
  }

  /// Optional extra GET on the **same** API host when documented (not a made-up Mini path).
  Future<Map<String, dynamic>> getRelativeJson(String path) async {
    final p = path.trim();
    if (!p.startsWith('/') || p.contains('..')) {
      throw ArgumentError('Invalid relative path: $path');
    }
    final res = await _dio.get<Map<String, dynamic>>(p);
    return res.data ?? {};
  }

  /// `POST /driver/accept-request` — `request_id` and/or `trip_id`.
  Future<Map<String, dynamic>> acceptRequest({String? requestId, String? tripId}) async {
    final body = <String, dynamic>{};
    if (requestId != null && requestId.isNotEmpty) body['request_id'] = requestId;
    if (tripId != null && tripId.isNotEmpty) body['trip_id'] = tripId;
    final res = await _dio.post<Map<String, dynamic>>('/driver/accept-request', data: body);
    return res.data ?? {};
  }

  /// `POST /driver/location` (web / Mini App) or **`POST /driver/location/app`** (native periodic pings).
  ///
  /// Set [useWebLocationPath] on native for **immediate** posts (e.g. before “Yetib keldim”) so the same route as
  /// Flutter web is used (`/driver/location`), matching backend live checks tied to that handler.
  Future<void> postDriverLocation({
    required double lat,
    required double lng,
    double? accuracy,
    DateTime? timestamp,
    bool useWebLocationPath = false,
  }) async {
    final body = <String, dynamic>{
      'lat': lat,
      'lng': lng,
    };
    if (accuracy != null) body['accuracy'] = accuracy;
    if (timestamp != null) {
      body['timestamp'] = timestamp.millisecondsSinceEpoch ~/ 1000;
    }
    final path = (!AppConfig.isNativeApp || useWebLocationPath)
        ? '/driver/location'
        : '/driver/location/app';
    try {
      await _dio.post<void>(path, data: body);
      if (kDebugMode) {
        debugPrint('[yetti_driver] POST $path HTTP ok');
      }
    } on DioException catch (e) {
      if (kDebugMode) {
        final sc = e.response?.statusCode;
        final code = parseDriverApiErrorCode(e);
        debugPrint(
          '[yetti_driver] POST $path failed (no secrets logged): '
          'HTTP ${sc ?? '—'} code=${code ?? '—'} type=${e.type}',
        );
      }
      rethrow;
    }
  }

  /// `POST /driver/offline` — optional body `{}`; **200** `{"ok":true}`. Same auth as other driver routes.
  /// Clears server online/live flags (Telegram “stop live” equivalent); stopping app location alone is not enough.
  Future<void> postDriverOffline() async {
    try {
      await _dio.post<Map<String, dynamic>>('/driver/offline', data: <String, dynamic>{});
    } on DioException catch (e) {
      if (kDebugMode) {
        final sc = e.response?.statusCode;
        final code = parseDriverApiErrorCode(e);
        debugPrint(
          '[yetti_driver] POST /driver/offline failed (no secrets logged): '
          'HTTP ${sc ?? '—'} code=${code ?? '—'} type=${e.type}',
        );
      }
      rethrow;
    }
  }

  /// Optional [lat]/[lng]/[accuracy]/[timestamp] help backends that validate pickup/start against
  /// the same coordinates just posted on `/driver/location/app` (parity with web + fresh fix).
  /// Extra JSON keys are ignored by strict unmarshalers in Go.
  Future<void> postTripArrived(
    String tripId, {
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? timestamp,
  }) async {
    final body = <String, dynamic>{'trip_id': tripId};
    if (AppConfig.isNativeApp &&
        AppConfig.driverHttpLiveLocationEnabled &&
        lat != null &&
        lng != null) {
      body['lat'] = lat;
      body['lng'] = lng;
      if (accuracy != null) body['accuracy'] = accuracy;
      if (timestamp != null) {
        body['timestamp'] = timestamp.millisecondsSinceEpoch ~/ 1000;
      }
    }
    await _dio.post<void>('/trip/arrived', data: body);
  }

  Future<void> postTripStart(
    String tripId, {
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? timestamp,
  }) async {
    final body = <String, dynamic>{'trip_id': tripId};
    if (AppConfig.isNativeApp &&
        AppConfig.driverHttpLiveLocationEnabled &&
        lat != null &&
        lng != null) {
      body['lat'] = lat;
      body['lng'] = lng;
      if (accuracy != null) body['accuracy'] = accuracy;
      if (timestamp != null) {
        body['timestamp'] = timestamp.millisecondsSinceEpoch ~/ 1000;
      }
    }
    await _dio.post<void>('/trip/start', data: body);
  }

  /// `POST /trip/finish` — driver completes trip; body `{ trip_id }` (parity with `/trip/start`).
  Future<void> postTripFinish(String tripId) async {
    await _dio.post<void>('/trip/finish', data: {'trip_id': tripId});
  }

  /// `POST /trip/cancel/driver` — driver cancel.
  Future<void> postTripCancelDriver(String tripId) async {
    await _dio.post<void>('/trip/cancel/driver', data: {'trip_id': tripId});
  }

  /// `GET /trip/:id` — trip UUID.
  Future<Map<String, dynamic>> getTrip(String tripId) async {
    final res = await _dio.get<Map<String, dynamic>>('/trip/$tripId');
    return res.data ?? {};
  }

  /// `GET /legal/active`
  Future<Map<String, dynamic>> getLegalActive() async {
    final res = await _dio.get<Map<String, dynamic>>('/legal/active');
    return res.data ?? {};
  }

  /// `POST /legal/accept`
  Future<void> postLegalAccept([Map<String, dynamic>? body]) async {
    await _dio.post<void>('/legal/accept', data: body ?? <String, dynamic>{});
  }
}
