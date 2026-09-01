import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/services/driver_dispatch_parser.dart';

void main() {
  group('tripRequestFromTripJson', () {
    test('keeps real coordinates', () {
      final r = tripRequestFromTripJson({
        'id': 'trip-1',
        'pickup_lat': 41.3111,
        'pickup_lng': 69.2406,
        'dropoff_lat': 41.35,
        'dropoff_lng': 69.30,
      }, requestId: 'req-1');

      expect(r.tripId, 'trip-1');
      expect(r.pickup!.latitude, closeTo(41.3111, 1e-9));
      expect(r.destination!.longitude, closeTo(69.30, 1e-9));
    });

    test('missing pickup stays null instead of falling back to city centre', () {
      final r = tripRequestFromTripJson({'id': 'trip-1'}, requestId: 'req-1');
      expect(r.pickup, isNull);
      expect(r.destination, isNull);
    });

    test('missing dropoff does not synthesise an offset destination', () {
      final r = tripRequestFromTripJson({
        'id': 'trip-1',
        'pickup_lat': 41.0,
        'pickup_lng': 69.0,
      }, requestId: 'req-1');
      expect(r.pickup, isNotNull);
      expect(r.destination, isNull);
    });

    test('reads nested pickup / destination objects', () {
      final r = tripRequestFromTripJson({
        'trip': {
          'id': 'trip-9',
          'pickup': {'lat': 41.1, 'lng': 69.1},
          'destination': {'latitude': 41.2, 'longitude': 69.2},
        },
      }, requestId: 'req-9');
      expect(r.tripId, 'trip-9');
      expect(r.pickup!.latitude, closeTo(41.1, 1e-9));
      expect(r.destination!.latitude, closeTo(41.2, 1e-9));
    });
  });

  group('tripRequestFromQueueItem', () {
    QueueOfferItem item(Map<String, dynamic> raw) => parseAvailableRequests({
          'available_requests': [raw],
        }).queueItems.single;

    test('destination is null when the queue row has no drop coords', () {
      final r = tripRequestFromQueueItem(item({
        'request_id': 'r1',
        'pickup_lat': 41.0,
        'pickup_lng': 69.0,
      }));
      expect(r.pickup, isNotNull);
      expect(r.destination, isNull);
    });

    test('destination is used when the queue row provides it', () {
      final r = tripRequestFromQueueItem(item({
        'request_id': 'r1',
        'pickup_lat': 41.0,
        'pickup_lng': 69.0,
        'dropoff_lat': 41.5,
        'dropoff_lng': 69.5,
      }));
      expect(r.destination!.latitude, closeTo(41.5, 1e-9));
    });
  });

  group('parseAvailableRequests', () {
    test('skips rows without pickup coordinates', () {
      final snap = parseAvailableRequests({
        'available_requests': [
          {'request_id': 'no-coords'},
          {'request_id': 'ok', 'pickup_lat': 41.0, 'pickup_lng': 69.0},
        ],
      });
      expect(snap.queueItems.map((q) => q.requestId), ['ok']);
    });

    test('deduplicates the same request across alias keys', () {
      final snap = parseAvailableRequests({
        'available_requests': [
          {'request_id': 'r1', 'pickup_lat': 41.0, 'pickup_lng': 69.0},
        ],
        'orders': [
          {'request_id': 'r1', 'pickup_lat': 41.0, 'pickup_lng': 69.0},
        ],
      });
      expect(snap.queueItems.length, 1);
    });

    test('reads assigned trip envelope', () {
      final snap = parseAvailableRequests({
        'assigned_trip': {'trip_id': 't1', 'status': 'STARTED'},
      });
      expect(snap.assignedTripId, 't1');
      expect(snap.assignedTripStatus, 'STARTED');
    });
  });

  group('parseServerTripStatus', () {
    test('maps known statuses and rejects the rest', () {
      expect(parseServerTripStatus('started')?.name, 'started');
      expect(parseServerTripStatus('FINISHED')?.name, 'finished');
      expect(parseServerTripStatus('SOMETHING_ELSE'), isNull);
      expect(parseServerTripStatus(null), isNull);
    });
  });

  group('tripStatusStringFromJson', () {
    test('reads flat status / trip_status', () {
      expect(tripStatusStringFromJson({'status': 'STARTED'}), 'STARTED');
      expect(tripStatusStringFromJson({'trip_status': 'ARRIVED'}), 'ARRIVED');
    });

    test('reads nested trip and data envelopes', () {
      expect(tripStatusStringFromJson({'trip': {'status': 'FINISHED'}}), 'FINISHED');
      expect(tripStatusStringFromJson({'data': {'trip_status': 'WAITING'}}), 'WAITING');
    });

    test('null when no status anywhere', () {
      expect(tripStatusStringFromJson({'id': 't1'}), isNull);
    });

    test('composes with parseServerTripStatus across the chain', () {
      for (final s in ['WAITING', 'ARRIVED', 'STARTED', 'FINISHED']) {
        expect(parseServerTripStatus(tripStatusStringFromJson({'trip': {'status': s}}))?.name,
            s.toLowerCase());
      }
    });
  });
}
