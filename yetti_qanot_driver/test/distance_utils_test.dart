import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/core/geo/lat_lng.dart';
import 'package:yetti_qanot_driver/features/trip/presentation/widgets/distance_utils.dart';

void main() {
  test('formatKm renders a dash for unknown / non-finite distances', () {
    expect(formatKm(null), '—');
    expect(formatKm(double.nan), '—');
    expect(formatKm(double.infinity), '—');
    expect(formatKm(0.25), '250 m');
    expect(formatKm(3.14), '3.1 km');
  });

  test('formatMinutes renders a dash for unknown ETAs', () {
    expect(formatMinutes(null), '—');
    expect(formatMinutes(double.nan), '—');
    expect(formatMinutes(0.4), '<1 min');
    expect(formatMinutes(12.6), '13 min');
  });

  test('haversineKm matches a known Tashkent distance', () {
    const a = MapLatLng(41.311081, 69.240562);
    const b = MapLatLng(41.351081, 69.240562);
    // 0.04° of latitude ≈ 4.45 km.
    expect(haversineKm(a, b), closeTo(4.45, 0.05));
    expect(haversineKm(a, a), closeTo(0, 1e-9));
  });

  test('bearingDegrees points north / east correctly', () {
    const origin = MapLatLng(41.0, 69.0);
    expect(bearingDegrees(origin, const MapLatLng(41.1, 69.0)), closeTo(0, 0.5));
    expect(bearingDegrees(origin, const MapLatLng(41.0, 69.1)), closeTo(90, 0.5));
  });

  test('isValidGeoDegrees rejects NaN and out-of-range values', () {
    expect(isValidGeoDegrees(41.0, 69.0), isTrue);
    expect(isValidGeoDegrees(double.nan, 69.0), isFalse);
    expect(isValidGeoDegrees(91.0, 69.0), isFalse);
    expect(isValidGeoDegrees(41.0, 181.0), isFalse);
  });
}
