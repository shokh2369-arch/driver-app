import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_error_parser.dart';
import 'config.dart';

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
    return Dio(
      BaseOptions(
        baseUrl: base.endsWith('/') ? base.substring(0, base.length - 1) : base,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Content-Type': 'application/json'},
      ),
    );
  }

  static String normalizePhone(String raw) {
    return raw.trim().replaceAll(RegExp(r'\s'), '');
  }

  /// `POST /auth/request-code` — body `{ "phone": "..." }`.
  Future<void> requestCode(String phone) async {
    final p = normalizePhone(phone);
    try {
      await _dio.post<void>('/auth/request-code', data: {'phone': p});
    } on DioException catch (e) {
      if (kDebugMode) {
        final sc = e.response?.statusCode;
        final code = parseDriverApiErrorCode(e);
        final msg = parseDriverApiErrorMessage(e);
        final extra = e.type == DioExceptionType.connectionError
            ? ' base=${_dio.options.baseUrl} msg=${e.message ?? '—'} err=${e.error}'
            : '';
        debugPrint(
          '[yetti_driver] POST /auth/request-code failed: HTTP ${sc ?? '—'} code=${code ?? '—'} '
          'detail=${msg ?? '—'} type=${e.type} phone=$p$extra',
        );
      }
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
      if (kDebugMode) {
        final sc = e.response?.statusCode;
        final code = parseDriverApiErrorCode(e);
        debugPrint(
          '[yetti_driver] POST /auth/verify-code failed: HTTP ${sc ?? '—'} code=${code ?? '—'} type=${e.type}',
        );
      }
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
