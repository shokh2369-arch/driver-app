import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/api_error_parser.dart';

DioException _err({int status = 400, Object? data}) => DioException(
      requestOptions: RequestOptions(path: '/trip/arrived'),
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/trip/arrived'),
        statusCode: status,
        data: data,
      ),
      type: DioExceptionType.badResponse,
    );

void main() {
  group('isPickupProximityRejection', () {
    test('matches structured proximity codes', () {
      for (final code in [
        'DRIVER_TOO_FAR',
        'MOVE_CLOSER',
        'PICKUP_DISTANCE_EXCEEDED',
        'PROXIMITY_REQUIRED',
      ]) {
        expect(
          isPickupProximityRejection(_err(data: {'code': code})),
          isTrue,
          reason: code,
        );
      }
    });

    test('matches localized proximity sentences', () {
      for (final msg in [
        'Mijozga yaqin bo‘ling',
        'Siz hali yetib bormagansiz',
        'Подъезжайте ближе к клиенту',
        'Вы далеко от точки подачи',
        'Мижозга яқин бўлинг',
        'You are not close enough to the pickup',
      ]) {
        expect(
          isPickupProximityRejection(_err(data: {'message': msg})),
          isTrue,
          reason: msg,
        );
      }
    });

    // The whole point of the tightened matcher: these must NOT be swallowed, or the
    // driver's UI advances to ARRIVED/STARTED while the server stays put.
    test('does not match unrelated business errors', () {
      for (final msg in [
        'Недостаточно средств на балансе',
        'Balansda 100 000 so‘m yetarli emas',
        'Время ожидания истекло',
        'Заказ уже отменён',
        'Trip already finished',
        'Комиссия не оплачена',
      ]) {
        expect(
          isPickupProximityRejection(_err(data: {'message': msg})),
          isFalse,
          reason: msg,
        );
      }
    });

    test('does not match unrelated codes or empty bodies', () {
      expect(
        isPickupProximityRejection(_err(data: {'code': 'INSUFFICIENT_BALANCE'})),
        isFalse,
      );
      expect(isPickupProximityRejection(_err(data: null)), isFalse);
      expect(isPickupProximityRejection(_err(data: {})), isFalse);
    });

    test('still matches the Telegram live-location deployment error', () {
      expect(
        isPickupProximityRejection(
          _err(data: {'code': 'Telegram jonli lokatsiyani yoqing'}),
        ),
        isTrue,
      );
    });
  });

  group('isSessionRevokedError', () {
    test('accepts known revocation codes on 401/403 only', () {
      expect(
        isSessionRevokedError(
          _err(status: 401, data: {'code': 'SESSION_REPLACED'}),
        ),
        isTrue,
      );
      expect(
        isSessionRevokedError(
          _err(status: 403, data: {'code': 'login-elsewhere'}),
        ),
        isTrue,
      );
      expect(
        isSessionRevokedError(
          _err(status: 500, data: {'code': 'SESSION_REPLACED'}),
        ),
        isFalse,
      );
      expect(
        isSessionRevokedError(_err(status: 401, data: {'code': 'NOT_FOUND'})),
        isFalse,
      );
    });
  });

  group('isLegalAcceptanceRequired', () {
    test('only on 403 with the exact code', () {
      expect(
        isLegalAcceptanceRequired(
          _err(status: 403, data: {'code': 'LEGAL_ACCEPTANCE_REQUIRED'}),
        ),
        isTrue,
      );
      expect(
        isLegalAcceptanceRequired(
          _err(status: 401, data: {'code': 'LEGAL_ACCEPTANCE_REQUIRED'}),
        ),
        isFalse,
      );
    });
  });

  group('isAuthFailure / isDriverNotApproved', () {
    test('any 401 is an auth failure (session dead)', () {
      expect(isAuthFailure(_err(status: 401, data: {'error': 'driver auth required'})), isTrue);
      expect(isAuthFailure(_err(status: 401, data: {'code': 'WHATEVER'})), isTrue);
    });
    test('non-401 is not an auth failure', () {
      expect(isAuthFailure(_err(status: 403, data: {'error': 'x'})), isFalse);
      expect(isAuthFailure(_err(status: 500, data: null)), isFalse);
    });
    test('403 not-approved is detected and is NOT an auth failure', () {
      final e = _err(status: 403, data: {'code': 'DRIVER_NOT_APPROVED'});
      expect(isDriverNotApproved(e), isTrue);
      expect(isAuthFailure(e), isFalse);
      expect(isSessionRevokedError(e), isFalse);
    });
    test('plain 403 is not "not approved"', () {
      expect(isDriverNotApproved(_err(status: 403, data: {'error': 'forbidden zone'})), isFalse);
    });
  });

  group('login error contract (request-code / verify-code)', () {
    test('isRateLimited: 429 or RATE_LIMITED/TOO_MANY code (the hung-but-landed OTP trap)', () {
      expect(isRateLimited(_err(status: 429, data: null)), isTrue);
      expect(isRateLimited(_err(status: 400, data: {'code': 'RATE_LIMITED'})), isTrue);
      expect(isRateLimited(_err(status: 400, data: {'code': 'TOO_MANY_REQUESTS'})), isTrue);
      expect(isRateLimited(_err(status: 400, data: {'code': 'INVALID_CODE'})), isFalse);
      expect(isRateLimited(_err(status: 500, data: null)), isFalse);
    });

    test('isInvalidCode: only INVALID_CODE (case/hyphen tolerant)', () {
      expect(isInvalidCode(_err(status: 400, data: {'code': 'INVALID_CODE'})), isTrue);
      expect(isInvalidCode(_err(status: 401, data: {'code': 'invalid-code'})), isTrue);
      expect(isInvalidCode(_err(status: 400, data: {'code': 'INVALID_PHONE'})), isFalse);
    });

    test('isDriverNotRegistered', () {
      expect(isDriverNotRegistered(_err(status: 403, data: {'code': 'DRIVER_NOT_REGISTERED'})), isTrue);
      expect(isDriverNotRegistered(_err(status: 404, data: {'code': 'driver-not-registered'})), isTrue);
      expect(isDriverNotRegistered(_err(status: 403, data: {'code': 'DRIVER_NOT_APPROVED'})), isFalse);
    });

    test('isInvalidPhone: only 400 INVALID_PHONE/INVALID_BODY', () {
      expect(isInvalidPhone(_err(status: 400, data: {'code': 'INVALID_PHONE'})), isTrue);
      expect(isInvalidPhone(_err(status: 400, data: {'code': 'INVALID_BODY'})), isTrue);
      expect(isInvalidPhone(_err(status: 403, data: {'code': 'INVALID_PHONE'})), isFalse);
      expect(isInvalidPhone(_err(status: 400, data: {'code': 'RATE_LIMITED'})), isFalse);
    });

    test('isServerError: 5xx only', () {
      expect(isServerError(_err(status: 502, data: null)), isTrue);
      expect(isServerError(_err(status: 500, data: null)), isTrue);
      expect(isServerError(_err(status: 429, data: null)), isFalse);
      expect(isServerError(_err(status: 400, data: null)), isFalse);
    });

    test('isTransportFailure: no HTTP response + transport type', () {
      DioException t(DioExceptionType type) => DioException(
            requestOptions: RequestOptions(path: '/auth/request-code'),
            type: type,
          );
      // The onrender edge hang: connection/timeout with no response.
      expect(isTransportFailure(t(DioExceptionType.connectionTimeout)), isTrue);
      expect(isTransportFailure(t(DioExceptionType.receiveTimeout)), isTrue);
      expect(isTransportFailure(t(DioExceptionType.connectionError)), isTrue);
      expect(isTransportFailure(t(DioExceptionType.unknown)), isTrue);
      // A real HTTP status is NOT a transport failure.
      expect(isTransportFailure(_err(status: 502, data: null)), isFalse);
      expect(isTransportFailure(t(DioExceptionType.cancel)), isFalse);
    });
  });

  group('describeDioFailure (log classification)', () {
    DioException typed(DioExceptionType t, {Object? error, int? status}) => DioException(
          requestOptions: RequestOptions(path: '/auth/request-code'),
          type: t,
          error: error,
          response: status == null
              ? null
              : Response<dynamic>(
                  requestOptions: RequestOptions(path: '/auth/request-code'),
                  statusCode: status),
        );

    test('timeouts', () {
      expect(describeDioFailure(typed(DioExceptionType.connectionTimeout)), 'timeout');
      expect(describeDioFailure(typed(DioExceptionType.receiveTimeout)), 'timeout');
    });
    test('canceled (the onrender edge hang shows as this in DevTools)', () {
      expect(describeDioFailure(typed(DioExceptionType.cancel)), 'canceled');
    });
    test('http status', () {
      expect(describeDioFailure(typed(DioExceptionType.badResponse, status: 502)), 'HTTP 502');
    });
    test('connection refused vs unreachable', () {
      expect(
        describeDioFailure(typed(DioExceptionType.connectionError, error: 'Connection refused')),
        'connection refused',
      );
      expect(
        describeDioFailure(typed(DioExceptionType.connectionError, error: 'SocketException: reset')),
        contains('unreachable'),
      );
    });
  });
}
