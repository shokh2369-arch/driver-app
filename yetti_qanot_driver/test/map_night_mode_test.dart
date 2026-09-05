import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/features/home/presentation/widgets/map_night_mode.dart';

void main() {
  // 12:00 UTC == 17:00 Tashkent.
  DateTime utc(int h, [int m = 0]) => DateTime.utc(2026, 9, 2, h, m);

  test('night starts at 17:00 Tashkent and ends at 06:00', () {
    expect(isMapNight(utc(11, 59)), isFalse, reason: '16:59 Tashkent');
    expect(isMapNight(utc(12, 0)), isTrue, reason: '17:00 Tashkent');
    expect(isMapNight(utc(18, 30)), isTrue, reason: '23:30 Tashkent');
    expect(
      isMapNight(DateTime.utc(2026, 9, 3, 0, 59)),
      isTrue,
      reason: '05:59 Tashkent',
    );
    expect(
      isMapNight(DateTime.utc(2026, 9, 3, 1, 0)),
      isFalse,
      reason: '06:00 Tashkent',
    );
    expect(isMapNight(utc(7)), isFalse, reason: '12:00 Tashkent');
  });

  test('phone time zone does not matter, only the instant', () {
    final local = DateTime(2026, 9, 2, 20, 0); // whatever zone the test runs in
    expect(isMapNight(local), isMapNight(local.toUtc()));
  });

  test('next change is the coming boundary', () {
    expect(nextMapNightChange(utc(10)), utc(12), reason: 'day → 17:00');
    expect(
      nextMapNightChange(utc(12)),
      DateTime.utc(2026, 9, 3, 1),
      reason: 'night → 06:00 next day',
    );
    expect(
      nextMapNightChange(DateTime.utc(2026, 9, 3, 0, 30)),
      DateTime.utc(2026, 9, 3, 1),
    );
  });

  test('custom window without midnight wrap', () {
    expect(
      isMapNight(utc(3), nightStartHour: 7, nightEndHour: 9),
      isTrue,
    ); // 08:00
    expect(
      isMapNight(utc(5), nightStartHour: 7, nightEndHour: 9),
      isFalse,
    ); // 10:00
  });
}
