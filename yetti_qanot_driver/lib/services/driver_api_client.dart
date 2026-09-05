import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_error_parser.dart';
import 'config.dart';
import 'resilient_transport.dart';

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
        // Keep API interactions snappy on flaky/cold hosts: fail fast and let UI retry,
        // instead of stalling the driver on every tap.
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 10),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    // Native: sticky, raced edge-address connections (one dead Render/Cloudflare
    // IP must not turn every request into a coin toss). No-op on web.
    withResilientTransport(dio);
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
          } else if (isAuthFailure(e) || isSessionRevokedError(e)) {
            // 401 (or an explicit revocation code) = the session is gone. Clear it and
            // route to login instead of retrying a doomed request forever.
            onSessionRevoked?.call();
          }
          // 403 "driver not approved" is intentionally NOT a logout — the token is valid;
          // the account is pending. Left to the caller/poll to surface.
          handler.next(e);
        },
      ),
    );
    return dio;
  }

  /// Release the underlying connection pool (provider disposal / sign-out).
  void close() => _dio.close(force: true);

  /// `GET /health` — optional connectivity (plain body, often `OK`).
  Future<String> getHealth() async {
    final res = await _dio.get<String>(
      '/health',
      options: Options(responseType: ResponseType.plain),
    );
    return (res.data ?? '').trim();
  }

  /// `POST /driver/online` — clears the server's `manual_offline` flag so dispatch
  /// resumes. Required on the ONLINE toggle: location pings **no longer** clear it, so
  /// without this a driver who ever tapped OFFLINE stays offline forever.
  /// 200 `{"ok":true,"manual_offline":false}`; 401 driver auth required.
  Future<void> postDriverOnline() async {
    try {
      await _dio.post<Map<String, dynamic>>('/driver/online', data: <String, dynamic>{});
    } on DioException catch (e) {
      if (kDebugMode) {
        final sc = e.response?.statusCode;
        final code = parseDriverApiErrorCode(e);
        debugPrint(
          '[yetti_driver] POST /driver/online failed (no secrets logged): '
          'HTTP ${sc ?? '—'} code=${code ?? '—'} type=${e.type}',
        );
      }
      rethrow;
    }
  }

  /// `GET /driver/available-requests`.
  ///
  /// [waitSec] enables server-side **long polling**: the request blocks up to that many
  /// seconds and returns as soon as dispatch changes. The per-request `receiveTimeout` is
  /// widened past [waitSec] so the socket is not torn down mid-wait (the client default is
  /// only 20s). A backend that predates long poll simply ignores the query and returns
  /// immediately — the caller floors the loop so that does not become a busy-spin.
  Future<Map<String, dynamic>> getAvailableRequests({int? waitSec}) async {
    Options? options;
    Map<String, dynamic>? query;
    if (waitSec != null && waitSec > 0) {
      query = {'wait_sec': waitSec};
      options = Options(
        receiveTimeout: Duration(seconds: waitSec + 15),
      );
    }
    final res = await _dio.get<Map<String, dynamic>>(
      '/driver/available-requests',
      queryParameters: query,
      options: options,
    );
    return res.data ?? {};
  }

  /// Driver trip history — **`GET /driver/trips`** (same auth as **`GET /driver/available-requests`**).
  /// Optional [limit] is sent as **`limit`** query (clamped **1–100**; omit to use server default **50**).
  /// Optional [offset] is sent as **`offset`** (must be **≥ 0**; omit for server default **0**).
  /// Override path with `DRIVER_TRIP_HISTORY_HTTP_PATH` when the backend uses a different route.
  Future<dynamic> getDriverTripHistory({int? limit, int? offset}) async {
    var path = AppConfig.driverTripHistoryHttpPath.trim();
    if (path.isEmpty) path = '/driver/trips';
    if (!path.startsWith('/') || path.contains('..')) {
      throw ArgumentError('Invalid DRIVER_TRIP_HISTORY_HTTP_PATH: $path');
    }
    final query = <String, dynamic>{};
    if (limit != null) {
      query['limit'] = limit.clamp(1, 100);
    }
    if (offset != null && offset >= 0) {
      query['offset'] = offset;
    }
    final res = await _dio.get<dynamic>(
      path,
      queryParameters: query.isEmpty ? null : query,
    );
    return res.data;
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

  /// Driver location — native posts **both** routes for dispatch parity with Telegram / Mini App:
  ///
  /// - **`POST /driver/location`** — same as web; backend often ties `live_location_active` / dispatch pool to this handler.
  /// - **`POST /driver/location/app`** — `app_last_seen_at` / `app_lat` / `app_lng` (effective location when fresh).
  ///
  /// Periodic native sync previously used only `/driver/location/app`, so drivers could poll dispatch but stay
  /// ineligible until Telegram live location was active.
  Future<void> postDriverLocation({
    required double lat,
    required double lng,
    double? accuracy,
    DateTime? timestamp,
  }) async {
    final body = <String, dynamic>{
      'lat': lat,
      'lng': lng,
    };
    if (accuracy != null) body['accuracy'] = accuracy;
    if (timestamp != null) {
      body['timestamp'] = timestamp.millisecondsSinceEpoch ~/ 1000;
    }

    final paths = AppConfig.isNativeApp
        ? const ['/driver/location', '/driver/location/app']
        : const ['/driver/location'];

    // Fire both routes CONCURRENTLY. Posting them one after the other doubled the
    // latency of every location sync — and of the trip actions that wait on one —
    // for no benefit: the two endpoints are independent.
    final results = await Future.wait(
      paths.map((path) async {
        try {
          final res = await _dio.post<void>(path, data: body);
          if (kDebugMode) {
            debugPrint('[yetti_driver] POST $path HTTP ok status=${res.statusCode ?? '—'}');
          }
          return null;
        } on DioException catch (e) {
          if (kDebugMode) {
            final sc = e.response?.statusCode;
            final code = parseDriverApiErrorCode(e);
            debugPrint(
              '[yetti_driver] POST $path failed (no secrets logged): '
              'HTTP ${sc ?? '—'} code=${code ?? '—'} type=${e.type}',
            );
          }
          return e;
        }
      }),
    );

    // Only the primary route's failure is fatal, same as before.
    final primaryError = results.first;
    if (primaryError != null) throw primaryError;
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
  ///
  /// MUST stay on the authenticated [_dio]: the endpoint answers anonymous callers too but
  /// omits rider/driver phone numbers for them. The request interceptor attaches
  /// `X-Driver-Id` / `X-Driver-Session`, so the rider phone (shown on the trip screen so
  /// the driver can call) is only returned because this call carries driver auth. Do not
  /// route this through an unauthenticated client.
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
