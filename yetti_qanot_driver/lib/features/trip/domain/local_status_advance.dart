import 'trip_status.dart';

/// Ordering of the driver-visible trip states. A server snapshot may only ever move
/// the UI *forward*; anything else is a stale read.
int tripStatusRank(TripStatus s) => switch (s) {
      TripStatus.waiting => 0,
      TripStatus.arrived => 1,
      TripStatus.started => 2,
      TripStatus.finished => 3,
    };

/// Holds the status a driver just tapped ("Yetib keldim", "Safarni boshlash") until the
/// server actually reports it.
///
/// Why this exists: the dispatch poll runs every few seconds and reports
/// `assigned_trip.status`. Between the action POST returning 200 and the backend
/// committing the new status, that poll still returns the OLD status. Applying it
/// blindly reverts the button under the driver's finger, so they tap again.
///
/// The advance is released **only** when:
///  * the server reports a status at least as advanced ([resolve] with a higher rank),
///  * the active trip changes ([resolve] with a different `tripId`), or
///  * the caller explicitly [clear]s it (the action failed and the UI was rolled back).
///
/// Deliberately **not** released by a timer, and **not** released just because the POST
/// succeeded — both were previously true and both produced the flip-flop. When the
/// server rejects a transition the app intentionally keeps (the pickup-proximity gate),
/// nothing will ever confirm it, so a timeout would guarantee a revert.
class LocalStatusAdvance {
  TripStatus? _status;
  String? _tripId;

  /// The optimistic status currently being held, if any.
  TripStatus? get status => _status;

  bool get isActive => _status != null;

  /// Record a driver-tapped status for [tripId].
  void note(TripStatus status, String? tripId) {
    _status = status;
    _tripId = tripId;
  }

  void clear() {
    _status = null;
    _tripId = null;
  }

  /// Reconcile a server-reported [serverStatus] for [tripId] against the held advance,
  /// returning the status the UI should display.
  TripStatus resolve(TripStatus serverStatus, String? tripId) {
    final held = _status;
    if (held == null) return serverStatus;

    // Different trip entirely — the advance is meaningless now.
    if (_tripId != tripId) {
      clear();
      return serverStatus;
    }

    // Server caught up (or moved past us): stop holding.
    if (tripStatusRank(serverStatus) >= tripStatusRank(held)) {
      clear();
      return serverStatus;
    }

    // Stale snapshot — keep showing what the driver did.
    return held;
  }
}
