import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/driver_dispatch_parser.dart';

void main() {
  test('parseDriverBalanceFromDispatchJson reads top-level keys', () {
    final b = parseDriverBalanceFromDispatchJson({
      'total_balance': 99670,
      'promo_balance': 0,
      'cash_balance': 99670,
    });
    expect(b, isNotNull);
    expect(b!.totalSom, 99670);
    expect(b.promoSom, 0);
    expect(b.cashSom, 99670);
  });

  test('parseDriverBalanceFromDispatchJson merges data envelope', () {
    final b = parseDriverBalanceFromDispatchJson({
      'data': {'balance': '12 345', 'promo': '0'},
    });
    expect(b, isNotNull);
    expect(b!.totalSom, 12345);
    expect(b.promoSom, 0);
  });

  test('parseDriverBalanceFromDispatchJson returns null when absent', () {
    expect(parseDriverBalanceFromDispatchJson({'requests': []}), isNull);
  });

  test('parseDriverBalanceFromDispatchJson reads nested stats', () {
    final b = parseDriverBalanceFromDispatchJson({
      'available_requests': [],
      'stats': {'cash_balance': 100, 'promo_balance': 50},
    });
    expect(b, isNotNull);
    expect(b!.cashSom, 100);
    expect(b.promoSom, 50);
    expect(b.totalSom, 150);
  });

  test('infers total from promo alone when total_balance absent', () {
    final b = parseDriverBalanceFromDispatchJson({
      'promo_balance': 18915,
    });
    expect(b, isNotNull);
    expect(b!.promoSom, 18915);
    expect(b.cashSom, isNull);
    expect(b.totalSom, 18915);
  });

  test('tiyin suffix scales down', () {
    final b = parseDriverBalanceFromDispatchJson({'balance_tiyin': 9967000});
    expect(b!.totalSom, 99670);
  });

  // Regression: the alias list was overwriting instead of taking the first match, so a
  // trailing `*_tiyin` key silently beat the explicit soʻm total.
  test('first matching total alias wins over later ones', () {
    final b = parseDriverBalanceFromDispatchJson({
      'total_balance': 99670,
      'balance_tiyin': 1,
    });
    expect(b!.totalSom, 99670);
  });

  test('promo and cash also take the first matching alias', () {
    final b = parseDriverBalanceFromDispatchJson({
      'promo_balance': 500,
      'promo_tiyin': 1,
      'cash_balance': 700,
      'cash_tiyin': 1,
    });
    expect(b!.promoSom, 500);
    expect(b.cashSom, 700);
    expect(b.totalSom, 1200);
  });

  test('wallet block does not override an explicit top-level total', () {
    final b = parseDriverBalanceFromDispatchJson({
      'total_balance': 1000,
      'wallet': {'total': 5},
    });
    expect(b!.totalSom, 1000);
  });

  test('parses string amounts with separators', () {
    final b = parseDriverBalanceFromDispatchJson({'balance': '1 234,50'});
    expect(b!.totalSom, closeTo(1234.5, 1e-9));
  });
}
