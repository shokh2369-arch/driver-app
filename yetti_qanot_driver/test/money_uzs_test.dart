import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/core/formatting/money_uzs.dart';

void main() {
  test('groups thousands with spaces', () {
    expect(formatUzsSom(99670), "99 670 so'm");
    expect(formatUzsSom(0), "0 so'm");
    expect(formatUzsSom(-1500), "-1 500 so'm");
  });

  test('honours a localized currency suffix', () {
    expect(formatUzsSom(1000, suffix: 'сўм'), '1 000 сўм');
    expect(formatSomInt(2500, suffix: 'сўм'), '2 500 сўм');
  });

  test('non-finite server values render as a dash instead of throwing', () {
    expect(formatUzsSom(double.nan), '—');
    expect(formatUzsSom(double.infinity), '—');
    expect(formatUzsSom(double.negativeInfinity), '—');
    expect(formatDisplayFareSom(double.nan), '—');
    expect(formatUzsSomOrDash(double.nan), '—');
  });

  test('display fare rounds to the nearest 100 soʻm', () {
    expect(formatDisplayFareSom(12349), "12 300 so'm");
    expect(formatDisplayFareSom(12350), "12 400 so'm");
    expect(formatDisplayFareSom(null), '—');
  });
}
