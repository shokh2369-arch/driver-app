import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/driver_dispatch_parser.dart';

void main() {
  group('parseCommissionFromJson — the three states', () {
    test('normal: charged with a percent', () {
      final c = parseCommissionFromJson({
        'total_balance': 48080,
        'commission_percent': 5,
        'commission_charged': true,
      });
      expect(c, isNotNull);
      expect(c!.percent, 5);
      expect(c.charged, isTrue);
      expect(c.isOff, isFalse); // renders "Buyurtmadan 5%"
    });

    test('off via flag: charged=false is a real setting, reads as "no commission"', () {
      final c = parseCommissionFromJson({
        'commission_percent': 5,
        'commission_charged': false,
      });
      expect(c, isNotNull);
      expect(c!.isOff, isTrue);
    });

    test('off via zero: 0% reads as "no commission", not "0%"', () {
      final c = parseCommissionFromJson({
        'commission_percent': 0,
        'commission_charged': true,
      });
      expect(c, isNotNull);
      expect(c!.isOff, isTrue);
    });

    test('unknown: field absent → null (hide the row, never guess)', () {
      expect(parseCommissionFromJson({'total_balance': 48080}), isNull);
      expect(parseCommissionFromJson(const {}), isNull);
    });
  });

  group('parseCommissionFromJson — parsing details', () {
    test('accepts string/num percents and defaults charged to true when absent', () {
      final c = parseCommissionFromJson({'commission_percent': '7'});
      expect(c!.percent, 7);
      expect(c.charged, isTrue);
    });

    test('reads a data envelope', () {
      final c = parseCommissionFromJson({
        'data': {'commission_percent': 8, 'commission_charged': true},
      });
      expect(c!.percent, 8);
      expect(c.isOff, isFalse);
    });

    test('clamps out-of-range percents', () {
      expect(parseCommissionFromJson({'commission_percent': 150})!.percent, 100);
      expect(parseCommissionFromJson({'commission_percent': -3})!.percent, 0);
    });

    test('tolerates a non-numeric percent by returning null', () {
      expect(parseCommissionFromJson({'commission_percent': 'n/a'}), isNull);
    });
  });
}
