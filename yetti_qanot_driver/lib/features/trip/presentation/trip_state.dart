import '../../../core/geo/lat_lng.dart';

import '../domain/driver_balance.dart';
import '../domain/driver_dashboard_stats.dart';
import '../domain/trip_request.dart';
import '../domain/trip_status.dart';

/// Set when `GET /trip/:id` cannot hydrate the map (e.g. 404) — same idea as Mini App “Reja topilmadi”.
enum TripHydrationIssue {
  none,
  tripNotFound,
}

/// Shown once in a dialog after a completed trip ([TripController.clearFareCompletionPopup]).
class TripFareCompletionPopup {
  const TripFareCompletionPopup({this.fareSom, this.distanceKm});

  final double? fareSom;
  final double? distanceKm;
}

class TripState {
  const TripState({
    required this.status,
    required this.activeRequest,
    this.driverBalance,
    this.remoteLiveLocation,
    this.dashboardStats,
    this.referralLink,
    this.hydrationIssue = TripHydrationIssue.none,
    this.fareCompletionPopup,
    this.clientOdometerKm = 0,
  });

  final TripStatus status;
  final TripRequest? activeRequest;

  /// Yo‘nalshsiz taxi: safar **boshlangandan** keyin GPS bo‘yicha yig‘ilgan masofa (start→hozir), asosan UI.
  /// Backend `distance_km` bo‘lsa u ustun.
  final double clientOdometerKm;

  /// From `GET /driver/available-requests` when the API includes wallet fields.
  final DriverBalanceSnapshot? driverBalance;

  /// From WebSocket `driver_location_update` (e.g. other party live position).
  final MapLatLng? remoteLiveLocation;

  /// From `GET /driver/promo-program` and/or `GET /driver/referral-status` when parseable.
  final DriverDashboardStats? dashboardStats;

  /// From `GET /driver/referral-link` when present.
  final String? referralLink;

  final TripHydrationIssue hydrationIssue;

  /// Non-null after a normal completion (driver finish, WS `trip_finished`, poll FINISHED).
  final TripFareCompletionPopup? fareCompletionPopup;

  bool get hasActiveTrip => activeRequest != null && status != TripStatus.finished;

  /// True when the server expects **continuous** driver coordinates (assigned / in-progress trip).
  /// Used to avoid auto-[OFFLINE] on brief backgrounding and to tighten HTTP location cadence (~90s server guard).
  bool get requiresContinuousLiveLocation {
    if (activeRequest == null || status == TripStatus.finished) return false;
    final tid = activeRequest!.tripId?.trim();
    if (tid != null && tid.isNotEmpty) return true;
    return status == TripStatus.arrived || status == TripStatus.started;
  }

  List<MapLatLng> routePoints() {
    final req = activeRequest;
    if (req == null) return const [];

    // "Route" without external Directions API: draw straight segments.
    return [req.pickup, req.destination];
  }

  TripState copyWith({
    TripStatus? status,
    TripRequest? Function()? activeRequest,
    DriverBalanceSnapshot? Function()? driverBalance,
    MapLatLng? Function()? remoteLiveLocation,
    DriverDashboardStats? Function()? dashboardStats,
    String? Function()? referralLink,
    TripHydrationIssue? hydrationIssue,
    TripFareCompletionPopup? Function()? fareCompletionPopup,
    double? clientOdometerKm,
  }) {
    return TripState(
      status: status ?? this.status,
      activeRequest: activeRequest != null ? activeRequest() : this.activeRequest,
      driverBalance: driverBalance != null ? driverBalance() : this.driverBalance,
      remoteLiveLocation: remoteLiveLocation != null ? remoteLiveLocation() : this.remoteLiveLocation,
      dashboardStats: dashboardStats != null ? dashboardStats() : this.dashboardStats,
      referralLink: referralLink != null ? referralLink() : this.referralLink,
      hydrationIssue: hydrationIssue ?? this.hydrationIssue,
      fareCompletionPopup:
          fareCompletionPopup != null ? fareCompletionPopup() : this.fareCompletionPopup,
      clientOdometerKm: clientOdometerKm ?? this.clientOdometerKm,
    );
  }
}
