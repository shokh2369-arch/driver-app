import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/api_error_parser.dart';

DioException _err(int status, Object? data) => DioException(
      requestOptions: RequestOptions(path: '/driver/accept-request'),
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/driver/accept-request'),
        statusCode: status,
        data: data,
      ),
      type: DioExceptionType.badResponse,
    );

void main() {
  group('isDriverHasActiveTripError', () {
    test('true for the new 409 code (any casing / dash form)', () {
      expect(isDriverHasActiveTripError(_err(409, {'error': 'driver_has_active_trip'})), isTrue);
      expect(isDriverHasActiveTripError(_err(409, {'code': 'DRIVER_HAS_ACTIVE_TRIP'})), isTrue);
      expect(isDriverHasActiveTripError(_err(409, {'code': 'driver-has-active-trip'})), isTrue);
    });

    // Must be distinguishable from "someone else took it" — that one still means
    // "no longer available", this one must route to the existing trip.
    test('false for request-taken and other 409s', () {
      expect(isDriverHasActiveTripError(_err(409, {'code': 'REQUEST_TAKEN'})), isFalse);
      expect(isDriverHasActiveTripError(_err(409, {'error': 'request no longer available'})), isFalse);
      expect(isDriverHasActiveTripError(_err(404, {'code': 'NOT_FOUND'})), isFalse);
      expect(isDriverHasActiveTripError(_err(409, null)), isFalse);
    });
  });

  group('activeTripIdFromError', () {
    test('extracts active_trip_id when present', () {
      final e = _err(409, {
        'error': 'driver_has_active_trip',
        'active_trip_id': 'cc961650-d9e9-4bf5-bb08-4ea2a1c4d2ad',
        'request_id': 'r1',
      });
      expect(activeTripIdFromError(e), 'cc961650-d9e9-4bf5-bb08-4ea2a1c4d2ad');
    });

    test('null when absent, empty, or non-map body', () {
      expect(activeTripIdFromError(_err(409, {'error': 'driver_has_active_trip'})), isNull);
      expect(activeTripIdFromError(_err(409, {'active_trip_id': '  '})), isNull);
      expect(activeTripIdFromError(_err(409, 'plain text body')), isNull);
    });
  });
}
