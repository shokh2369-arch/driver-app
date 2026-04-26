import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/core/geo/lat_lng.dart';
import 'package:yetti_qanot_driver/features/trip/domain/trip_request.dart';
import 'package:yetti_qanot_driver/features/trip/domain/trip_status.dart';
import 'package:yetti_qanot_driver/features/trip/presentation/trip_state.dart';

MapLatLng get _p => const MapLatLng(41.3, 69.2);

void main() {
  test('requiresContinuousLiveLocation: queue-only waiting (no trip_id) is false', () {
    final s = TripState(
      status: TripStatus.waiting,
      activeRequest: TripRequest(id: 'q1', pickup: _p, destination: _p),
    );
    expect(s.requiresContinuousLiveLocation, false);
  });

  test('requiresContinuousLiveLocation: assigned waiting is true', () {
    final s = TripState(
      status: TripStatus.waiting,
      activeRequest: TripRequest(id: 'q1', pickup: _p, destination: _p, tripId: 'uuid-1'),
    );
    expect(s.requiresContinuousLiveLocation, true);
  });

  test('requiresContinuousLiveLocation: arrived/started without trip_id still true', () {
    var s = TripState(
      status: TripStatus.arrived,
      activeRequest: TripRequest(id: 'q1', pickup: _p, destination: _p),
    );
    expect(s.requiresContinuousLiveLocation, true);
    s = TripState(
      status: TripStatus.started,
      activeRequest: TripRequest(id: 'q1', pickup: _p, destination: _p),
    );
    expect(s.requiresContinuousLiveLocation, true);
  });

  test('requiresContinuousLiveLocation: finished is false', () {
    final s = TripState(
      status: TripStatus.finished,
      activeRequest: TripRequest(id: 'q1', pickup: _p, destination: _p, tripId: 'uuid-1'),
    );
    expect(s.requiresContinuousLiveLocation, false);
  });
}
