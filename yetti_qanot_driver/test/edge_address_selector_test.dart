import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/resilient_http_client_io.dart';

void main() {
  final a = InternetAddress('216.24.57.7');
  final b = InternetAddress('216.24.57.15');
  const host = 'api.example';

  test('first pick is the first candidate; success makes it sticky', () {
    final s = EdgeAddressSelector();
    expect(s.pick(host, [a, b]), a);
    s.markGood(host, a);
    expect(
      s.pick(host, [b, a]),
      a,
      reason: 'sticky even when resolver order flips',
    );
  });

  test('a failed address is avoided and the other one becomes preferred', () {
    final s = EdgeAddressSelector();
    s.markBad(host, a);
    expect(s.pick(host, [a, b]), b);
    s.markGood(host, b);
    expect(s.pick(host, [a, b]), b);
  });

  test('a failed address is retried after badTtl', () {
    var now = DateTime(2026, 1, 1, 12);
    final s = EdgeAddressSelector(
      badTtl: const Duration(minutes: 2),
      now: () => now,
    );
    s.markBad(host, a);
    expect(s.pick(host, [a, b]), b);
    now = now.add(const Duration(minutes: 3));
    expect(
      s.pick(host, [a, b]),
      a,
      reason: 'ban expired, resolver order wins again',
    );
  });

  test('when every address failed, the least recently failed one is tried', () {
    var now = DateTime(2026, 1, 1, 12);
    final s = EdgeAddressSelector(now: () => now);
    s.markBad(host, a);
    now = now.add(const Duration(seconds: 30));
    s.markBad(host, b);
    expect(s.pick(host, [a, b]), a);
  });

  test('a failure on the preferred address drops the preference', () {
    final s = EdgeAddressSelector();
    s.markGood(host, a);
    s.markBad(host, a);
    expect(s.pick(host, [a, b]), b);
  });

  test('order() races the preferred address first and failed ones last', () {
    final s = EdgeAddressSelector();
    final c = InternetAddress('216.24.57.1');
    s.markGood(host, b);
    s.markBad(host, a);
    expect(s.order(host, [a, b, c]), [b, c, a]);
  });

  test('wss/ws URLs must dial 443/80, not Uri.port (which is 0 for them)', () {
    // Documents the assumption behind resilient_http_client_io.dart's port rule.
    expect(Uri.parse('wss://api.example/ws').port, 0);
    expect(Uri.parse('https://api.example/x').port, 443);
    expect(Uri.parse('wss://api.example:8443/ws').hasPort, isTrue);
  });

  test('isPreferred reflects the last successful address only', () {
    final s = EdgeAddressSelector();
    expect(s.isPreferred(host, a), isFalse);
    s.markGood(host, a);
    expect(s.isPreferred(host, a), isTrue);
    expect(s.isPreferred(host, b), isFalse);
    s.markBad(host, a);
    expect(s.isPreferred(host, a), isFalse, reason: 'a failure drops the preference');
  });

  test('hosts are tracked independently', () {
    final s = EdgeAddressSelector();
    s.markBad('one.example', a);
    expect(s.pick('two.example', [a, b]), a);
  });
}
