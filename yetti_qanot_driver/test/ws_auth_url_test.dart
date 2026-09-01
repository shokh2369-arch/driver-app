import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/config.dart';

/// The production bug was WebSocket upgrades sent with no bearer token → 401 loop. These
/// assert every WS URL builder carries the token as `access_token=`, on every platform
/// (query is the portable mechanism; web can't set upgrade headers).
void main() {
  const token = 'TESTBEARERTOKEN123';

  group('every WS URL builder includes access_token when a token is given', () {
    test('dispatch socket', () {
      final url = AppConfig.wsUrlStringForDriverDispatch(
        driverIdForQuery: '4',
        accessToken: token,
      );
      expect(url, contains('access_token=$token'));
      expect(url, startsWith('wss://'));
      expect(url, contains('/ws/driver-dispatch'));
    });

    test('trip socket (string)', () {
      final url = AppConfig.wsUrlStringForTrip(
        'trip-uuid-1',
        driverIdForQuery: '4',
        accessToken: token,
      );
      expect(url, contains('access_token=$token'));
      expect(url, contains('trip_id=trip-uuid-1'));
      expect(url, startsWith('wss://'));
    });

    test('trip socket (uri)', () {
      final uri = AppConfig.wsUriForTrip(
        'trip-uuid-1',
        driverIdForQuery: '4',
        accessToken: token,
      );
      expect(uri.queryParameters['access_token'], token);
      expect(uri.queryParameters['trip_id'], 'trip-uuid-1');
      expect(uri.scheme, 'wss');
    });
  });

  group('no token → no access_token param (never an empty credential)', () {
    test('dispatch', () {
      final url = AppConfig.wsUrlStringForDriverDispatch(driverIdForQuery: '4');
      expect(url, isNot(contains('access_token')));
    });
    test('trip', () {
      final url = AppConfig.wsUrlStringForTrip('t', driverIdForQuery: '4');
      expect(url, isNot(contains('access_token')));
    });
    test('empty-string token is treated as no token', () {
      final url = AppConfig.wsUrlStringForDriverDispatch(
        driverIdForQuery: '4',
        accessToken: '',
      );
      expect(url, isNot(contains('access_token')));
    });
  });
}
