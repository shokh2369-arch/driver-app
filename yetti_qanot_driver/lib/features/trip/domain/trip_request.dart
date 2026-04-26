import '../../../core/geo/lat_lng.dart';

class TripRequest {
  const TripRequest({
    required this.id,
    required this.pickup,
    required this.destination,
    this.tripId,
    this.distanceKm,
    this.radiusKm,
    this.expiresAt,
    this.riderPhone,
    this.fareSom,
  });

  /// `request_id` from dispatch queue.
  final String id;
  final MapLatLng pickup;
  final MapLatLng destination;

  /// Server trip UUID — required for `/trip/*` after assignment.
  final String? tripId;

  final double? distanceKm;
  final double? radiusKm;
  final String? expiresAt;

  /// Rider / passenger phone when the API sends it (`rider_phone`, nested `rider.phone`, …).
  final String? riderPhone;

  /// Trip price in soʻm when present (`fare_som`, `price`, nested trip fields, …).
  final double? fareSom;

  TripRequest copyWith({
    String? id,
    MapLatLng? pickup,
    MapLatLng? destination,
    String? Function()? tripId,
    double? Function()? distanceKm,
    double? Function()? radiusKm,
    String? Function()? expiresAt,
    String? Function()? riderPhone,
    double? Function()? fareSom,
  }) {
    return TripRequest(
      id: id ?? this.id,
      pickup: pickup ?? this.pickup,
      destination: destination ?? this.destination,
      tripId: tripId != null ? tripId() : this.tripId,
      distanceKm: distanceKm != null ? distanceKm() : this.distanceKm,
      radiusKm: radiusKm != null ? radiusKm() : this.radiusKm,
      expiresAt: expiresAt != null ? expiresAt() : this.expiresAt,
      riderPhone: riderPhone != null ? riderPhone() : this.riderPhone,
      fareSom: fareSom != null ? fareSom() : this.fareSom,
    );
  }
}
