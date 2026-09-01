import '../../../core/geo/lat_lng.dart';

class TripRequest {
  const TripRequest({
    required this.id,
    this.pickup,
    this.destination,
    this.tripId,
    this.distanceKm,
    this.radiusKm,
    this.expiresAt,
    this.riderPhone,
    this.fareSom,
    this.estimatedPriceSom = 0,
  });

  /// `request_id` from dispatch queue.
  final String id;

  /// Pickup coordinates, or **null** when the backend did not send them. Never
  /// substitute a placeholder here — the driver navigates to this point.
  final MapLatLng? pickup;

  /// Drop-off coordinates, or **null** when the backend did not send them.
  final MapLatLng? destination;

  /// Server trip UUID — required for `/trip/*` after assignment.
  final String? tripId;

  final double? distanceKm;
  final double? radiusKm;
  final String? expiresAt;

  /// Rider / passenger phone when the API sends it (`rider_phone`, nested `rider.phone`, …).
  final String? riderPhone;

  /// Trip price in soʻm when present (`fare_som`, `price`, nested trip fields, …).
  final double? fareSom;

  /// Approximate trip price from dispatch (`estimated_price`, int64 soʻm).
  /// Defaults to 0 when the backend omits it.
  final int estimatedPriceSom;

  TripRequest copyWith({
    String? id,
    MapLatLng? Function()? pickup,
    MapLatLng? Function()? destination,
    String? Function()? tripId,
    double? Function()? distanceKm,
    double? Function()? radiusKm,
    String? Function()? expiresAt,
    String? Function()? riderPhone,
    double? Function()? fareSom,
    int? estimatedPriceSom,
  }) {
    return TripRequest(
      id: id ?? this.id,
      pickup: pickup != null ? pickup() : this.pickup,
      destination: destination != null ? destination() : this.destination,
      tripId: tripId != null ? tripId() : this.tripId,
      distanceKm: distanceKm != null ? distanceKm() : this.distanceKm,
      radiusKm: radiusKm != null ? radiusKm() : this.radiusKm,
      expiresAt: expiresAt != null ? expiresAt() : this.expiresAt,
      riderPhone: riderPhone != null ? riderPhone() : this.riderPhone,
      fareSom: fareSom != null ? fareSom() : this.fareSom,
      estimatedPriceSom: estimatedPriceSom ?? this.estimatedPriceSom,
    );
  }
}
