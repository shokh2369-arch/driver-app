import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/formatting/money_uzs.dart';
import '../../../core/theme/ios_tokens.dart';
import '../../../core/geo/lat_lng.dart' show MapLatLng, isValidGeoDegrees;
import '../../../core/localization/arb/app_localizations.dart';
import '../../../services/api_error_parser.dart';
import '../../../services/config.dart';
import '../../../services/trip_live_location_messages.dart';
import '../../../services/driver_user_exception.dart';
import '../../../services/service_providers.dart';
import '../../driver/domain/driver_status.dart';
import '../../driver/presentation/driver_id_controller.dart';
import '../../driver/presentation/driver_location_sync_controller.dart';
import '../../driver/presentation/driver_status_controller.dart';
import '../../trip/domain/trip_status.dart';
import '../../trip/presentation/trip_controller.dart';
import '../../trip/presentation/trip_state.dart';
import '../../trip/presentation/widgets/distance_utils.dart'
    show bearingDegrees, haversineKm;
import '../../trip/presentation/widgets/trip_status_banner.dart';
import 'location_gate_controller.dart';
import 'widgets/driver_app_bar_overlay.dart';
import 'widgets/driver_dashboard_panel.dart';
import 'widgets/language_switch_tile.dart';
import 'widgets/theme_switch_tile.dart';
import 'available_requests_screen.dart';
import 'trip_history_screen.dart';
import 'widgets/trip_map_layer.dart';
import 'widgets/trip_map_mini_app_overlays.dart';

/// Upper bound on the pre-action location POST. The trip action itself carries the
/// coordinates in its body, so a slow flush must never hold the button hostage.
const Duration _locationFlushTimeout = Duration(seconds: 4);

String _driverUserExceptionText(DriverUserException e, AppLocalizations t) {
  switch (e.userCode) {
    case 'TRIP_NOT_FOUND':
      return t.trip_plan_not_found;
    case 'DRIVER_LOCATION_STALE':
    case 'LIVE_LOCATION_INACTIVE':
      return tripLiveLocationStaleHint(t);
    case 'ACCEPT_REQUIRES_ONLINE':
      return t.accept_requires_online;
    case 'ACCEPT_FAILED':
      return e.message.trim().isEmpty ? t.accept_failed : e.message;
    case 'DRIVER_HAS_ACTIVE_TRIP':
      return e.message.trim().isEmpty ? t.accept_active_trip_exists : e.message;
    case 'TRIP_ACTION_NO_TRIP':
      return t.trip_action_no_trip;
  }
  if (e.message.trim().isEmpty) {
    return t.trip_plan_not_found;
  }
  return e.message;
}

/// Open [uri], telling the driver when no app can handle it instead of failing silently.
/// On Android 11+/iOS this also covers a missing `<queries>` / `LSApplicationQueriesSchemes`
/// entry, which is otherwise indistinguishable from a dead button.
Future<void> launchOrNotify(
  BuildContext context,
  Uri uri, {
  required String failureMessage,
  LaunchMode mode = LaunchMode.platformDefault,
}) async {
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: mode);
  } catch (e) {
    debugPrint('[yetti_driver] launchUrl failed for ${uri.scheme}: $e');
  }
  if (ok || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(failureMessage)));
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _drawerKey = GlobalKey<ScaffoldState>();

  StreamSubscription<Position>? _posSub;
  bool _posSubBackground = false;
  bool _locationErrorShown = false;

  /// Trip panel folded down to the primary action only (more map).
  bool _tripPanelCollapsed = false;
  MapLatLng? _me;
  Timer? _meUiThrottle;
  MapLatLng? _pendingMeUi;

  /// Coarse driver point for gating actions (e.g. “Yetib keldim”) when map smoothing/accuracy
  /// rejects most fixes (common on web). This is **not** used for bearing or drawing.
  MapLatLng? _meGate;
  double? _lastFixAccuracyM;
  DateTime? _lastFixAt;
  double _carBearingDeg = 0;
  MapLatLng? _lastBearingAnchor;
  final List<MapLatLng> _smoothPos = [];

  /// UI-only: hide offer sheet after Accept without changing [TripStatus] (still WAITING).
  String? _acceptedOfferId;

  Future<void> _openSettingsSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  AppLocalizations.of(context).settings,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                const ThemeSwitchTile(),
                const SizedBox(height: 12),
                const LanguageSwitchTile(),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _signOut() async {
    Navigator.pop(context);
    if (AppConfig.driverId.trim().isNotEmpty) return;
    try {
      // Best-effort: ensure the driver is OFFLINE on sign-out.
      await ref
          .read(driverStatusProvider.notifier)
          .setStatus(DriverStatus.offline);
    } catch (_) {}
    ref.invalidate(tripProvider);
    await ref.read(driverIdProvider.notifier).clearDriverId();
  }

  void _openTripHistory(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const TripHistoryScreen()),
    );
  }

  void _openAvailableRequests(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AvailableRequestsScreen(driverPosition: _me),
      ),
    );
  }

  Future<void> _openBalanceSheet(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final trip = ref.read(tripProvider);
    final b = trip.driverBalance;
    final total = formatUzsSomOrDash(b?.totalSom, suffix: t.currency_som);
    final link = trip.referralLink;
    final linkTrimmed = link?.trim();
    final hasLink = linkTrimmed != null && linkTrimmed.isNotEmpty;
    final detail = AppConfig.hasHttpApi
        ? '${t.promo_balance}: ${formatUzsSomOrDash(b?.promoSom, suffix: t.currency_som)}\n'
              '${t.cash_balance}: ${formatUzsSomOrDash(b?.cashSom, suffix: t.currency_som)}'
        : '—';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final bodyStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.balance, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(
                total,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? IosTokens.systemGreenDark
                      : IosTokens.systemGreen,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(detail, style: bodyStyle),
              if (AppConfig.hasHttpApi && hasLink) ...[
                const SizedBox(height: 16),
                Text(
                  t.referral_link_label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SelectableText(linkTrimmed, style: bodyStyle),
                    ),
                    IconButton(
                      tooltip: t.copy_action,
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: linkTrimmed),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t.copied_to_clipboard)),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _callDispatch() async {
    final raw = AppConfig.dispatchPhoneE164.trim();
    if (raw.isEmpty) return;
    final uri = Uri.parse(raw.startsWith('tel:') ? raw : 'tel:$raw');
    await launchOrNotify(
      context,
      uri,
      failureMessage: AppLocalizations.of(context).launch_dialer_failed,
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  void initState() {
    super.initState();
    _startLocation();
    // Drive the geolocator foreground service from `driverStatus`, NOT from
    // app lifecycle. Reason: when we waited for `paused` to fire and *then*
    // started the FGS, aggressive battery-saver OEMs (Xiaomi, Samsung,
    // Honor, OnePlus, …) often suspended the Dart isolate before the FGS
    // actually finished registering — the dispatch poll timer never fired,
    // so `LocalNotifications.notifyNewOrder` never reached the system tray.
    //
    // By starting the FGS the moment the driver toggles ONLINE (while the
    // app is still foregrounded), Android has the persistent
    // `foregroundServiceType="location"` notification + WAKE_LOCK in place
    // before the screen ever turns off, so the poll keeps firing and new
    // order notifications make it through. This is the same pattern used
    // by Uber / Bolt / Yandex Go.
    ref.listenManual<DriverStatus>(driverStatusProvider, (
      DriverStatus? previous,
      DriverStatus next,
    ) {
      if (previous == next) return;
      unawaited(
        _subscribeLocationStream(background: next == DriverStatus.online),
      );
    });
  }

  void _ingestGps(Position pos) {
    // Reachable after an `await` (see [_startLocation]) — the widget may already be gone.
    if (!mounted) return;
    if (!isValidGeoDegrees(pos.latitude, pos.longitude)) return;
    _lastFixAccuracyM = pos.accuracy;
    _lastFixAt = pos.timestamp;

    // Driver coordinates are personal data — never write them to release logs.
    if (kDebugMode && AppConfig.debugLocation) {
      debugPrint(
        '[yetti_driver] Home ingest -> lat: ${pos.latitude}, lng: ${pos.longitude}, '
        'acc_m: ${pos.accuracy}, ts: ${pos.timestamp.toIso8601String()}',
      );
    }
    // Always forward fixes to [DriverLocationSyncController] so app location posts run while ONLINE.
    // Otherwise strict map accuracy (below) can block all ingests → server never marks driver live / “online”.
    ref.read(driverLocationSyncProvider.notifier).ingestPosition(pos);

    // Keep a coarse "gate" position for action enablement on devices/browsers with inaccurate fixes.
    // Desktop/web geolocation can report coarse accuracy; we still want the UI to update and allow actions.
    final prevGate = _meGate;
    _meGate = MapLatLng(pos.latitude, pos.longitude);
    if (_me == null &&
        (prevGate == null ||
            prevGate.latitude != _meGate!.latitude ||
            prevGate.longitude != _meGate!.longitude)) {
      setState(() {});
    }

    // First fix: allow weaker GPS so the map can show the taxi marker (many devices report >50 m in cities).
    // After we have a point, stay stricter for smoother bearing + odometer.
    if (!AppConfig.debugLocation) {
      final maxAccuracyM = _me == null ? 200.0 : 80.0;
      if (pos.accuracy > maxAccuracyM) return;
    }
    final prevMe = _me;
    var ll = MapLatLng(pos.latitude, pos.longitude);
    _smoothPos.add(ll);
    while (_smoothPos.length > 3) {
      _smoothPos.removeAt(0);
    }
    if (_smoothPos.length >= 2) {
      var lat = 0.0;
      var lng = 0.0;
      for (final e in _smoothPos) {
        lat += e.latitude;
        lng += e.longitude;
      }
      final n = _smoothPos.length;
      ll = MapLatLng(lat / n, lng / n);
    }
    if (_lastBearingAnchor != null) {
      final d = haversineKm(_lastBearingAnchor!, ll);
      if (d >= 0.005) {
        _carBearingDeg = bearingDegrees(_lastBearingAnchor!, ll);
        _lastBearingAnchor = ll;
      }
    } else {
      _lastBearingAnchor = ll;
    }
    // Throttle UI rebuilds (map is expensive). Location sync still receives every fix above.
    _pendingMeUi = ll;
    _meUiThrottle ??= Timer(const Duration(milliseconds: 1000), () {
      _meUiThrottle = null;
      if (!mounted) return;
      final next = _pendingMeUi;
      if (next == null) return;
      setState(() => _me = next);
    });
    final trip = ref.read(tripProvider);
    if (trip.status == TripStatus.started && prevMe != null) {
      final seg = haversineKm(prevMe, ll);
      if (seg > 0 && seg < 0.35) {
        ref.read(tripProvider.notifier).addClientOdometerKm(seg);
      }
    }
  }

  Future<void> _startLocation() async {
    final service = ref.read(locationServiceProvider);
    try {
      final current = await service.currentPosition();
      _ingestGps(current);
    } catch (_) {
      // On web, getCurrentPosition can fail even after permission prompts; still try the stream.
    }
    // Subscribe with the FGS already engaged when the driver is ONLINE on
    // launch — covers the case where the driver was last online, killed the
    // app, then reopens it; we want background-safe location streaming
    // immediately so the dispatch poll keeps running if the screen turns off.
    final isOnline = ref.read(driverStatusProvider) == DriverStatus.online;
    await _subscribeLocationStream(background: isOnline);
  }

  /// (Re)subscribe the position stream.
  ///
  /// On Android, [background] enables the geolocator foreground service so the
  /// GPS stream and HTTP location ticker keep running while the screen is off
  /// or the app is backgrounded — without this the backend's ~90s freshness
  /// guard expires and the driver is shown as offline server-side even though
  /// the local [DriverStatus] is still ONLINE.
  Future<void> _subscribeLocationStream({required bool background}) async {
    if (_posSub != null && _posSubBackground == background) return;
    await _posSub?.cancel();
    _posSub = null;
    if (!mounted) return;
    final service = ref.read(locationServiceProvider);
    try {
      _posSub = service
          .positionStream(background: background)
          .listen(
            _ingestGps,
            // Revoked permission or a disabled location service arrives as a stream error.
            // Without a handler it becomes an unhandled async exception and the driver is
            // left with a stream that quietly stopped producing fixes.
            onError: (Object e, StackTrace st) {
              debugPrint('[yetti_driver] location stream error: $e');
              _onLocationStreamFailed();
            },
            onDone: _onLocationStreamFailed,
            cancelOnError: false,
          );
      _posSubBackground = background;
    } catch (e) {
      debugPrint('[yetti_driver] location stream subscribe failed: $e');
      _posSub = null;
    }
  }

  void _onLocationStreamFailed() {
    if (!mounted) return;
    _posSub = null;
    if (_locationErrorShown) return;
    _locationErrorShown = true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).location_stream_error),
      ),
    );
    // Re-check the permission gate so the driver gets the actionable screen.
    unawaited(ref.read(locationGateProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _meUiThrottle?.cancel();
    super.dispose();
  }

  static bool _sameFarePopup(
    TripFareCompletionPopup? a,
    TripFareCompletionPopup? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    // Same trip → same summary, even if a later source filled in other numbers.
    if (a.tripId != null && a.tripId == b.tripId) return true;
    return a.fareSom == b.fareSom && a.distanceKm == b.distanceKm;
  }

  /// Trips whose completion dialog was already opened this session — the
  /// "Safar tugadi" dialog must appear once per trip, whichever path
  /// (finish button, poll, WebSocket, reconcile) publishes a summary.
  final Set<String> _completionDialogShownFor = <String>{};

  Future<void> _showTripFareCompletionDialog(
    TripFareCompletionPopup data,
  ) async {
    final t = AppLocalizations.of(context);
    final fare = formatDisplayFareSom(data.fareSom, suffix: t.currency_som);
    final distStr = (data.distanceKm != null && data.distanceKm! > 0)
        ? '${data.distanceKm!.toStringAsFixed(1)} km'
        : null;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text(t.trip_completed_dialog_title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                fare,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (distStr != null) ...[
                const SizedBox(height: 12),
                Text(
                  '${t.trip_distance_label}: $distStr',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.trip_completed_ok),
            ),
          ],
        );
      },
    );
    if (mounted) {
      ref.read(tripProvider.notifier).clearFareCompletionPopup();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tripProvider, (TripState? previous, TripState next) {
      final a = previous?.activeRequest?.tripId;
      final b = next.activeRequest?.tripId;
      if (a != b) {
        _lastBearingAnchor = null;
        _smoothPos.clear();
      }
      final popup = next.fareCompletionPopup;
      if (popup == null) return;
      if (_sameFarePopup(previous?.fareCompletionPopup, popup)) return;
      final tripId = popup.tripId;
      if (tripId != null && _completionDialogShownFor.contains(tripId)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final still = ref.read(tripProvider).fareCompletionPopup;
        if (still == null || !_sameFarePopup(still, popup)) return;
        if (tripId != null) {
          if (!_completionDialogShownFor.add(tripId)) return;
          if (_completionDialogShownFor.length > 50) {
            _completionDialogShownFor.remove(_completionDialogShownFor.first);
          }
        }
        unawaited(_showTripFareCompletionDialog(still));
      });
    });
    ref.watch(driverLocationSyncProvider);
    final t = AppLocalizations.of(context);
    final driverStatus = ref.watch(driverStatusProvider);
    final trip = ref.watch(tripProvider);
    final online = driverStatus == DriverStatus.online;

    final req = trip.activeRequest;

    /// Queue-only offers have no `trip_id` yet; assigned / in-progress trips always do.
    final queueOfferOnly =
        req != null && (req.tripId == null || req.tripId!.isEmpty);
    final offerPreviewActive =
        trip.pendingQueueOfferExpiresAt == null ||
        DateTime.now().isBefore(trip.pendingQueueOfferExpiresAt!);
    final showOffer =
        online &&
        req != null &&
        trip.status == TripStatus.waiting &&
        req.id != _acceptedOfferId &&
        queueOfferOnly &&
        offerPreviewActive;

    if (trip.activeRequest == null) {
      _acceptedOfferId = null;
    }

    // Use last known point for UI and action gating.
    final driverPosForUi = _me ?? _meGate;

    // Variant 1: if we have an assigned/in-flight trip (trip_id set) show the map + overlays
    // regardless of local session flags (acceptedOfferId can be lost on refresh).
    // Keep queue-only previews on the dashboard until accepted.
    final hasAssignedTrip = req != null && !queueOfferOnly;
    final showMap = hasAssignedTrip && trip.status != TripStatus.finished;

    final b = trip.driverBalance;
    final promoStr = formatUzsSomOrDash(b?.promoSom, suffix: t.currency_som);
    final cashStr = formatUzsSomOrDash(b?.cashSom, suffix: t.currency_som);
    final totalStr = formatUzsSomOrDash(b?.totalSom, suffix: t.currency_som);

    final tripInProgress = trip.status == TripStatus.started;
    final showDashboard = !showMap;
    final showUnfinishedTripCard = trip.hasActiveTrip && !showMap && !showOffer;
    // Room for map FABs: bottom sheet is one column (fare strip + trip panel) when not in progress.
    final mapBottomInset = showMap
        ? (_tripPanelCollapsed
              ? (tripInProgress ? 190.0 : 270.0)
              : (tripInProgress ? 280.0 : 360.0))
        : 0.0;

    return Scaffold(
      key: _drawerKey,
      extendBodyBehindAppBar: showMap,
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              DrawerHeader(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.local_taxi,
                      size: 44,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'YettiQanot',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(t.balance),
                onTap: () {
                  Navigator.pop(context);
                  _openBalanceSheet(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: Text(t.settings),
                onTap: () {
                  Navigator.pop(context);
                  _openSettingsSheet(context);
                },
              ),
              if (AppConfig.driverId.trim().isEmpty)
                ListTile(
                  leading: Icon(
                    Icons.logout,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    t.sign_out,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onTap: _signOut,
                ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: showMap
                ? TripMapLayer(
                    me: _me,
                    trip: trip,
                    bottomOverlayInset: mapBottomInset,
                    carBearingDegrees: _carBearingDeg,
                  )
                : const _HomeBackdrop(),
          ),
          if (AppConfig.debugLocation)
            Positioned(
              left: 12,
              bottom: 12,
              child: SafeArea(
                top: false,
                child: _LocationDebugPill(
                  me: _me,
                  accuracyM: _lastFixAccuracyM,
                  at: _lastFixAt,
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: DriverAppBarOverlay(
              tripMapChrome: showMap,
              online: online,
              onMenu: () => _drawerKey.currentState?.openDrawer(),
              onPhone: _callDispatch,
              onOnlineToggle: (v) async {
                try {
                  await ref
                      .read(driverStatusProvider.notifier)
                      .setStatus(
                        v ? DriverStatus.online : DriverStatus.offline,
                      );
                  if (v) {
                    // Ingest latest fix for map + location sync (server registration is in [DriverStatusController]).
                    try {
                      final loc = ref.read(locationServiceProvider);
                      final pos = await loc.currentPosition();
                      _ingestGps(pos);
                    } catch (_) {
                      // Best-effort: permission / GPS may be unavailable; periodic sync will catch up.
                    }
                  }
                } on DioException catch (e) {
                  if (!context.mounted) return;
                  final msg =
                      parseDriverApiErrorMessage(e) ??
                      AppLocalizations.of(context).offline_api_failed;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(msg)));
                } catch (_) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(context).offline_api_failed,
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          if (showMap &&
              trip.activeRequest != null &&
              trip.status != TripStatus.finished) ...[
            Positioned(
              left: 14,
              right: 14,
              top: MediaQuery.paddingOf(context).top + 72,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TripStatusBanner(
                    status: trip.status,
                    toPickupText: t.to_pickup,
                    arrivedText: t.trip_status_ready_to_start,
                    startedText: t.unfinished_trip_phase_started,
                  ),
                  if (!tripInProgress && !_tripPanelCollapsed) ...[
                    const SizedBox(height: 8),
                    TripRiderInfoCard(
                      request: trip.activeRequest!,
                      onCall: () => launchRiderOrDispatchCall(
                        context,
                        trip.activeRequest,
                      ),
                      onNavigateToPickup: () async {
                        final p = trip.activeRequest?.pickup;
                        if (p == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(t.pickup_coordinates_missing),
                            ),
                          );
                          return;
                        }
                        final uri = Uri.parse(
                          'https://www.google.com/maps/dir/?api=1'
                          '&destination=${p.latitude},${p.longitude}'
                          '&travelmode=driving',
                        );
                        await launchOrNotify(
                          context,
                          uri,
                          failureMessage: t.launch_maps_failed,
                          mode: LaunchMode.externalApplication,
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
          // Dashboard: full-height scroll. Trip map: bottom sheet only — do **not** use
          // [AnimatedSwitcher] with a stacked layout here; it left two children in a [Stack] and
          // caused "RenderStack was not laid out" / zero-size hit tests over the map.
          if (showDashboard)
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              top: MediaQuery.paddingOf(context).top + 64,
              child: SingleChildScrollView(
                key: const ValueKey('dashScroll'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Balance top-up is manual: an empty wallet silently stops orders.
                    // Explain it (with a support contact) instead of an empty offer list.
                    if (online && b?.totalSom != null && b!.totalSom! <= 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(14),
                          child: ListTile(
                            leading: Icon(
                              Icons.account_balance_wallet_outlined,
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                            title: Text(
                              t.balance_empty_orders_paused,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            trailing: TextButton.icon(
                              onPressed: _callDispatch,
                              icon: const Icon(Icons.call, size: 18),
                              label: Text(t.contact_support),
                              style: TextButton.styleFrom(
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (trip.dispatchUnreachable)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(14),
                          child: ListTile(
                            leading: Icon(
                              Icons.cloud_off_rounded,
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                            title: Text(
                              t.dispatch_unreachable,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    if (trip.hydrationIssue == TripHydrationIssue.tripNotFound)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(14),
                          child: ListTile(
                            leading: Icon(
                              Icons.map_outlined,
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                            title: Text(
                              t.trip_plan_not_found,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            trailing: IconButton(
                              icon: Icon(
                                Icons.close,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                              onPressed: () => ref
                                  .read(tripProvider.notifier)
                                  .clearTripHydrationNotice(),
                            ),
                          ),
                        ),
                      ),
                    DriverDashboardPanel(
                      key: const ValueKey('dash'),
                      online: online,
                      promoValue: promoStr,
                      cashValue: cashStr,
                      totalBalanceText: totalStr,
                      commission: trip.commission,
                      dashboardStats: trip.dashboardStats,
                      onTripHistoryTap: () => _openTripHistory(context),
                      onAvailableRequestsTap: () =>
                          _openAvailableRequests(context),
                      onPendingOfferTimeout: () => ref
                          .read(tripProvider.notifier)
                          .dismissQueueOfferPreview(),
                      onBalanceTap: () => _openBalanceSheet(context),
                      pendingOffer: showOffer ? trip.activeRequest! : null,
                      pendingOfferExpiresAt: showOffer
                          ? trip.pendingQueueOfferExpiresAt
                          : null,
                      driverPosition: _me,
                      unfinishedTripStatus: showUnfinishedTripCard
                          ? trip.status
                          : null,
                      onContinueUnfinishedTrip: showUnfinishedTripCard
                          ? () => setState(
                              () => _acceptedOfferId = trip.activeRequest!.id,
                            )
                          : null,
                      acceptOfferLabel: showOffer ? t.accept : null,
                      onAcceptOffer: showOffer
                          ? () async {
                              final id = trip.activeRequest?.id;
                              try {
                                await ref
                                    .read(tripProvider.notifier)
                                    .acceptOffer();
                                if (!context.mounted) return;
                                setState(() => _acceptedOfferId = id);
                              } on DriverUserException catch (e) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      _driverUserExceptionText(e, t),
                                    ),
                                  ),
                                );
                              } catch (e) {
                                debugPrint('[yetti_driver] accept failed: $e');
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(t.accept_failed)),
                                );
                              }
                            }
                          : null,
                    ),
                  ],
                ),
              ),
            )
          else
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: SafeArea(
                top: false,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showMap)
                          _PanelHandle(
                            collapsed: _tripPanelCollapsed,
                            onTap: () => setState(
                              () => _tripPanelCollapsed = !_tripPanelCollapsed,
                            ),
                          ),
                        if (trip.activeRequest != null &&
                            trip.status != TripStatus.finished &&
                            !(showMap && _tripPanelCollapsed)) ...[
                          TripFareDistanceStrip(
                            trip: trip,
                            driverPos: driverPosForUi,
                          ),
                          const SizedBox(height: 8),
                        ],
                        _TripActionPanel(
                          // Keyed by trip only — never by status. The action methods
                          // publish the new status optimistically on their first line;
                          // a status-keyed panel was disposed right there, mid-request:
                          // the busy spinner vanished, the next button became tappable
                          // while the previous POST was still in flight (a second tap
                          // then hit `/trip/start` against a server still at WAITING),
                          // and every error snackbar was dropped on an unmounted context.
                          key: ValueKey(
                            'trip_${trip.activeRequest?.tripId ?? trip.activeRequest?.id ?? 'none'}',
                          ),
                          trip: trip,
                          driverPos: driverPosForUi,
                          driverAccuracyM: _lastFixAccuracyM,
                          driverFixAt: _lastFixAt,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// No map on idle / pending offer (offer is inline on [DriverDashboardPanel]) — map after Accept.
/// Chevron handle above the trip panel: folds the fare strip and the rider card
/// away so the map gets the space; the primary action always stays.
class _PanelHandle extends StatelessWidget {
  const _PanelHandle({required this.collapsed, required this.onTap});

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: theme.colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(999),
          elevation: 2,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 64,
              height: 28,
              child: Icon(
                collapsed
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 24,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeBackdrop extends StatelessWidget {
  const _HomeBackdrop();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(color: theme.colorScheme.surface);
  }
}

class _LocationDebugPill extends StatelessWidget {
  const _LocationDebugPill({
    required this.me,
    required this.accuracyM,
    required this.at,
  });

  final MapLatLng? me;
  final double? accuracyM;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lat = me?.latitude;
    final lng = me?.longitude;
    final coords = (lat != null && lng != null)
        ? 'lat: ${lat.toStringAsFixed(6)}\nlng: ${lng.toStringAsFixed(6)}'
        : 'lat/lng: —';
    final acc = accuracyM != null
        ? 'acc: ${accuracyM!.toStringAsFixed(0)} m'
        : 'acc: —';
    final ts = at != null ? 'ts: ${at!.toIso8601String()}' : 'ts: —';
    final copy = (lat != null && lng != null)
        ? '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}'
        : '';

    return Material(
      color: Colors.black.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: copy.isEmpty
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: copy));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Coordinates copied')),
                );
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: DefaultTextStyle(
            style:
                theme.textTheme.labelSmall?.copyWith(color: Colors.white) ??
                const TextStyle(color: Colors.white),
            child: Text('$coords\n$acc\n$ts'),
          ),
        ),
      ),
    );
  }
}

Future<bool> _confirmCancelTrip(
  BuildContext context,
  AppLocalizations t,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.cancel_trip_confirm_title),
      content: Text(t.cancel_trip_confirm_body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.common_back),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(t.cancel_trip_confirm_yes),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class _TripActionPanel extends ConsumerStatefulWidget {
  const _TripActionPanel({
    super.key,
    required this.trip,
    this.driverPos,
    this.driverAccuracyM,
    this.driverFixAt,
  });

  final TripState trip;
  final MapLatLng? driverPos;

  /// Last fix accuracy from GPS (meters), for location flush before “Yetib keldim”.
  final double? driverAccuracyM;

  /// GPS fix time for [flushHttpNowAt] / `POST /trip/arrived` timestamp parity with Chrome/web.
  final DateTime? driverFixAt;

  @override
  ConsumerState<_TripActionPanel> createState() => _TripActionPanelState();
}

class _TripActionPanelState extends ConsumerState<_TripActionPanel> {
  /// Trip actions run strictly one after another so each `/trip/*` call goes out
  /// exactly once per tap, without any loading state on the buttons: the optimistic
  /// status change (Yetib keldim → Safarni boshlash → Safarni tugatish) is the tap's
  /// feedback. A spinner while the request was in flight read as "the app froze",
  /// and a bare double tap used to fire the same request twice.
  ///
  /// A tap made while the previous action is still in flight is honoured right after
  /// it — but only if the trip is still at the stage that button belonged to
  /// ([forStatus]). A failed, reverted action must not let the queued tap fire the
  /// next transition against the wrong stage, and a double tap on one button must
  /// not run its action twice.
  Future<void> _queue = Future<void>.value();

  Future<void> _serial(
    TripStatus? forStatus,
    Future<void> Function() action,
  ) {
    final run = _queue.then((_) async {
      if (!mounted) return;
      if (forStatus != null && ref.read(tripProvider).status != forStatus) {
        return;
      }
      await action();
    });
    // Keep the chain alive after a failure; each action reports its own error.
    _queue = run.catchError((_) {});
    return run;
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final driverPos = widget.driverPos;
    final driverAccuracyM = widget.driverAccuracyM;
    final driverFixAt = widget.driverFixAt;
    final t = AppLocalizations.of(context);
    if (trip.activeRequest == null) return const SizedBox.shrink();

    final theme = Theme.of(context);

    Widget primary({
      required String text,
      required IconData icon,
      VoidCallback? onPressed,
      required Color color,
    }) {
      return SizedBox(
        height: 64,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, color: Colors.white),
          label: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: color,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
      );
    }

    final isDark = theme.brightness == Brightness.dark;
    final panelBg = isDark
        ? IosTokens.darkElevated
        : (theme.brightness == Brightness.light
              ? Colors.white
              : theme.colorScheme.surfaceContainerHigh);
    final titleColor = isDark ? Colors.white : theme.colorScheme.onSurface;
    final bodyMuted = isDark
        ? Colors.white.withValues(alpha: 0.72)
        : theme.colorScheme.onSurfaceVariant;
    final bodySmallMuted = isDark
        ? Colors.white.withValues(alpha: 0.58)
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      elevation: 0,
      borderRadius: BorderRadius.circular(22),
      color: panelBg,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : (theme.brightness == Brightness.light
                        ? IosTokens.separatorOpaque.withValues(alpha: 0.35)
                        : Colors.white.withValues(alpha: 0.08)),
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.trip_panel_title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: titleColor,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    style: TextButton.styleFrom(
                      // 48dp minimum touch target — this is tapped while driving.
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      minimumSize: const Size(48, 48),
                    ),
                    // Destructive and irreversible, on a screen used while driving —
                    // always confirm before cancelling.
                    onPressed: () async {
                            final confirmed = await _confirmCancelTrip(
                              context,
                              t,
                            );
                            if (!confirmed || !context.mounted) return;
                            await _serial(null, () async {
                              try {
                                await ref
                                    .read(tripProvider.notifier)
                                    .cancelTripAsDriver();
                              } on DriverUserException catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        _driverUserExceptionText(e, t),
                                      ),
                                    ),
                                  );
                                }
                              } catch (e) {
                                debugPrint(
                                  '[yetti_driver] cancelTrip error: $e',
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(t.offline_api_failed),
                                    ),
                                  );
                                }
                              }
                            });
                          },
                    child: Text(
                      t.cancel_trip,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
              if (trip.status == TripStatus.waiting) ...[
                Text(
                  t.to_pickup,
                  style: theme.textTheme.bodyMedium?.copyWith(color: bodyMuted),
                ),
                const SizedBox(height: 10),
                Builder(
                  builder: (context) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        primary(
                          text: t.arrived,
                          icon: Icons.flag,
                          // Arrival is not proximity-gated, and coordinates are optional
                          // in `POST /trip/arrived`. Requiring a fix used to leave the
                          // button permanently dead in a garage / on a bad GPS day, with
                          // no way for the driver to progress the trip.
                          onPressed: () => _serial(TripStatus.waiting, () async {
                            final locNotifier = ref.read(
                              driverLocationSyncProvider.notifier,
                            );
                            final tripNotifier = ref.read(
                              tripProvider.notifier,
                            );
                            try {
                              // Fire the location refresh in PARALLEL, never in front of
                              // the action: `/trip/arrived` carries lat/lng/accuracy/timestamp
                              // in its own body, and [toArrived] publishes the optimistic
                              // status on its first line. Awaiting the flush here put two
                              // extra round trips (~1.2s) between the tap and the UI moving.
                              // Use map/UI coordinates on Android: [flushHttpNow] can no-op if [_last] in
                              // [DriverLocationSyncController] is behind the smoothed map position.
                              final p = driverPos;
                              if (p != null) {
                                unawaited(
                                  locNotifier
                                      .flushHttpNowAt(
                                        p.latitude,
                                        p.longitude,
                                        accuracy: driverAccuracyM,
                                        fixTimestamp: driverFixAt,
                                      )
                                      .timeout(_locationFlushTimeout)
                                      .catchError((_) {}),
                                );
                              }
                              await tripNotifier.toArrived(
                                lat: p?.latitude,
                                lng: p?.longitude,
                                accuracy: driverAccuracyM,
                                fixTime: driverFixAt,
                              );
                            } on DioException catch (e) {
                              if (context.mounted) {
                                final code = (parseDriverApiErrorCode(e) ?? '')
                                    .toUpperCase();
                                final msg =
                                    (code == 'DRIVER_LOCATION_STALE' ||
                                        code == 'LIVE_LOCATION_INACTIVE' ||
                                        isTelegramLiveLocationBackendError(e))
                                    ? tripLiveLocationStaleHint(t)
                                    : (parseDriverApiErrorMessage(e) ??
                                          t.offline_api_failed);
                                ScaffoldMessenger.of(
                                  context,
                                ).showSnackBar(SnackBar(content: Text(msg)));
                              }
                            } on DriverUserException catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      _driverUserExceptionText(e, t),
                                    ),
                                  ),
                                );
                              }
                            } catch (e, st) {
                              debugPrint(
                                '[yetti_driver] Yetib keldim error: $e\n$st',
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(t.phone_login_network_error),
                                  ),
                                );
                              }
                            }
                          }),
                          color: IosTokens.systemBlue,
                        ),
                        // Informational only — the action stays available.
                        if (driverPos == null) ...[
                          const SizedBox(height: 8),
                          Text(
                            t.allow_location,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: bodySmallMuted,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ] else if (trip.status == TripStatus.arrived) ...[
                Text(
                  t.trip_status_ready_to_start,
                  style: theme.textTheme.bodyMedium?.copyWith(color: bodyMuted),
                ),
                const SizedBox(height: 10),
                primary(
                  text: t.start_trip,
                  icon: Icons.play_arrow,
                  onPressed: () => _serial(TripStatus.arrived, () async {
                    final locNotifier = ref.read(
                      driverLocationSyncProvider.notifier,
                    );
                    final tripNotifier = ref.read(tripProvider.notifier);
                    try {
                      // In parallel with the action, never in front of it — see the
                      // equivalent note on "Yetib keldim". `/trip/start` carries the same
                      // coordinates in its body.
                      final p = driverPos;
                      if (p != null) {
                        unawaited(
                          locNotifier
                              .flushHttpNowAt(
                                p.latitude,
                                p.longitude,
                                accuracy: driverAccuracyM,
                                fixTimestamp: driverFixAt,
                              )
                              .timeout(_locationFlushTimeout)
                              .catchError((_) {}),
                        );
                      } else {
                        unawaited(
                          locNotifier
                              .flushHttpNow()
                              .timeout(_locationFlushTimeout)
                              .catchError((_) {}),
                        );
                      }
                      await tripNotifier.startTrip(
                        lat: p?.latitude,
                        lng: p?.longitude,
                        accuracy: driverAccuracyM,
                        fixTime: driverFixAt,
                      );
                    } on DriverUserException catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(_driverUserExceptionText(e, t)),
                          ),
                        );
                      }
                    } on DioException catch (e) {
                      if (!context.mounted) return;
                      final code = (parseDriverApiErrorCode(e) ?? '')
                          .toUpperCase();
                      final msg =
                          (code == 'DRIVER_LOCATION_STALE' ||
                              code == 'LIVE_LOCATION_INACTIVE' ||
                              isTelegramLiveLocationBackendError(e))
                          ? tripLiveLocationStaleHint(t)
                          : (parseDriverApiErrorMessage(e) ??
                                t.offline_api_failed);
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(msg)));
                    } catch (e, st) {
                      debugPrint('[yetti_driver] startTrip error: $e\n$st');
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t.offline_api_failed)),
                        );
                      }
                    }
                  }),
                  color: IosTokens.systemOrange,
                ),
              ] else if (trip.status == TripStatus.started) ...[
                Text(
                  t.unfinished_trip_phase_started,
                  style: theme.textTheme.bodyMedium?.copyWith(color: bodyMuted),
                ),
                const SizedBox(height: 12),
                primary(
                  text: t.finish_trip,
                  icon: Icons.task_alt,
                  onPressed: () => _serial(TripStatus.started, () async {
                    try {
                      await ref
                          .read(tripProvider.notifier)
                          .finishTrip(
                            lat: driverPos?.latitude,
                            lng: driverPos?.longitude,
                            accuracy: driverAccuracyM,
                            fixTime: driverFixAt,
                          );
                    } on DriverUserException catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(_driverUserExceptionText(e, t)),
                          ),
                        );
                      }
                    } catch (e) {
                      debugPrint('[yetti_driver] finishTrip error: $e');
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t.offline_api_failed)),
                        );
                      }
                    }
                  }),
                  color: theme.colorScheme.error,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
