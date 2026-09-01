class MapLatLng {
  const MapLatLng(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// True when [latitude]/[longitude] are finite and within WGS84 ranges (flutter_map rejects NaN / out-of-range).
bool isValidGeoDegrees(double latitude, double longitude) {
  if (!latitude.isFinite || !longitude.isFinite) return false;
  if (latitude.abs() > 90.0 || longitude.abs() > 180.0) return false;
  return true;
}

bool isValidMapLatLng(MapLatLng? p) =>
    p != null && isValidGeoDegrees(p.latitude, p.longitude);
