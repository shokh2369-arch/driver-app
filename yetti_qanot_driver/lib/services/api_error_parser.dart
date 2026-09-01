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

/// The per-driver OTP cooldown was hit — the previous `request-code` **landed server-side**
/// even if it looked like it failed (hung client-side), so a code is already in the driver's
/// Telegram and the backend enforces a ~30 s cooldown. HTTP **429** or a `RATE_LIMITED` /
/// `TOO_MANY_REQUESTS` code. The app must treat this as "code already sent", not a failure.
bool isRateLimited(DioException e) {
  if (e.response?.statusCode == 429) return true;
  final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase().replaceAll('-', '_');
  return code.contains('RATE_LIMIT') || code.contains('TOO_MANY');
}

/// `verify-code` rejected the entered code as wrong (`INVALID_CODE`, HTTP 400/401). Distinct
/// from a network/server failure — surface it inline, don't offer "retry the request".
bool isInvalidCode(DioException e) {
  final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase().replaceAll('-', '_');
  return code == 'INVALID_CODE';
}

/// The phone number has no registered driver — route to the Telegram registration bot.
bool isDriverNotRegistered(DioException e) {
  final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase().replaceAll('-', '_');
  return code == 'DRIVER_NOT_REGISTERED';
}

/// The number was rejected as not a valid Uzbek mobile (`INVALID_PHONE` / `INVALID_BODY`,
/// HTTP 400) — an inline field error, not a transient failure.
bool isInvalidPhone(DioException e) {
  if (e.response?.statusCode != 400) return false;
  final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase().replaceAll('-', '_');
  return code == 'INVALID_PHONE' || code == 'INVALID_BODY';
}

/// True when the failure never reached an HTTP response (timeout / connection error / cancel),
/// i.e. a transport-level failure rather than a server status. These are the failures whose
/// message depends on whether the internet is up (backend-down vs offline).
bool isTransportFailure(DioException e) {
  if (e.response != null) return false;
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
    case DioExceptionType.badCertificate:
    case DioExceptionType.unknown:
      return true;
    case DioExceptionType.cancel:
    case DioExceptionType.badResponse:
      return false;
  }
}

/// True for a 5xx server status (backend reachable but erroring) → "Serverda nosozlik".
bool isServerError(DioException e) {
  final sc = e.response?.statusCode;
  return sc != null && sc >= 500;
}

/// A short, human classification of a failure for logs — so the next person sees the
/// cause immediately (timeout/canceled vs refused vs unreachable vs an HTTP status),
/// rather than a generic "Tarmoq xatosi". Pair it with the target URL when logging.
String describeDioFailure(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'timeout';
    case DioExceptionType.cancel:
      return 'canceled';
    case DioExceptionType.badResponse:
      return 'HTTP ${e.response?.statusCode ?? '?'}';
    case DioExceptionType.badCertificate:
      return 'bad certificate';
    case DioExceptionType.connectionError:
    case DioExceptionType.unknown:
      final err = (e.error?.toString() ?? e.message ?? '').toLowerCase();
      if (err.contains('refused')) return 'connection refused';
      if (err.contains('timed out') || err.contains('timeout')) return 'timeout';
      if (err.contains('cancel')) return 'canceled';
      // The onrender edge case: TCP/TLS never completes → no response, host unreachable.
      return 'connection failed (host unreachable / no response)';
  }
}

/// Any authenticated driver call that comes back **401** means the bearer token is no
/// longer valid — the session is dead (single-session login: another device revoked it, or
/// it expired). [DriverApiClient] only makes authenticated calls, so a 401 there is always
/// "log out", never "retry". (Login itself uses a separate client, so its 401s don't reach
/// this.)
bool isAuthFailure(DioException e) => e.response?.statusCode == 401;

/// 403 that specifically means the driver account isn't approved yet (registered, pending).
/// Distinct from a dead session — the token is valid, so do NOT log out; surface the
/// awaiting-approval state instead.
bool isDriverNotApproved(DioException e) {
  if (e.response?.statusCode != 403) return false;
  final blob = '${parseDriverApiErrorCode(e) ?? ''} ${parseDriverApiErrorMessage(e) ?? ''}'
      .toLowerCase();
  return blob.contains('not_approved') ||
      blob.contains('not approved') ||
      blob.contains('approval') ||
      blob.contains('tasdiq'); // uz "tasdiqlanmagan"
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

/// Phrases that only ever appear in the “you are not close enough to the pickup”
/// rejection. Deliberately specific: broader matching (a bare `100`, a lone Cyrillic
/// `м`) also hits unrelated failures such as “Недостаточно средств на балансе”, and
/// treating those as a proximity gate advances the trip locally while the server
/// never moved — the driver then believes they are ARRIVED/STARTED when they are not.
const _pickupProximityPhrases = <String>[
  'yaqin bo', // "mijozga yaqin bo‘ling"
  'yaqinroq',
  'hali yetib bormagansiz',
  'olib ketish nuqtasi',
  'pickup point',
  'too far from pickup',
  'not close enough',
  'подъезжайте ближе',
  'вы далеко',
  'слишком далеко',
  'метров до',
  'яқин бў', // uz-Cyrl "яқин бўлинг"
  'яқинроқ',
];

/// True when the backend rejected `/trip/arrived` or `/trip/start` purely because the
/// driver is not close enough to the pickup — the one rejection the product deliberately
/// treats as non-fatal. Everything else must surface to the driver.
bool isPickupProximityRejection(DioException e) {
  // Implementations vary: some return a structured `code`, others only a localized message.
  final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase();
  if (code.contains('CLOSER') ||
      code.contains('PROXIM') ||
      code.contains('TOO_FAR') ||
      code.contains('PICKUP_DISTANCE') ||
      code.contains('DISTANCE_')) {
    return true;
  }
  if (isTelegramLiveLocationBackendError(e)) return true;

  // Go sometimes puts the whole localized sentence in `code`, so scan both fields.
  final blob = '$code ${parseDriverApiErrorMessage(e) ?? ''}'.toLowerCase();
  if (blob.trim().isEmpty) return false;
  return _pickupProximityPhrases.any(blob.contains);
}

/// The driver already has an active trip and cannot accept another (backend 409
/// `driver_has_active_trip`). Distinct from "request taken" — the offer is still listed,
/// so the app must route to the existing trip, not show "no longer available".
bool isDriverHasActiveTripError(DioException e) {
  final code = (parseDriverApiErrorCode(e) ?? '').toLowerCase().replaceAll('-', '_');
  return code == 'driver_has_active_trip';
}

/// `active_trip_id` from a [isDriverHasActiveTripError] 409 body, when present.
String? activeTripIdFromError(DioException e) {
  final data = e.response?.data;
  if (data is Map) {
    final v = data['active_trip_id'];
    final s = v?.toString().trim();
    if (s != null && s.isNotEmpty) return s;
  }
  return null;
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
