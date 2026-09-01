import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/features/trip/domain/local_status_advance.dart';
import 'package:yetti_qanot_driver/features/trip/domain/trip_status.dart';

void main() {
  group('the reported bug: button changes, then reverts', () {
    // Driver taps "Yetib keldim". POST returns 200. The dispatch poll fires ~4s later
    // but the backend has not committed the status yet and still reports WAITING.
    // That snapshot must NOT drag the button back to "Yetib keldim".
    test('a stale WAITING poll does not revert a tapped ARRIVED', () {
      final adv = LocalStatusAdvance()..note(TripStatus.arrived, 't1');

      // Several stale polls in a row — the driver keeps seeing ARRIVED.
      for (var i = 0; i < 5; i++) {
        expect(adv.resolve(TripStatus.waiting, 't1'), TripStatus.arrived);
      }
      expect(adv.isActive, isTrue);
    });

    test('a stale ARRIVED poll does not revert a tapped STARTED', () {
      final adv = LocalStatusAdvance()..note(TripStatus.started, 't1');
      expect(adv.resolve(TripStatus.arrived, 't1'), TripStatus.started);
      expect(adv.resolve(TripStatus.waiting, 't1'), TripStatus.started);
    });

    // The old implementation released the hold after 30s, so a backend that never
    // reflects the change (e.g. it rejected on pickup proximity, which the app
    // deliberately ignores) reverted the button and restarted the tap loop.
    test('holds indefinitely — no timeout releases it', () {
      final adv = LocalStatusAdvance()..note(TripStatus.arrived, 't1');
      // 1000 stale polls stands in for "much longer than any timeout".
      for (var i = 0; i < 1000; i++) {
        expect(adv.resolve(TripStatus.waiting, 't1'), TripStatus.arrived);
      }
      expect(adv.status, TripStatus.arrived);
    });
  });

  group('release conditions', () {
    test('releases once the server reports the same status', () {
      final adv = LocalStatusAdvance()..note(TripStatus.arrived, 't1');
      expect(adv.resolve(TripStatus.arrived, 't1'), TripStatus.arrived);
      expect(adv.isActive, isFalse, reason: 'server caught up');
      // Subsequent snapshots now pass through untouched.
      expect(adv.resolve(TripStatus.waiting, 't1'), TripStatus.waiting);
    });

    test('releases when the server moves further ahead', () {
      final adv = LocalStatusAdvance()..note(TripStatus.arrived, 't1');
      expect(adv.resolve(TripStatus.started, 't1'), TripStatus.started);
      expect(adv.isActive, isFalse);
    });

    test('server FINISHED always wins', () {
      final adv = LocalStatusAdvance()..note(TripStatus.arrived, 't1');
      expect(adv.resolve(TripStatus.finished, 't1'), TripStatus.finished);
      expect(adv.isActive, isFalse);
    });

    test('releases when the active trip changes', () {
      final adv = LocalStatusAdvance()..note(TripStatus.started, 't1');
      expect(adv.resolve(TripStatus.waiting, 't2'), TripStatus.waiting);
      expect(adv.isActive, isFalse);
    });

    test('releases when the trip id becomes null', () {
      final adv = LocalStatusAdvance()..note(TripStatus.arrived, 't1');
      expect(adv.resolve(TripStatus.waiting, null), TripStatus.waiting);
      expect(adv.isActive, isFalse);
    });

    test('explicit clear (action failed, UI rolled back)', () {
      final adv = LocalStatusAdvance()..note(TripStatus.arrived, 't1');
      adv.clear();
      expect(adv.isActive, isFalse);
      expect(adv.resolve(TripStatus.waiting, 't1'), TripStatus.waiting);
    });
  });

  group('pass-through when nothing is held', () {
    test('server status is used verbatim', () {
      final adv = LocalStatusAdvance();
      expect(adv.isActive, isFalse);
      for (final s in TripStatus.values) {
        expect(adv.resolve(s, 't1'), s);
      }
    });
  });

  group('full arrive -> start -> finish sequence', () {
    test('never regresses across the whole chain', () {
      final adv = LocalStatusAdvance();
      var shown = TripStatus.waiting;

      // Tap ARRIVED, then two stale polls.
      adv.note(TripStatus.arrived, 't1');
      shown = adv.resolve(TripStatus.waiting, 't1');
      expect(shown, TripStatus.arrived);
      shown = adv.resolve(TripStatus.waiting, 't1');
      expect(shown, TripStatus.arrived);

      // Server catches up.
      shown = adv.resolve(TripStatus.arrived, 't1');
      expect(shown, TripStatus.arrived);

      // Tap STARTED, stale poll still says ARRIVED.
      adv.note(TripStatus.started, 't1');
      shown = adv.resolve(TripStatus.arrived, 't1');
      expect(shown, TripStatus.started);

      // Server catches up, then finishes.
      shown = adv.resolve(TripStatus.started, 't1');
      expect(shown, TripStatus.started);
      shown = adv.resolve(TripStatus.finished, 't1');
      expect(shown, TripStatus.finished);
    });
  });

  group('tripStatusRank', () {
    test('is strictly increasing along the trip lifecycle', () {
      expect(tripStatusRank(TripStatus.waiting), lessThan(tripStatusRank(TripStatus.arrived)));
      expect(tripStatusRank(TripStatus.arrived), lessThan(tripStatusRank(TripStatus.started)));
      expect(tripStatusRank(TripStatus.started), lessThan(tripStatusRank(TripStatus.finished)));
    });
  });
}
