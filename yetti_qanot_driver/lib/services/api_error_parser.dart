import 'package:dio/dio.dart';

/// Parses JSON error bodies from the Go API (snake_case / `code` / `error` / `message`).
String? parseDriverApiErrorCode(DioException e) {
  final data = e.response?.data;
  if (data is Map) {
    final c = data['code'];
    if (c != null) return c.toString();
    final err = data['error'];
    if (err is String) return err;
  }
  return null;
}

/// Human-readable detail when the server sends one; never includes secrets.
String? parseDriverApiErrorMessage(DioException e) {
  final data = e.response?.data;
  if (data is Map) {
    final m = data['message'] ?? data['detail'] ?? data['reason'];
    if (m != null) return m.toString();
    final err = data['error'];
    if (err is String && err.length < 500) return err;
  }
  return null;
}

bool isLegalAcceptanceRequired(DioException e) {
  if (e.response?.statusCode != 403) return false;
  final code = parseDriverApiErrorCode(e);
  return code == 'LEGAL_ACCEPTANCE_REQUIRED';
}

/// Server rejected the device session (e.g. driver logged in on another phone). Backend should return
/// one of these `code` values with HTTP **401** or **403** after issuing a new session on verify-code.
bool isSessionRevokedError(DioException e) {
  final sc = e.response?.statusCode;
  if (sc != 401 && sc != 403) return false;
  final raw = (parseDriverApiErrorCode(e) ?? '').trim().toUpperCase().replaceAll('-', '_');
  const revoked = {
    'SESSION_REPLACED',
    'SESSION_INVALIDATED',
    'SESSION_INVALID',
    'LOGIN_ELSEWHERE',
    'AUTH_SESSION_EXPIRED',
  };
  return revoked.contains(raw);
}

/// Backend still enforcing Telegram “live location” while the native app uses `/driver/location/app`.
/// The message often lands in JSON `code` (full localized sentence) or in the response body string.
bool isTelegramLiveLocationBackendError(DioException e) {
  final sc = e.response?.statusCode;
  if (sc == null || sc < 400 || sc >= 500) return false;

  final parts = <String>[
    parseDriverApiErrorCode(e) ?? '',
    parseDriverApiErrorMessage(e) ?? '',
  ];
  final data = e.response?.data;
  if (data is String && data.trim().isNotEmpty) {
    parts.add(data);
  }
  final blob = parts.join(' ').toLowerCase();
  if (blob.isEmpty) return false;

  if (blob.contains('telegram') &&
      (blob.contains('локац') ||
          blob.contains('lokats') ||
          blob.contains('жонли') ||
          blob.contains('jonli') ||
          blob.contains('live'))) {
    return true;
  }
  if (blob.contains('телеграм') &&
      (blob.contains('локац') || blob.contains('lokats') || blob.contains('жонли'))) {
    return true;
  }
  if (blob.contains('жонли') && blob.contains('локац')) return true;
  return false;
}
