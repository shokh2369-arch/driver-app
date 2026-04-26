import 'dart:async';

import 'package:dio/dio.dart';
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
import 'widgets/driver_app_bar_overlay.dart';
import 'widgets/driver_dashboard_panel.dart';
import 'widgets/language_switch_tile.dart';
import 'widgets/theme_switch_tile.dart';
import 'available_requests_screen.dart';
import 'trip_history_screen.dart';
import 'widgets/trip_map_layer.dart';
import 'widgets/trip_map_mini_app_overlays.dart';

String _driverUserExceptionText(DriverUserException e, AppLocalizations t) {
  if (e.userCode == 'TRIP_NOT_FOUND') {
    return t.trip_plan_not_found;
  }
  if (e.userCode == 'DRIVER_LOCATION_STALE' || e.userCode == 'LIVE_LOCATION_INACTIVE') {
    return tripLiveLocationStaleHint(t);
  }
  if (e.message.trim().isEmpty) {
    return t.trip_plan_not_found;
  }
  return e.message;
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _drawerKey = GlobalKey<ScaffoldState>();

  StreamSubscription<Position>? _posSub;
  MapLatLng? _me;
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
      await ref.read(driverStatusProvider.notifier).setStatus(DriverStatus.offline);
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
    final total = formatUzsSomOrDash(b?.totalSom);
    final link = trip.referralLink;
    final linkTrimmed = link?.trim();
    final hasLink = linkTrimmed != null && linkTrimmed.isNotEmpty;
    final detail = AppConfig.hasHttpApi
        ? '${t.promo_balance}: ${formatUzsSomOrDash(b?.promoSom)}\n${t.cash_balance}: ${formatUzsSomOrDash(b?.cashSom)}'
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
                        await Clipboard.setData(ClipboardData(text: linkTrimmed));
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
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  void initState() {
    super.initState();
    _startLocation();
  }

  void _ingestGps(Position pos) {
    if (!isValidGeoDegrees(pos.latitude, pos.longitude)) return;
    _lastFixAccuracyM = pos.accuracy;
    _lastFixAt = pos.timestamp;

    if (AppConfig.debugLocation) {
      // ignore: avoid_print
      print(
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
    setState(() => _me = ll);
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
      _posSub = service.positionStream().listen(_ingestGps);
    } catch (_) {
      // On web, getCurrentPosition can fail even after permission prompts; still try the stream.
      try {
        _posSub = service.positionStream().listen(_ingestGps);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  static bool _sameFarePopup(TripFareCompletionPopup? a, TripFareCompletionPopup? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.fareSom == b.fareSom && a.distanceKm == b.distanceKm;
  }

  Future<void> _showTripFareCompletionDialog(TripFareCompletionPopup data) async {
    final t = AppLocalizations.of(context);
    final fare = formatDisplayFareSom(data.fareSom);
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
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final still = ref.read(tripProvider).fareCompletionPopup;
        if (still == null || !_sameFarePopup(still, popup)) return;
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
    final queueOfferOnly = req != null && (req.tripId == null || req.tripId!.isEmpty);
    final showOffer =
        online &&
        req != null &&
        trip.status == TripStatus.waiting &&
        req.id != _acceptedOfferId &&
        queueOfferOnly;

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
    final promoStr = formatUzsSomOrDash(b?.promoSom);
    final cashStr = formatUzsSomOrDash(b?.cashSom);
    final totalStr = formatUzsSomOrDash(b?.totalSom);

    final tripInProgress = trip.status == TripStatus.started;
    final showDashboard = !showMap;
    final showUnfinishedTripCard =
        trip.hasActiveTrip && !showMap && !showOffer;
    // Room for map FABs: bottom sheet is one column (fare strip + trip panel) when not in progress.
    final mapBottomInset = showMap ? (tripInProgress ? 280.0 : 360.0) : 0.0;

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
                  leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                  title: Text(
                    t.sign_out,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                  await ref.read(driverStatusProvider.notifier).setStatus(
                        v ? DriverStatus.online : DriverStatus.offline,
                      );
                } on DioException catch (e) {
                  if (!context.mounted) return;
                  final msg =
                      parseDriverApiErrorMessage(e) ?? AppLocalizations.of(context).offline_api_failed;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                } catch (_) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(AppLocalizations.of(context).offline_api_failed)),
                  );
                }
              },
            ),
          ),
          if (showMap && trip.activeRequest != null && trip.status != TripStatus.finished) ...[
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
                  if (!tripInProgress) ...[
                    const SizedBox(height: 8),
                    TripRiderInfoCard(
                      request: trip.activeRequest!,
                      onCall: () => launchRiderOrDispatchCall(trip.activeRequest),
                      onNavigateToPickup: () async {
                        final req = trip.activeRequest;
                        if (req == null) return;
                        final p = req.pickup;
                        final uri = Uri.parse(
                          'https://www.google.com/maps/dir/?api=1'
                          '&destination=${p.latitude},${p.longitude}'
                          '&travelmode=driving',
                        );
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    TripMapStatsPill(trip: trip, driverPos: driverPosForUi),
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
                    if (trip.hydrationIssue == TripHydrationIssue.tripNotFound)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(14),
                          child: ListTile(
                            leading: Icon(
                              Icons.map_outlined,
                              color: Theme.of(context).colorScheme.onErrorContainer,
                            ),
                            title: Text(
                              t.trip_plan_not_found,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            trailing: IconButton(
                              icon: Icon(
                                Icons.close,
                                color: Theme.of(context).colorScheme.onErrorContainer,
                              ),
                              onPressed: () =>
                                  ref.read(tripProvider.notifier).clearTripHydrationNotice(),
                            ),
                          ),
                        ),
                      ),
                    DriverDashboardPanel(
                      key: const ValueKey('dash'),
                      promoValue: promoStr,
                      cashValue: cashStr,
                      totalBalanceText: totalStr,
                      dashboardStats: trip.dashboardStats,
                      onTripHistoryTap: () => _openTripHistory(context),
                      onAvailableRequestsTap: () => _openAvailableRequests(context),
                      onPendingOfferTimeout: () =>
                          ref.read(tripProvider.notifier).dismissQueueOfferPreview(),
                      onBalanceTap: () => _openBalanceSheet(context),
                      pendingOffer: showOffer ? trip.activeRequest! : null,
                      driverPosition: _me,
                      unfinishedTripStatus: showUnfinishedTripCard ? trip.status : null,
                      onContinueUnfinishedTrip: showUnfinishedTripCard
                          ? () => setState(() => _acceptedOfferId = trip.activeRequest!.id)
                          : null,
                      acceptOfferLabel: showOffer ? t.accept : null,
                      onAcceptOffer: showOffer
                          ? () async {
                              final id = trip.activeRequest?.id;
                              try {
                                await ref.read(tripProvider.notifier).acceptOffer();
                                if (!context.mounted) return;
                                setState(() => _acceptedOfferId = id);
                              } on DriverUserException catch (e) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(_driverUserExceptionText(e, t))),
                                );
                              } catch (_) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Accept failed')),
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
                        if (trip.activeRequest != null && trip.status != TripStatus.finished) ...[
                          TripFareDistanceStrip(trip: trip),
                          const SizedBox(height: 8),
                        ],
                        _TripActionPanel(
                          key: ValueKey('trip_${trip.status.name}'),
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
class _HomeBackdrop extends StatelessWidget {
  const _HomeBackdrop();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(color: theme.colorScheme.surface);
  }
}

class _LocationDebugPill extends StatelessWidget {
  const _LocationDebugPill({required this.me, required this.accuracyM, required this.at});

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
    final acc = accuracyM != null ? 'acc: ${accuracyM!.toStringAsFixed(0)} m' : 'acc: —';
    final ts = at != null ? 'ts: ${at!.toIso8601String()}' : 'ts: —';
    final copy = (lat != null && lng != null) ? '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}' : '';

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
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white) ??
                const TextStyle(color: Colors.white),
            child: Text('$coords\n$acc\n$ts'),
          ),
        ),
      ),
    );
  }
}

/// Brief pause after `POST /driver/location/app` so the server can commit freshness before trip actions.
const Duration _kTripActionPostFlushDelay = Duration(milliseconds: 280);

class _TripActionPanel extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: Colors.white),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: color,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
      );
    }

    final isDark = theme.brightness == Brightness.dark;
    final panelBg =
        isDark ? IosTokens.darkElevated : (theme.brightness == Brightness.light ? Colors.white : theme.colorScheme.surfaceContainerHigh);
    final titleColor = isDark ? Colors.white : theme.colorScheme.onSurface;
    final bodyMuted = isDark ? Colors.white.withValues(alpha: 0.72) : theme.colorScheme.onSurfaceVariant;
    final bodySmallMuted = isDark ? Colors.white.withValues(alpha: 0.58) : theme.colorScheme.onSurfaceVariant;

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
                    'Trip',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: titleColor,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () async {
                      try {
                        await ref.read(tripProvider.notifier).cancelTripAsDriver();
                      } on DriverUserException catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(_driverUserExceptionText(e, t))),
                          );
                        }
                      } catch (_) {}
                    },
                    child: Text(t.cancel_trip, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ],
              ),
              if (trip.status == TripStatus.waiting) ...[
                Text(t.to_pickup, style: theme.textTheme.bodyMedium?.copyWith(color: bodyMuted)),
                const SizedBox(height: 10),
                Builder(
                  builder: (context) {
                    // Arrival is not proximity-gated anymore. Still require a location fix so the
                    // backend can validate with fresh coordinates.
                    final canMarkArrived = driverPos != null;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        primary(
                          text: t.arrived,
                          icon: Icons.flag,
                          onPressed: canMarkArrived
                              ? () async {
                                  final locNotifier = ref.read(driverLocationSyncProvider.notifier);
                                  final tripNotifier = ref.read(tripProvider.notifier);
                                  try {
                                    // Backend validates arrival using last posted driver coords.
                                    // Use map/UI coordinates on Android: [flushHttpNow] can no-op if [_last] in
                                    // [DriverLocationSyncController] is behind the smoothed map position.
                                    final p = driverPos!;
                                    await locNotifier.flushHttpNowAt(
                                          p.latitude,
                                          p.longitude,
                                          accuracy: driverAccuracyM,
                                          fixTimestamp: driverFixAt,
                                        );
                                    await Future<void>.delayed(_kTripActionPostFlushDelay);
                                    await tripNotifier.toArrived(
                                          lat: p.latitude,
                                          lng: p.longitude,
                                          accuracy: driverAccuracyM,
                                          fixTime: driverFixAt,
                                        );
                                  } on DioException catch (e) {
                                    if (context.mounted) {
                                      final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase();
                                      final msg = (code == 'DRIVER_LOCATION_STALE' ||
                                              code == 'LIVE_LOCATION_INACTIVE' ||
                                              isTelegramLiveLocationBackendError(e))
                                          ? tripLiveLocationStaleHint(t)
                                          : (parseDriverApiErrorMessage(e) ?? t.offline_api_failed);
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                                    }
                                  } on DriverUserException catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(_driverUserExceptionText(e, t))),
                                      );
                                    }
                                  } catch (e, st) {
                                    debugPrint('[yetti_driver] Yetib keldim error: $e\n$st');
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(t.phone_login_network_error)),
                                      );
                                    }
                                  }
                                }
                              : null,
                          color: IosTokens.systemBlue,
                        ),
                        if (!canMarkArrived) ...[
                          const SizedBox(height: 8),
                          Text(
                            driverPos == null
                                ? t.allow_location
                                : t.allow_location,
                            style: theme.textTheme.bodySmall?.copyWith(color: bodySmallMuted),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ] else if (trip.status == TripStatus.arrived) ...[
                Text(t.trip_status_ready_to_start, style: theme.textTheme.bodyMedium?.copyWith(color: bodyMuted)),
                const SizedBox(height: 10),
                primary(
                  text: t.start_trip,
                  icon: Icons.play_arrow,
                  onPressed: () async {
                    final locNotifier = ref.read(driverLocationSyncProvider.notifier);
                    final tripNotifier = ref.read(tripProvider.notifier);
                    try {
                      final p = driverPos;
                      if (p != null) {
                        await locNotifier.flushHttpNowAt(
                              p.latitude,
                              p.longitude,
                              accuracy: driverAccuracyM,
                              fixTimestamp: driverFixAt,
                            );
                      } else {
                        await locNotifier.flushHttpNow();
                      }
                      await Future<void>.delayed(_kTripActionPostFlushDelay);
                      await tripNotifier.startTrip(
                            lat: p?.latitude,
                            lng: p?.longitude,
                            accuracy: driverAccuracyM,
                            fixTime: driverFixAt,
                          );
                    } on DriverUserException catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(_driverUserExceptionText(e, t))),
                        );
                      }
                    } on DioException catch (e) {
                      if (!context.mounted) return;
                      final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase();
                      final msg = (code == 'DRIVER_LOCATION_STALE' ||
                              code == 'LIVE_LOCATION_INACTIVE' ||
                              isTelegramLiveLocationBackendError(e))
                          ? tripLiveLocationStaleHint(t)
                          : (parseDriverApiErrorMessage(e) ?? t.offline_api_failed);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                    } catch (e, st) {
                      debugPrint('[yetti_driver] startTrip error: $e\n$st');
                    }
                  },
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
                  onPressed: () async {
                    try {
                      await ref.read(tripProvider.notifier).finishTrip();
                    } on DriverUserException catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(_driverUserExceptionText(e, t))),
                        );
                      }
                    } catch (_) {}
                  },
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
