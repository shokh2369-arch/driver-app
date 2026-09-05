import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_error_parser.dart';
import 'config.dart';
import 'resilient_transport.dart';

/// Result of [AuthApiClient.verifyCode] — [sessionToken] is optional until the backend issues sessions.
class PhoneAuthResult {
  const PhoneAuthResult({required this.driverId, this.sessionToken});

  final String driverId;
  final String? sessionToken;
}

/// Unauthenticated calls (`POST /auth/*`) — **no** `X-Driver-Id` / Telegram headers.
class AuthApiClient {
  AuthApiClient({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  static Dio _createDio() {
    final base = AppConfig.apiBaseUrl;
    final dio = Dio(
      BaseOptions(
        baseUrl: base.endsWith('/') ? base.substring(0, base.length - 1) : base,
        // Explicit ~10 s ceiling on every auth call: the driver must not wait ~15 s per tap
        // while the onrender edge hangs. Fail early, then the reachability banner explains why.
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    // Native: sticky, raced edge-address connections; no-op on web.
    return withResilientTransport(dio);
  }

  /// E.164-friendly: `+998…` or `998…` or a 9-digit Uzbek mobile (`9XXXXXXXX`) → `+998…`.
  static String normalizePhone(String raw) {
    final trimmed = raw.trim().replaceAll(RegExp(r'\s'), '');
    if (trimmed.isEmpty) return '';
    final digitsOnly = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length == 9 && digitsOnly.startsWith('9')) {
      return '+998$digitsOnly';
    }
    if (digitsOnly.length == 12 && digitsOnly.startsWith('998')) {
      return '+$digitsOnly';
    }
    return trimmed;
  }

  /// `POST /auth/request-code` — body `{ "phone": "..." }`.
  Future<void> requestCode(String phone) async {
    final p = normalizePhone(phone);
    try {
      await _dio.post<void>('/auth/request-code', data: {'phone': p});
    } on DioException catch (e) {
      // Always log the target host + failure kind so a routing/edge outage (the recurring
      // onrender regional block) is obvious in the console, not hidden behind "Tarmoq xatosi".
      debugPrint(
        '[yetti_driver] POST ${_dio.options.baseUrl}/auth/request-code failed: '
        '${describeDioFailure(e)} '
        '(code=${parseDriverApiErrorCode(e) ?? '—'}, type=${e.type})',
      );
      rethrow;
    }
  }

  /// `POST /auth/verify-code` — body `{ "phone": "...", "code": "..." }`.
  /// Returns **`driver_id`** for `X-Driver-Id` and optional **`session_token`** (or `access_token` / `token`) for `X-Driver-Session`.
  Future<PhoneAuthResult> verifyCode(String phone, String code) async {
    final p = normalizePhone(phone);
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/auth/verify-code',
        data: {'phone': p, 'code': code.trim()},
      );
      final data = res.data ?? {};
      final id = data['driver_id'] ?? data['user_id'] ?? data['id'];
      final s = id?.toString().trim();
      if (s == null || s.isEmpty) {
        throw DioException(
          requestOptions: RequestOptions(path: '/auth/verify-code'),
          message: 'verify-code: missing driver_id in response',
          type: DioExceptionType.badResponse,
        );
      }
      return PhoneAuthResult(driverId: s, sessionToken: _parseSessionToken(data));
    } on DioException catch (e) {
      debugPrint(
        '[yetti_driver] POST ${_dio.options.baseUrl}/auth/verify-code failed: '
        '${describeDioFailure(e)} '
        '(code=${parseDriverApiErrorCode(e) ?? '—'}, type=${e.type})',
      );
      rethrow;
    }
  }

  static String? _parseSessionToken(Map<String, dynamic> data) {
    for (final key in ['session_token', 'driver_session', 'access_token', 'token']) {
      final v = data[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }
}
