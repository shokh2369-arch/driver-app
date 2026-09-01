import 'dart:math';

import '../../../../core/geo/lat_lng.dart';

double haversineKm(MapLatLng a, MapLatLng b) {
  const r = 6371.0;
  double toRad(double d) => d * pi / 180.0;
  final dLat = toRad(b.latitude - a.latitude);
  final dLng = toRad(b.longitude - a.longitude);
  final lat1 = toRad(a.latitude);
  final lat2 = toRad(b.latitude);
  final h = sin(dLat / 2) * sin(dLat / 2) + sin(dLng / 2) * sin(dLng / 2) * cos(lat1) * cos(lat2);
  return 2 * r * asin(sqrt(h));
}

/// Renders [dash] when the distance is unknown (missing coordinates) or non-finite,
/// rather than showing a fabricated `0 m`.
String formatKm(double? km, {String dash = '—'}) {
  if (km == null || !km.isFinite) return dash;
  if (km < 1) return '${(km * 1000).round()} m';
  return '${km.toStringAsFixed(1)} km';
}

String formatMinutes(double? minutes, {String dash = '—'}) {
  if (minutes == null || !minutes.isFinite) return dash;
  if (minutes < 1) return '<1 min';
  return '${minutes.round()} min';
}

/// Initial bearing from [from] to [to], degrees clockwise from north (0–360).
double bearingDegrees(MapLatLng from, MapLatLng to) {
  final lat1 = from.latitude * pi / 180.0;
  final lat2 = to.latitude * pi / 180.0;
  final dLng = (to.longitude - from.longitude) * pi / 180.0;
  final y = sin(dLng) * cos(lat2);
  final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
  final br = atan2(y, x) * 180.0 / pi;
  return (br + 360.0) % 360.0;
}

