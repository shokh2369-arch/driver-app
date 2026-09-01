import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/auth_api_client.dart';

// The login screen now rejects anything that is not +998 followed by 9 digits before
// sending, to avoid burning an SMS + a (now atomic) lockout attempt on a typo. This mirrors
// that rule against AuthApiClient.normalizePhone.
final _uzMobile = RegExp(r'^\+998\d{9}$');

void main() {
  group('normalizePhone', () {
    test('9-digit local becomes +998…', () {
      expect(AuthApiClient.normalizePhone('901234567'), '+998901234567');
    });
    test('12-digit 998… gets a +', () {
      expect(AuthApiClient.normalizePhone('998901234567'), '+998901234567');
    });
    test('already E.164 passes through', () {
      expect(AuthApiClient.normalizePhone('+998901234567'), '+998901234567');
    });
    test('strips spaces', () {
      expect(AuthApiClient.normalizePhone(' 90 123 45 67 '), '+998901234567');
    });
  });

  group('valid Uzbek mobile gate', () {
    test('accepts normalized real numbers', () {
      for (final raw in ['901234567', '+998 90 123 45 67', '998901234567']) {
        expect(_uzMobile.hasMatch(AuthApiClient.normalizePhone(raw)), isTrue, reason: raw);
      }
    });
    test('rejects junk / wrong length / wrong country', () {
      for (final raw in ['12345', 'abcdef', '+1 555 0100', '99890123456', '9989012345678']) {
        expect(_uzMobile.hasMatch(AuthApiClient.normalizePhone(raw)), isFalse, reason: raw);
      }
    });
  });
}
