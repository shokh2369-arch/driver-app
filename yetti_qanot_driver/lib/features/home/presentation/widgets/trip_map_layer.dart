import 'package:flutter/widgets.dart';

import '../../../../core/geo/lat_lng.dart';
import '../../../trip/presentation/trip_state.dart';
import 'osm_trip_map.dart';

/// OpenStreetMap tiles via [flutter_map] (Leaflet-style), all platforms.
class TripMapLayer extends StatelessWidget {
  const TripMapLayer({
    super.key,
    required this.me,
    required this.trip,
    this.bottomOverlayInset = 0,
    this.carBearingDegrees = 0,
  });

  final MapLatLng? me;
  final TripState trip;
  final double bottomOverlayInset;

  /// Degrees clockwise from north — taxi marker rotation (mini-app bearing).
  final double carBearingDegrees;

  @override
  Widget build(BuildContext context) {
    return OsmTripMap(
      me: me,
      trip: trip,
      bottomOverlayInset: bottomOverlayInset,
      carBearingDegrees: carBearingDegrees,
    );
  }
}
