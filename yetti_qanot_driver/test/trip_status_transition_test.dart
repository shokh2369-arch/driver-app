import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/core/geo/lat_lng.dart';
import 'package:yetti_qanot_driver/features/trip/domain/trip_request.dart';
import 'package:yetti_qanot_driver/features/trip/domain/trip_status.dart';
import 'package:yetti_qanot_driver/features/trip/presentation/trip_state.dart';
import 'package:yetti_qanot_driver/services/driver_dispatch_parser.dart';

const _p = MapLatLng(41.3, 69.2);

TripState _state(TripStatus status, {String? tripId = 't1', double odo = 0}) =>
    TripState(
      status: status,
      activeRequest: TripRequest(id: 'r1', pickup: _p, tripId: tripId),
      clientOdometerKm: odo,
    );

void main() {
  group('server status mapping drives the visible button', () {
    // waiting -> "Yetib keldim", arrived -> "Safarni boshlash",
    // started -> "Safarni tugatish". A bad mapping shows the wrong action.
    test('each server status maps to exactly one trip status', () {
      expect(parseServerTripStatus('WAITING'), TripStatus.waiting);
      expect(parseServerTripStatus('ARRIVED'), TripStatus.arrived);
      expect(parseServerTripStatus('STARTED'), TripStatus.started);
      expect(parseServerTripStatus('FINISHED'), TripStatus.finished);
    });

    test('mapping is case-insensitive', () {
      expect(parseServerTripStatus('arrived'), TripStatus.arrived);
      expect(parseServerTripStatus('Started'), TripStatus.started);
    });

    test('unknown status does not silently become WAITING', () {
      // The caller decides the fallback; the parser must report "unknown".
      expect(parseServerTripStatus('EN_ROUTE'), isNull);
      expect(parseServerTripStatus(''), isNull);
    });
  });

  group('odometer across transitions', () {
    test('resets on arrive, accumulates only while started', () {
      expect(_state(TripStatus.arrived).clientOdometerKm, 0);
      final started = _state(TripStatus.started, odo: 4.2);
      expect(started.clientOdometerKm, 4.2);
      // copyWith must carry it forward untouched unless explicitly reset.
      expect(started.copyWith(status: TripStatus.started).clientOdometerKm, 4.2);
      expect(started.copyWith(clientOdometerKm: 0).clientOdometerKm, 0);
    });
  });

  group('requiresContinuousLiveLocation across the transition chain', () {
    test('true from assignment through started, false once finished', () {
      expect(_state(TripStatus.waiting).requiresContinuousLiveLocation, isTrue);
      expect(_state(TripStatus.arrived).requiresContinuousLiveLocation, isTrue);
      expect(_state(TripStatus.started).requiresContinuousLiveLocation, isTrue);
      expect(_state(TripStatus.finished).requiresContinuousLiveLocation, isFalse);
    });

    test('queue-only offer (no trip id) does not demand continuous location', () {
      expect(
        _state(TripStatus.waiting, tripId: null).requiresContinuousLiveLocation,
        isFalse,
      );
    });
  });

  group('hasActiveTrip gates the action panel', () {
    test('panel-visible states', () {
      expect(_state(TripStatus.waiting).hasActiveTrip, isTrue);
      expect(_state(TripStatus.arrived).hasActiveTrip, isTrue);
      expect(_state(TripStatus.started).hasActiveTrip, isTrue);
      expect(_state(TripStatus.finished).hasActiveTrip, isFalse);
    });
  });

  group('fare completion popup after finish', () {
    test('carries fare and distance through', () {
      final s = _state(TripStatus.started).copyWith(
        status: TripStatus.finished,
        activeRequest: () => null,
        fareCompletionPopup: () =>
            const TripFareCompletionPopup(fareSom: 25000, distanceKm: 7.4),
      );
      expect(s.activeRequest, isNull);
      expect(s.fareCompletionPopup!.fareSom, 25000);
      expect(s.fareCompletionPopup!.distanceKm, 7.4);
      expect(s.hasActiveTrip, isFalse);
    });

    test('clearing the popup leaves the finished state intact', () {
      final s = _state(TripStatus.finished).copyWith(
        fareCompletionPopup: () => null,
      );
      expect(s.fareCompletionPopup, isNull);
      expect(s.status, TripStatus.finished);
    });
  });
}
