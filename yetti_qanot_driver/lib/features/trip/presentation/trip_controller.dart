import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/money_uzs.dart';
import '../../../core/geo/lat_lng.dart';
import '../../../core/localization/arb/app_localizations.dart';
import '../../../core/localization/l10n_resolver.dart';
import '../../../data/repositories/driver_repository.dart';
import '../../../services/api_error_parser.dart';
import '../../../services/app_lifecycle_provider.dart';
import '../../../services/config.dart';
import '../../../services/driver_session_revocation.dart';
import '../../../services/driver_dashboard_parser.dart';
import '../../../services/driver_dispatch_parser.dart'
    show
        QueueOfferItem,
        extractDistanceKmFromMap,
        extractFareSomFromMap,
        mergeDriverBalanceSnapshots,
        parseAvailableRequests,
        parseCommissionFromJson,
        parseDriverBalanceFromDispatchJson,
        parseServerTripStatus,
        tripRequestFromQueueItem,
        tripRequestFromTripJson,
        tripStatusStringFromJson;
import '../../../services/driver_user_exception.dart';
import '../../../services/service_providers.dart';
import '../../../services/websocket_service.dart';
import '../../../services/local_notifications.dart';
import '../../../services/trip_status_voice.dart';
import '../../driver/domain/driver_status.dart';
import '../../driver/presentation/driver_id_controller.dart';
import '../../driver/presentation/driver_session_controller.dart';
import '../../driver/presentation/driver_status_controller.dart';
import '../domain/driver_dashboard_stats.dart';
import '../domain/local_status_advance.dart';
import '../domain/trip_request.dart';
import '../domain/trip_status.dart';
import 'trip_state.dart';

bool _walletKeysLogged = false;

String? _formatOfferDistanceKm(AppLocalizations t, double? km) {
  if (km == null || !km.isFinite || km <= 0) return null;
  final value = km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';
  return '${t.trip_distance_label}: $value';
}

String? _formatOfferPriceLine(AppLocalizations t, QueueOfferItem item) {
  final fare = extractFareSomFromMap(item.raw);
  if (fare != null && fare.isFinite && fare > 0) {
    return '${t.trip_price_label}: ${formatDisplayFareSom(fare, suffix: t.currency_som)}';
  }
  if (item.estimatedPriceSom > 0) {
    return '${t.trip_price_label}: '
        '${formatUzsSom(item.estimatedPriceSom.toDouble(), suffix: t.currency_som)}';
  }
  return null;
}

String _newOrderQueueNotificationBody(AppLocalizations t, QueueOfferItem item) {
  final lines = <String>[];
  final price = _formatOfferPriceLine(t, item);
  final dist = _formatOfferDistanceKm(t, item.distanceKm);
  if (price != null) lines.add(price);
  if (dist != null) lines.add(dist);
  lines.add(t.notification_open_app_to_accept);
  return lines.join('\n');
}

/// Promo / referral HTTP is heavy; refresh less often than [GET /driver/available-requests].
const Duration _ancillaryMinGap = Duration(seconds: 60);

/// Foreground dispatch poll (seconds) when the dispatch poke WebSocket is **down**.
/// `GET /driver/available-requests` is a heavy endpoint that also drives most of the
/// dashboard, so this is the degraded-mode cadence, not the normal one.
const int _dispatchPollIdleForegroundSeconds = 4;

/// Slightly looser while assigned / in-flight (driver busy; same endpoint also drives heavy UI).
const int _dispatchPollActiveForegroundSeconds = 8;

/// Background dispatch poll (seconds) when the poke WebSocket is down. Kept short
/// enough that [LocalNotifications.notifyNewOrder] still fires soon after a rider
/// order while the screen is off. The location foreground service
/// ([LocationService.positionStream] background mode) keeps the Dart isolate alive.
/// The backend ~90s live guard is satisfied by [DriverLocationSyncController], not
/// by this poll.
const int _dispatchPollBackgroundIdleSeconds = 6;

/// Slightly relaxed while assigned / in-flight (same endpoint, heavier UI work).
const int _dispatchPollBackgroundActiveSeconds = 10;

/// While `GET /ws/driver-dispatch` is connected it pushes `dispatch_changed` the moment
/// anything changes, so the timer is only a safety net — poll this many times slower.
const int _dispatchPollWsHealthyFactor = 3;

/// On web, when the poke WebSocket is healthy, HTTP is only a backup — use this fixed
/// interval instead of the short native cadence × [_dispatchPollWsHealthyFactor].
const int _dispatchPollWebWsHealthySeconds = 30;

/// Ignore dispatch-WS poke bursts closer than this (reconnect `hello` storms).
const Duration _dispatchWsPokeDebounce = Duration(milliseconds: 1500);

/// Backoff bounds for both WebSockets. A flat 2s retry hammers the server when the
/// route is unavailable, especially combined with the per-poll reconnect nudge.
const Duration _wsReconnectMinDelay = Duration(seconds: 2);
const Duration _wsReconnectMaxDelay = Duration(seconds: 60);

/// Consecutive `GET /driver/available-requests` failures before the dashboard tells the
/// driver dispatch is unreachable (one blip should not raise an alarm).
const int _dispatchFailuresBeforeNotice = 3;

/// Live metered stats from `GET /trip/:id` while [TripStatus.started] (mini-app LIVE_TRIP_POLL_INTERVAL_MS).
const Duration _liveTripPollInterval = Duration(seconds: 3);

/// Server-side long-poll window for `GET /driver/available-requests?wait_sec=`. The server
/// holds the request until dispatch changes or this elapses, then the client re-issues
/// immediately — one connection instead of a tight poll loop. Used only in the foreground,
/// while idle, and only when the dispatch poke WebSocket is NOT already connected (so we
/// never hold a long HTTP request and a WS at the same time).
const int _dispatchLongPollSeconds = 25;

/// Minimum spacing between long-poll *starts*. A backend that predates `wait_sec` returns
/// immediately; without this floor the loop would busy-spin against it. When long poll
/// works the request itself takes ~25s, so this floor never delays anything.
const Duration _dispatchLongPollFloor = Duration(seconds: 3);

class TripController extends Notifier<TripState> {
  Timer? _mockTimer;
  Timer? _pollTimer;
  Timer? _liveTripPollTimer;
  Timer? _lifecyclePollDebounce;
  DateTime? _lastAncillaryPoll;
  MapLatLng? _lastRemoteUiPoint;
  DateTime? _lastRemoteUiAt;
  WebSocketService? _ws;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  Timer? _tripWsReconnectTimer;
  int _tripWsReconnectAttempt = 0;
  WebSocketService? _dispatchWs;
  StreamSubscription<Map<String, dynamic>>? _dispatchWsSub;
  DateTime? _lastDispatchPokeAt;
  String? _lastDispatchWsAuthKey;
  Timer? _dispatchWsReconnectTimer;
  int _dispatchWsReconnectAttempt = 0;

  /// Earliest wall-clock time the next dispatch WS handshake may be attempted. Without
  /// this the per-poll reconnect nudge and the backoff timer race into a connect storm.
  DateTime? _dispatchWsNextAttemptAt;

  int _consecutiveDispatchFailures = 0;

  /// Wall-clock a poll took to return, used to floor the long-poll re-arm.
  Duration _lastPollElapsed = Duration.zero;

  /// Prevents overlapping `GET /driver/available-requests` (timer + WS poke).
  bool _pollInFlight = false;

  /// Set while a poll is in flight so one follow-up runs after it finishes.
  bool _pollDirty = false;

  /// Optimistic status set by a driver button tap, held until the server actually
  /// reports it — see [LocalStatusAdvance]. This is what stops a stale poll/WS echo
  /// from reverting the button under the driver's finger.
  final _localAdvance = LocalStatusAdvance();

  /// Trips finished/cancelled on this device. A finished trip must **never** come back —
  /// but the backend can keep returning it as the assigned trip for a while after
  /// `POST /trip/finish` (read-after-write lag / it doesn't clear `assigned_trip`
  /// promptly). A time-boxed window let it resurrect once the window expired; these ids are
  /// suppressed for the whole session instead. A trip id is unique per trip, so this can
  /// never hide a genuinely new order. Reset when the driver logs out (new controller).
  final Set<String> _finishedTripIds = {};

  /// Queue preview rows dismissed after the dashboard countdown — do not auto-show again until
  /// the request id disappears from [GET /driver/available-requests] (see [_pruneDismissedQueuePreviews]).
  final Set<String> _dismissedQueuePreviewIds = {};
  /// When each queue `request_id` first triggered [LocalNotifications.notifyNewOrder].
  final Map<String, DateTime> _queueOfferNotifiedAt = {};
  String? _lastNotifiedOfferId;
  String? _lastNotifiedAssignedTripId;

  DriverRepository? get _repo => ref.read(driverRepositoryProvider);

  @override
  TripState build() {
    ref.onDispose(() async {
      _mockTimer?.cancel();
      _pollTimer?.cancel();
      _liveTripPollTimer?.cancel();
      _lifecyclePollDebounce?.cancel();
      _dispatchWsReconnectTimer?.cancel();
      _tripWsReconnectTimer?.cancel();
      await _wsSub?.cancel();
      await _ws?.dispose();
      await _dispatchWsSub?.cancel();
      await _dispatchWs?.dispose();
    });

    if (AppConfig.hasHttpApi) {
      ref.listen(driverStatusProvider, (prev, next) {
        if (next == DriverStatus.online) {
          _startPollingWithImmediateRun();
          unawaited(_reconnectDispatchPokeWs());
        } else {
          _lifecyclePollDebounce?.cancel();
          _pollTimer?.cancel();
          _pollTimer = null;
          _cancelLiveTripPoll();
          unawaited(_disconnectDispatchPokeWs());
          _clearDispatchStateWhenGoingOffline();
        }
      });
      ref.listen(driverIdProvider, (prev, next) {
        if (next.isNotEmpty || AppConfig.driverId.isNotEmpty) {
          if (ref.read(driverStatusProvider) == DriverStatus.online) {
            _startPollingWithImmediateRun();
            unawaited(_reconnectDispatchPokeWs());
          }
        } else if (AppConfig.driverId.isEmpty) {
          _lifecyclePollDebounce?.cancel();
          _pollTimer?.cancel();
          _pollTimer = null;
          unawaited(_disconnectWs());
          unawaited(_disconnectDispatchPokeWs());
          _dismissedQueuePreviewIds.clear();
          _queueOfferNotifiedAt.clear();
          _lastNotifiedOfferId = null;
          _lastNotifiedAssignedTripId = null;
          state = const TripState(
            status: TripStatus.waiting,
            activeRequest: null,
          );
        }
      });
      ref.listen(driverSessionProvider, (String? previous, String next) {
        if (previous == next) return;
        if (ref.read(driverStatusProvider) != DriverStatus.online) return;
        unawaited(_reconnectDispatchPokeWs());
      });
      ref.listen(appLifecycleProvider, (
        AppLifecyclePhase? previous,
        AppLifecyclePhase next,
      ) {
        if (previous == next) return;
        if (ref.read(driverStatusProvider) != DriverStatus.online) return;
        if (next == AppLifecyclePhase.backgrounded) {
          // Poll immediately when leaving the app — don't wait for the next timer tick.
          _lifecyclePollDebounce?.cancel();
          _pollTimer?.cancel();
          _pollTimer = null;
          scheduleMicrotask(() async {
            await _pollAvailableRequests();
            _armNextDispatchPollTimer();
            unawaited(_connectDispatchPokeWsIfNeeded());
          });
          return;
        }
        // Resume from background: poll dispatch immediately so orders created while away show up.
        if (previous == AppLifecyclePhase.backgrounded) {
          _lifecyclePollDebounce?.cancel();
          _pollTimer?.cancel();
          _pollTimer = null;
          scheduleMicrotask(() async {
            // The trip may have advanced from the Telegram bot while we were away — do not
            // trust cached local state; refetch it first.
            await _reconcileActiveTripFromApi();
            await _pollAvailableRequests();
            _armNextDispatchPollTimer();
            unawaited(_reconnectDispatchPokeWs());
          });
          return;
        }
        _debounceReschedulePollTimerOnly();
      });
      if (ref.read(driverStatusProvider) == DriverStatus.online &&
          _hasDriverAuth()) {
        _startPollingWithImmediateRun();
        unawaited(_reconnectDispatchPokeWs());
      }
    } else {
      ref.listen(driverStatusProvider, (prev, next) {
        if (next == DriverStatus.offline) {
          _cancelLiveTripPoll();
          _clearDispatchStateWhenGoingOffline();
        }
      });
      _bootstrapMock();
    }

    return const TripState(status: TripStatus.waiting, activeRequest: null);
  }

  /// OFFLINE: hide **queue-only** preview (no `trip_id` yet). Keeps assigned / in-flight trips
  /// (`trip_id` set, or arrived / started) so the driver does not lose the active order UI.
  void _clearDispatchStateWhenGoingOffline() {
    if (ref.read(driverStatusProvider) != DriverStatus.offline) return;
    final s = state;
    if (s.status != TripStatus.waiting) return;
    if (s.activeRequest == null) return;
    final tid = s.activeRequest!.tripId?.trim();
    if (tid != null && tid.isNotEmpty) return;
    unawaited(_disconnectWs());
    state = s.copyWith(
      activeRequest: () => null,
      remoteLiveLocation: () => null,
      fareCompletionPopup: () => null,
      clientOdometerKm: 0,
    );
  }

  void _bootstrapMock() {
    assert(
      !AppConfig.hasHttpApi,
      'Mock offers must never run against a configured backend',
    );
    _mockTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (ref.read(driverStatusProvider) != DriverStatus.online) return;
      if (state.activeRequest != null) return;
      final r = Random();
      const base = MapLatLng(41.311081, 69.240562);
      final pickup = MapLatLng(
        base.latitude + (r.nextDouble() - 0.5) * 0.02,
        base.longitude + (r.nextDouble() - 0.5) * 0.02,
      );
      final destination = MapLatLng(
        base.latitude + (r.nextDouble() - 0.5) * 0.05,
        base.longitude + (r.nextDouble() - 0.5) * 0.05,
      );
      state = state.copyWith(
        activeRequest: () => TripRequest(
          id: 'mock_${DateTime.now().millisecondsSinceEpoch}',
          pickup: pickup,
          destination: destination,
        ),
        status: TripStatus.waiting,
      );
    });
  }

  bool _hasDriverAuth() =>
      AppConfig.driverId.trim().isNotEmpty ||
      ref.read(driverIdProvider).trim().isNotEmpty ||
      AppConfig.telegramInitData.trim().isNotEmpty;

  /// Thin alias around `state = next`. Audio cues are emitted only by the
  /// explicit Start Trip / Finish Trip button handlers — no automatic voice
  /// is produced for any other trip status change.
  void _publishTripState(TripState next) {
    state = next;
  }

  /// Record a driver-tapped optimistic status so polling/WS cannot revert it.
  void _noteLocalAdvance(TripStatus s) =>
      _localAdvance.note(s, state.activeRequest?.tripId);

  void _clearLocalAdvance() => _localAdvance.clear();

  /// Keep a freshly-tapped (optimistic) status from being reverted by a server
  /// snapshot that has not committed the transition yet.
  TripStatus _guardWithLocalAdvance(TripStatus mapped, String? tripId) =>
      _localAdvance.resolve(mapped, tripId);

  /// Immediate dispatch refresh — after going ONLINE or posting fresh location.
  void refreshDispatchNow() {
    if (!AppConfig.hasHttpApi) return;
    if (!_hasDriverAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    _startPollingWithImmediateRun();
  }

  /// Go ONLINE / driver id: one poll now, then a single chained timer (no overlapping bursts).
  void _startPollingWithImmediateRun() {
    _lifecyclePollDebounce?.cancel();
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!AppConfig.hasHttpApi) return;
    if (!_hasDriverAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;

    scheduleMicrotask(() async {
      await _pollAvailableRequests();
      _armNextDispatchPollTimer();
    });
  }

  /// Foreground/background flips on web can fire rapidly; debounce so we only re-arm one timer.
  void _debounceReschedulePollTimerOnly() {
    _lifecyclePollDebounce?.cancel();
    _lifecyclePollDebounce = Timer(const Duration(milliseconds: 450), () {
      if (ref.read(driverStatusProvider) != DriverStatus.online) return;
      if (!_hasDriverAuth()) return;
      _pollTimer?.cancel();
      _armNextDispatchPollTimer();
    });
  }

  /// True while `GET /ws/driver-dispatch` is actually connected, so `dispatch_changed`
  /// pushes arrive immediately and the poll timer can back off to a safety net.
  bool get _dispatchWsHealthy =>
      AppConfig.driverDispatchPokeWsEnabled &&
      (_dispatchWs?.hasActiveChannel ?? false);

  /// Long poll when we're the only thing waiting for offers: foreground, online, idle, and
  /// the push socket is down. During an active trip the driver can't take new orders and
  /// [_syncLiveTripPoll] drives the live UI, so a held offers request buys nothing there.
  bool get _longPollEligible {
    if (!AppConfig.hasHttpApi) return false;
    // Not on web: a 25s held request through the browser + CORS is fragile (preflights
    // stall, connections get dropped), which shows up as spurious "dispatch unreachable".
    // The battery win of long polling is for the native app on an all-day shift; web uses
    // the short chained poll and recovers from blips faster.
    if (kIsWeb) return false;
    if (ref.read(appLifecycleProvider) == AppLifecyclePhase.backgrounded) return false;
    if (state.requiresContinuousLiveLocation) return false;
    if (_dispatchWsHealthy) return false;
    return true;
  }

  void _armNextDispatchPollTimer() {
    _pollTimer?.cancel();
    if (!_hasDriverAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;

    if (_longPollEligible) {
      // Re-issue as soon as the floor allows. The request itself blocks up to
      // _dispatchLongPollSeconds server-side, so when long poll works this is ~immediate.
      final wait = _dispatchLongPollFloor - _lastPollElapsed;
      final delay = wait.isNegative ? Duration.zero : wait;
      _pollTimer = Timer(delay, () {
        scheduleMicrotask(() async {
          await _pollAvailableRequests(waitSec: _dispatchLongPollSeconds);
          _armNextDispatchPollTimer();
        });
      });
      return;
    }

    final bg = ref.read(appLifecycleProvider) == AppLifecyclePhase.backgrounded;
    final tripHeavy = state.requiresContinuousLiveLocation;
    var seconds = bg
        ? (tripHeavy
            ? _dispatchPollBackgroundActiveSeconds
            : _dispatchPollBackgroundIdleSeconds)
        : (tripHeavy
            ? _dispatchPollActiveForegroundSeconds
            : _dispatchPollIdleForegroundSeconds);
    if (_dispatchWsHealthy) {
      // Web: WS carries new orders; keep a slow HTTP safety net only.
      seconds = kIsWeb
          ? _dispatchPollWebWsHealthySeconds
          : seconds * _dispatchPollWsHealthyFactor;
    }
    _pollTimer = Timer(Duration(seconds: seconds), () {
      scheduleMicrotask(() async {
        await _pollAvailableRequests();
        _armNextDispatchPollTimer();
      });
    });
  }

  Future<void> _pollAvailableRequests({int? waitSec}) async {
    if (_pollInFlight) {
      _pollDirty = true;
      return;
    }
    _pollInFlight = true;
    try {
      do {
        _pollDirty = false;
        await _pollAvailableRequestsBody(waitSec: waitSec);
        // Follow-up after a coalesced poke must be a short poll, not another long hold.
        waitSec = null;
      } while (_pollDirty);
    } finally {
      _pollInFlight = false;
    }
    // Poke landed between the last dirty check and unlock — one more coalesced pass.
    if (_pollDirty) {
      await _pollAvailableRequests();
    }
  }

  Future<void> _pollAvailableRequestsBody({int? waitSec}) async {
    final repo = _repo;
    if (repo == null) return;
    if (!_hasDriverAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;

    final pollStarted = DateTime.now();
    try {
      final raw = await repo.getAvailableRequests(waitSec: waitSec);
      _noteDispatchPollSucceeded();
      var bal = parseDriverBalanceFromDispatchJson(raw);
      final walletPath = AppConfig.driverWalletHttpPath.trim();
      if (walletPath.isNotEmpty) {
        try {
          final w = await repo.getRelativeJson(walletPath);
          bal = mergeDriverBalanceSnapshots(
            bal,
            parseDriverBalanceFromDispatchJson(w),
          );
        } catch (_) {}
      }

      state = state.copyWith(driverBalance: bal != null ? () => bal : null);

      // Commission is admin-editable at runtime and rides on this same response, so a
      // change shows up on the next poll. Only overwrite when the field is present — a
      // response that omits it must not blank out the last known value with a guess.
      final commission = parseCommissionFromJson(raw);
      if (commission != null) {
        state = state.copyWith(commission: () => commission);
      }

      Future<void> applyAncillaryThenPublish() async {
        final now = DateTime.now();
        final runAncillary =
            _lastAncillaryPoll == null ||
            now.difference(_lastAncillaryPoll!) >= _ancillaryMinGap;

        Map<String, dynamic>? promoJson;
        Map<String, dynamic>? refStatusJson;
        String? refLink;
        if (runAncillary) {
          _lastAncillaryPoll = now;
          await Future.wait<void>([
            () async {
              try {
                promoJson = await repo.getDriverPromoProgram();
              } catch (_) {}
            }(),
            () async {
              try {
                refStatusJson = await repo.getDriverReferralStatus();
              } catch (_) {}
            }(),
            () async {
              try {
                refLink = await repo.getDriverReferralLink();
              } catch (_) {}
            }(),
          ]);
        }

        if (promoJson != null) {
          bal = mergeDriverBalanceSnapshots(
            bal,
            parseDriverBalanceFromDispatchJson(promoJson!),
          );
        }
        if (refStatusJson != null) {
          bal = mergeDriverBalanceSnapshots(
            bal,
            parseDriverBalanceFromDispatchJson(refStatusJson!),
          );
        }

        final hadPromo = promoJson != null;
        final hadRef = refStatusJson != null;
        final DriverDashboardStats? newDash = (hadPromo || hadRef)
            ? mergeDashboardStats(
                hadPromo ? parseDriverDashboardStats(promoJson!) : null,
                hadRef ? parseDriverDashboardStats(refStatusJson!) : null,
              )
            : null;

        if (runAncillary) {
          state = state.copyWith(
            driverBalance: bal != null ? () => bal : null,
            dashboardStats: newDash != null ? () => newDash : null,
            referralLink: refLink != null ? () => refLink : null,
          );
        } else {
          state = state.copyWith(driverBalance: bal != null ? () => bal : null);
        }

        if (bal == null && kDebugMode && !_walletKeysLogged) {
          _walletKeysLogged = true;
          debugPrint(
            '[yetti_driver] Wallet: no parseable balance after available-requests '
            '(keys: ${raw.keys.join(", ")}), optional DRIVER_WALLET_HTTP_PATH, '
            'GET /driver/promo-program, GET /driver/referral-status. '
            'See backend docs/DRIVER_HTTP_API_HANDOFF.md and DRIVER_CLIENT.md.',
          );
        }
      }

      final snap = parseAvailableRequests(raw);
      _pruneDismissedQueuePreviews(
        snap.queueItems.map((q) => q.requestId).toSet(),
      );

      if (snap.assignedTripId != null && snap.assignedTripStatus != null) {
        final st = snap.assignedTripStatus!.toUpperCase();
        if (st != 'FINISHED' && _isFinishedLocally(snap.assignedTripId)) {
          // Completed on this device moments ago; the server snapshot is simply stale.
          if (kDebugMode) {
            debugPrint(
              '[yetti_driver] ignoring stale assigned_trip for locally finished trip',
            );
          }
          await applyAncillaryThenPublish();
          return;
        }
        if (st == 'FINISHED') {
          // Do not announce "a trip was assigned to you" for a trip that already ended
          // (happens when the app restarts while the server still reports the last trip).
          _lastNotifiedAssignedTripId = snap.assignedTripId;
          final prev = state;
          final req = prev.activeRequest;
          await _disconnectWs();
          state = TripState(
            status: TripStatus.waiting,
            activeRequest: null,
            driverBalance: state.driverBalance,
            remoteLiveLocation: null,
            dashboardStats: state.dashboardStats,
            referralLink: state.referralLink,
            hydrationIssue: TripHydrationIssue.none,
            fareCompletionPopup: TripFareCompletionPopup(
              fareSom: req?.fareSom,
              distanceKm: req?.distanceKm,
            ),
            clientOdometerKm: 0,
            dispatchUnreachable: false,
          );
          await applyAncillaryThenPublish();
          return;
        }
        if (_lastNotifiedAssignedTripId != snap.assignedTripId) {
          _lastNotifiedAssignedTripId = snap.assignedTripId;
          final t = l10nFor(ref);
          final inForeground =
              ref.read(appLifecycleProvider) == AppLifecyclePhase.resumed;
          unawaited(
            LocalNotifications.notifyNewOrder(
              id: snap.assignedTripId.hashCode & 0x7fffffff,
              title: t.notification_trip_assigned_title,
              body: t.notification_trip_assigned_body,
              playRingtone: false,
              appInForeground: inForeground,
            ),
          );
        }
        try {
          final tripJson = await repo.getTrip(snap.assignedTripId!);
          final req = tripRequestFromTripJson(
            tripJson,
            requestId:
                tripJson['request_id']?.toString() ?? snap.assignedTripId!,
          );
          final mapped = parseServerTripStatus(st) ?? TripStatus.waiting;
          final prev = state;
          // UX requirement: do not enforce proximity gating for "Yetib keldim".
          // Some backend deployments still reject ARRIVED/STARTED by distance and keep returning
          // the previous status. Preserve the locally-tapped status once the driver advances the
          // trip, until the server catches up (STARTED/FINISHED) or the trip id changes — otherwise
          // a stale poll reverts the button and the driver has to tap again.
          final effectiveStatus =
              _guardWithLocalAdvance(mapped, snap.assignedTripId);
          _publishTripState(
            state.copyWith(
              activeRequest: () => req,
              status: effectiveStatus,
              remoteLiveLocation: () => null,
              hydrationIssue: TripHydrationIssue.none,
              fareCompletionPopup: () => null,
            ),
          );
          if (effectiveStatus == TripStatus.started) {
            if (prev.status != TripStatus.started ||
                prev.activeRequest?.tripId != req.tripId) {
              state = state.copyWith(clientOdometerKm: 0);
            }
            _syncLiveTripPoll();
          }
          await _connectWsIfNeeded(snap.assignedTripId!);
        } on DioException catch (e) {
          final code = parseDriverApiErrorCode(e);
          if (e.response?.statusCode == 404 || code == 'NOT_FOUND') {
            await _disconnectWs();
            state = state.copyWith(
              hydrationIssue: TripHydrationIssue.tripNotFound,
              activeRequest: () => null,
              status: TripStatus.waiting,
              remoteLiveLocation: () => null,
              fareCompletionPopup: () => null,
              clientOdometerKm: 0,
            );
          } else {
            rethrow;
          }
        }
        await applyAncillaryThenPublish();
        return;
      }

      if (state.activeRequest != null && state.activeRequest!.tripId != null) {
        await applyAncillaryThenPublish();
        return;
      }

      if (snap.queueItems.isEmpty) {
        await applyAncillaryThenPublish();
        return;
      }
      if (state.activeRequest != null) {
        final cur = state.activeRequest!.id;
        final stillThere = snap.queueItems.any((q) => q.requestId == cur);
        if (!stillThere) {
          state = state.copyWith(
            activeRequest: () => null,
            status: TripStatus.waiting,
            remoteLiveLocation: () => null,
            fareCompletionPopup: () => null,
            clientOdometerKm: 0,
            pendingQueueOfferExpiresAt: () => null,
          );
        } else if (_isQueueOnlyRequest(state.activeRequest!)) {
          _expireQueueOfferPreviewIfNeeded(cur);
        }
        await applyAncillaryThenPublish();
        return;
      }

      final first = snap.queueItems.first;
      if (_dismissedQueuePreviewIds.contains(first.requestId)) {
        await applyAncillaryThenPublish();
        return;
      }

      if (_isQueueOfferPreviewExpired(first.requestId)) {
        _expireQueueOfferPreviewIfNeeded(first.requestId);
        await applyAncillaryThenPublish();
        return;
      }

      _markQueueOfferNotified(first.requestId);
      if (_lastNotifiedOfferId != first.requestId) {
        _lastNotifiedOfferId = first.requestId;
        final t = l10nFor(ref);
        final inForeground =
            ref.read(appLifecycleProvider) == AppLifecyclePhase.resumed;
        unawaited(
          LocalNotifications.notifyNewOrder(
            id: first.requestId.hashCode & 0x7fffffff,
            title: t.notification_new_order_title,
            body: _newOrderQueueNotificationBody(t, first),
            playRingtone: true,
            appInForeground: inForeground,
          ),
        );
      }

      state = state.copyWith(
        activeRequest: () => tripRequestFromQueueItem(first),
        status: TripStatus.waiting,
        remoteLiveLocation: () => null,
        fareCompletionPopup: () => null,
        pendingQueueOfferExpiresAt: () => _queueOfferExpiresAt(first.requestId),
      );
      await applyAncillaryThenPublish();
    } catch (e, st) {
      debugPrint('available-requests poll failed: $e\n$st');
      // On Flutter web, in-flight HTTP requests can be aborted/cancelled by the browser
      // (or by rapid navigation / internal re-renders). Treat cancellation as a
      // non-fatal event so we don't flip the UI into "dispatch unreachable" banner.
      if (e is DioException && e.type == DioExceptionType.cancel) {
        if (kDebugMode) {
          debugPrint('[yetti_driver] available-requests poll cancelled; ignoring for dispatch banner');
        }
      } else {
        _noteDispatchPollFailed();
      }
    } finally {
      _lastPollElapsed = DateTime.now().difference(pollStarted);
      // Doze / OEM battery savers can drop WebSockets while the FGS keeps HTTP timers
      // alive. [_connectDispatchPokeWsIfNeeded] honours the backoff window, so this
      // nudge cannot turn into a reconnect storm.
      if (AppConfig.driverDispatchPokeWsEnabled &&
          ref.read(driverStatusProvider) == DriverStatus.online) {
        unawaited(_connectDispatchPokeWsIfNeeded());
      }
    }
  }

  void _noteDispatchPollSucceeded() {
    _consecutiveDispatchFailures = 0;
    if (state.dispatchUnreachable) {
      state = state.copyWith(dispatchUnreachable: false);
    }
  }

  /// Surface repeated dispatch failures instead of leaving the driver staring at an
  /// empty dashboard with no idea the backend is unreachable.
  void _noteDispatchPollFailed() {
    _consecutiveDispatchFailures++;
    if (_consecutiveDispatchFailures >= _dispatchFailuresBeforeNotice &&
        !state.dispatchUnreachable) {
      state = state.copyWith(dispatchUnreachable: true);
    }
  }

  /// Exponential backoff (2s, 4s, 8s … capped) for WebSocket retries.
  static Duration _wsBackoff(int attempt) {
    final ms = _wsReconnectMinDelay.inMilliseconds * (1 << attempt.clamp(0, 5));
    return Duration(
      milliseconds: ms.clamp(
        _wsReconnectMinDelay.inMilliseconds,
        _wsReconnectMaxDelay.inMilliseconds,
      ),
    );
  }

  /// The driver bearer token — the sole required credential (same source the HTTP client
  /// uses). Empty string when not logged in.
  String _driverToken() => ref.read(driverSessionProvider).trim();

  String? _driverIdForQuery() {
    final did = AppConfig.driverId.trim().isNotEmpty
        ? AppConfig.driverId.trim()
        : ref.read(driverIdProvider).trim();
    return did.isNotEmpty ? did : null;
  }

  /// Upgrade headers for native (IO) sockets — `Authorization: Bearer` where the client
  /// supports headers. The `access_token` query param is what authenticates on every
  /// platform (web can't set these), so this is belt-and-suspenders.
  Map<String, String> _wsAuthHeaders() {
    final headers = <String, String>{};
    final token = _driverToken();
    if (token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
    final did = _driverIdForQuery();
    if (did != null) headers['X-Driver-Id'] = did; // harmless legacy hint
    return headers;
  }

  Future<void> _connectWsIfNeeded(String tripId) async {
    final token = _driverToken();
    final url = AppConfig.wsUrlStringForTrip(
      tripId,
      driverIdForQuery: _driverIdForQuery(),
      accessToken: token.isNotEmpty ? token : null,
    );
    if (url.isEmpty) return;
    // Reconnect when the socket for this trip died; only skip if it is genuinely live.
    if (_ws != null && _lastWsTripId == tripId && _ws!.hasActiveChannel) return;

    _tripWsReconnectTimer?.cancel();
    _tripWsReconnectTimer = null;
    await _wsSub?.cancel();
    _wsSub = null;
    await _ws?.dispose();
    _lastWsTripId = tripId;
    // Fresh socket: drop the seq baseline. The reconcile below covers whatever we missed
    // while disconnected; within this connection, seq gaps then trigger their own refetch.
    _lastWsSeq = null;
    final hdr = _wsAuthHeaders();
    final svc = WebSocketService(url: url, connectHeaders: hdr.isEmpty ? null : hdr);
    _ws = svc;
    await svc.connect();
    if (!svc.hasActiveChannel) {
      // The WS upgrade can't reliably report its HTTP status (web hides it; dart:io does
      // not surface it). A dead session therefore surfaces as an HTTP 401 on the frequent
      // polls, which the API interceptor turns into a logout — that tears this socket down.
      // Here we just back off; a plain network blip should not log the driver out.
      _scheduleTripWsReconnect(tripId);
      return;
    }
    _tripWsReconnectAttempt = 0;
    _wsSub = svc.messages.listen(
      _onWsEvent,
      onDone: () => _onTripWsStreamEnded(tripId),
      onError: (Object e, StackTrace st) => _onTripWsStreamEnded(tripId),
    );
    // The trip may have advanced (bot, or events dropped) while the socket was down.
    unawaited(_reconcileActiveTripFromApi());
  }

  /// The trip socket carries `trip_started` / `trip_finished` / `trip_cancelled` and the
  /// rider's live position. Losing it silently for the rest of a trip is not acceptable,
  /// so re-establish it as long as the same trip is still active.
  void _onTripWsStreamEnded(String tripId) {
    if (state.activeRequest?.tripId != tripId) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    _scheduleTripWsReconnect(tripId);
  }

  void _scheduleTripWsReconnect(String tripId) {
    _tripWsReconnectTimer?.cancel();
    final delay = _wsBackoff(_tripWsReconnectAttempt);
    _tripWsReconnectAttempt++;
    if (kDebugMode) {
      debugPrint(
        '[yetti_driver] trip WS: reconnecting in ${delay.inSeconds}s '
        '(attempt $_tripWsReconnectAttempt)',
      );
    }
    _tripWsReconnectTimer = Timer(delay, () {
      if (state.activeRequest?.tripId != tripId) return;
      if (ref.read(driverStatusProvider) != DriverStatus.online) return;
      unawaited(_connectWsIfNeeded(tripId));
    });
  }

  /// Tear down then re-establish the poke socket, in that order. Firing both as
  /// independent futures raced: the connect could observe the old socket and bail.
  Future<void> _reconnectDispatchPokeWs() async {
    await _disconnectDispatchPokeWs();
    await _connectDispatchPokeWsIfNeeded();
  }

  Future<void> _connectDispatchPokeWsIfNeeded() async {
    if (!AppConfig.driverDispatchPokeWsEnabled) return;
    if (!_hasDriverAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    final token = _driverToken();
    final url = AppConfig.wsUrlStringForDriverDispatch(
      driverIdForQuery: _driverIdForQuery(),
      accessToken: token.isNotEmpty ? token : null,
    );
    if (url.isEmpty) return;

    final authKey = _dispatchWsAuthFingerprint();
    if (_dispatchWs != null &&
        _lastDispatchWsAuthKey == authKey &&
        _dispatchWs!.hasActiveChannel) {
      return;
    }

    // Respect the backoff window: this method is also nudged from every dispatch poll.
    final notBefore = _dispatchWsNextAttemptAt;
    if (notBefore != null && DateTime.now().isBefore(notBefore)) return;

    await _disconnectDispatchPokeWs(resetBackoff: false);

    final hdr = _dispatchWsHeaders();
    final svc = WebSocketService(
      url: url,
      connectHeaders: hdr.isEmpty ? null : hdr,
    );
    await svc.connect();
    if (!svc.hasActiveChannel) {
      if (kDebugMode) {
        debugPrint(
          '[yetti_driver] dispatch WS: connect failed or no channel; will retry',
        );
      }
      _scheduleDispatchWsReconnect();
      return;
    }

    _dispatchWs = svc;
    _lastDispatchWsAuthKey = authKey;
    _dispatchWsReconnectAttempt = 0;
    _dispatchWsNextAttemptAt = null;
    _dispatchWsSub = _dispatchWs!.messages.listen(
      (m) {
        // Best-effort poke: any message means "the queue may have changed, refetch".
        // `hello` fires on (re)connect, `dispatch_changed` on queue changes — both refetch.
        if (ref.read(driverStatusProvider) != DriverStatus.online) return;
        if (!_hasDriverAuth()) return;

        final now = DateTime.now();
        final last = _lastDispatchPokeAt;
        if (last != null && now.difference(last) < _dispatchWsPokeDebounce) {
          return;
        }
        _lastDispatchPokeAt = now;

        _lifecyclePollDebounce?.cancel();
        _pollTimer?.cancel();
        _pollTimer = null;
        scheduleMicrotask(() async {
          await _pollAvailableRequests();
          _armNextDispatchPollTimer();
        });
      },
      onDone: _onDispatchWsStreamEnded,
      onError: (Object e, StackTrace st) => _onDispatchWsStreamEnded(),
    );
  }

  void _onDispatchWsStreamEnded() {
    if (!AppConfig.driverDispatchPokeWsEnabled) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    unawaited(
      _disconnectDispatchPokeWs(resetBackoff: false)
          .then((_) => _scheduleDispatchWsReconnect()),
    );
  }

  void _scheduleDispatchWsReconnect() {
    if (!AppConfig.driverDispatchPokeWsEnabled) return;
    _dispatchWsReconnectTimer?.cancel();
    final delay = _wsBackoff(_dispatchWsReconnectAttempt);
    _dispatchWsReconnectAttempt++;
    _dispatchWsNextAttemptAt = DateTime.now().add(delay);
    if (kDebugMode) {
      debugPrint(
        '[yetti_driver] dispatch WS: reconnecting in ${delay.inSeconds}s '
        '(attempt $_dispatchWsReconnectAttempt)',
      );
    }
    _dispatchWsReconnectTimer = Timer(delay, () {
      _dispatchWsNextAttemptAt = null;
      if (ref.read(driverStatusProvider) != DriverStatus.online) return;
      unawaited(_connectDispatchPokeWsIfNeeded());
    });
  }

  Map<String, String> _dispatchWsHeaders() {
    final headers = _wsAuthHeaders(); // Authorization: Bearer + X-Driver-Id (native)
    final session = _driverToken();
    if (session.isNotEmpty) {
      headers['X-Driver-Session'] = session; // harmless legacy hint
    }
    return headers;
  }

  String _dispatchWsAuthFingerprint() {
    final did = AppConfig.driverId.trim().isNotEmpty
        ? AppConfig.driverId.trim()
        : ref.read(driverIdProvider).trim();
    final session = ref.read(driverSessionProvider).trim();
    return '$did|${session.isEmpty ? '-' : session}';
  }

  /// [resetBackoff]: true for deliberate teardown (going offline, auth change) so the
  /// next connect is immediate; false when the socket dropped and backoff must persist.
  Future<void> _disconnectDispatchPokeWs({bool resetBackoff = true}) async {
    _dispatchWsReconnectTimer?.cancel();
    _dispatchWsReconnectTimer = null;
    await _dispatchWsSub?.cancel();
    _dispatchWsSub = null;
    await _dispatchWs?.dispose();
    _dispatchWs = null;
    _lastDispatchWsAuthKey = null;
    if (resetBackoff) {
      _dispatchWsReconnectAttempt = 0;
      _dispatchWsNextAttemptAt = null;
    }
  }

  String? _lastWsTripId;

  /// Last `seq` seen on the trip socket. `seq` is monotonic per trip; a jump means the
  /// server dropped best-effort events (its queue was full), so we refetch and reconcile.
  int? _lastWsSeq;

  Future<void> _disconnectWs() async {
    _cancelLiveTripPoll();
    _clearLocalAdvance();
    _tripWsReconnectTimer?.cancel();
    _tripWsReconnectTimer = null;
    _tripWsReconnectAttempt = 0;
    _lastWsTripId = null;
    _lastWsSeq = null;
    _lastRemoteUiPoint = null;
    _lastRemoteUiAt = null;
    await _wsSub?.cancel();
    _wsSub = null;
    await _ws?.dispose();
    _ws = null;
  }

  /// Refetch `GET /trip/:id` and reconcile local state to the server — used when the
  /// socket signals a gap ([Task 5]) and on resume / reconnect ([Task 4]), because the
  /// trip may have advanced from the Telegram bot without the app doing anything.
  ///
  /// Respects the optimistic hold: a status the driver just tapped is not reverted by a
  /// server snapshot that has not caught up ([_guardWithLocalAdvance]).
  Future<void> _reconcileActiveTripFromApi() async {
    final tid = state.activeRequest?.tripId?.trim();
    final repo = _repo;
    if (tid == null || tid.isEmpty || repo == null) return;
    if (_isFinishedLocally(tid)) return;
    try {
      final json = await repo.getTrip(tid);
      final req = tripRequestFromTripJson(
        json,
        requestId: state.activeRequest?.id ?? tid,
      ).copyWith(tripId: () => tid);
      final serverStatus = parseServerTripStatus(tripStatusStringFromJson(json));

      if (serverStatus == TripStatus.finished) {
        // Completed or cancelled on another surface (bot). Close it out locally.
        final prev = state;
        _markTripFinishedLocally(tid);
        _cancelLiveTripPoll();
        _publishTripState(
          state.copyWith(
            status: TripStatus.finished,
            activeRequest: () => null,
            remoteLiveLocation: () => null,
            fareCompletionPopup: () => TripFareCompletionPopup(
              fareSom: req.fareSom ?? prev.activeRequest?.fareSom,
              distanceKm: req.distanceKm ?? prev.activeRequest?.distanceKm,
            ),
            clientOdometerKm: 0,
          ),
        );
        await _disconnectWs();
        return;
      }

      final guarded = serverStatus != null
          ? _guardWithLocalAdvance(serverStatus, tid)
          : state.status;
      final wasStarted = state.status == TripStatus.started;
      _publishTripState(state.copyWith(activeRequest: () => req, status: guarded));
      if (guarded == TripStatus.started && !wasStarted) _syncLiveTripPoll();
    } catch (e) {
      debugPrint('[yetti_driver] trip reconcile failed: $e');
    }
  }

  void _cancelLiveTripPoll() {
    _liveTripPollTimer?.cancel();
    _liveTripPollTimer = null;
  }

  /// `GET /trip/:id` every [_liveTripPollInterval] while trip is STARTED (fare / distance from API).
  void _syncLiveTripPoll() {
    _cancelLiveTripPoll();
    if (state.status != TripStatus.started) return;
    final tid = state.activeRequest?.tripId?.trim();
    if (tid == null || tid.isEmpty) return;
    if (_repo == null || !AppConfig.hasHttpApi) return;
    _liveTripPollTimer = Timer.periodic(_liveTripPollInterval, (_) {
      unawaited(_refreshActiveTripFromApi());
    });
    unawaited(_refreshActiveTripFromApi());
  }

  Future<void> _refreshActiveTripFromApi() async {
    final tid = state.activeRequest?.tripId?.trim();
    final repo = _repo;
    if (tid == null || repo == null) return;
    if (state.status != TripStatus.started) return;
    try {
      final json = await repo.getTrip(tid);
      final rid = state.activeRequest!.id;
      final req = tripRequestFromTripJson(
        json,
        requestId: rid,
      ).copyWith(tripId: () => tid);
      state = state.copyWith(activeRequest: () => req);
    } catch (_) {}
  }

  /// Server `ws.Event`-shaped JSON: `type`, `trip_id`, `trip_status`, `emitted_at` (RFC3339), `payload`.
  /// Inbound `emitted_at` is not the same field as HTTP app-location body `timestamp` (Unix seconds).
  void _onWsEvent(Map<String, dynamic> m) {
    final type = m['type']?.toString() ?? '';
    final code = (m['code']?.toString() ?? '').toUpperCase();
    if (type == 'session_revoked' ||
        type == 'auth_session_revoked' ||
        code == 'SESSION_REPLACED' ||
        code == 'SESSION_INVALIDATED' ||
        code == 'LOGIN_ELSEWHERE') {
      unawaited(handleDriverSessionRevoked(ref));
      return;
    }

    // Best-effort delivery: the server drops events when a queue is full. `seq` is
    // monotonic per trip, so a jump of more than 1 means we missed something — refetch
    // and reconcile rather than trusting the event stream. The event still processes
    // below; the socket is a hint, never the source of truth (bot can also advance trips).
    final seq = _wsInt(m['seq']);
    if (seq != null) {
      final last = _lastWsSeq;
      if (last != null && seq > last + 1) {
        if (kDebugMode) {
          debugPrint('[yetti_driver] WS seq gap: $last -> $seq, reconciling');
        }
        unawaited(_reconcileActiveTripFromApi());
      }
      if (last == null || seq > last) _lastWsSeq = seq;
    }

    if (type == 'driver_location_update') {
      final payload = m['payload'];
      Map<String, dynamic>? map;
      if (payload is Map) {
        map = Map<String, dynamic>.from(
          payload.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
      final lat = _wsNum(map?['lat'] ?? map?['latitude'] ?? m['lat']);
      final lng = _wsNum(map?['lng'] ?? map?['longitude'] ?? m['lng']);
      if (lat != null && lng != null) {
        final next = MapLatLng(lat, lng);
        final t = DateTime.now();
        final prev = _lastRemoteUiPoint;
        if (prev != null && _lastRemoteUiAt != null) {
          final dt = t.difference(_lastRemoteUiAt!);
          final dLat = (next.latitude - prev.latitude).abs();
          final dLng = (next.longitude - prev.longitude).abs();
          if (dt < const Duration(seconds: 2) &&
              dLat < 0.00012 &&
              dLng < 0.00012) {
            return;
          }
        }
        _lastRemoteUiPoint = next;
        _lastRemoteUiAt = t;
        state = state.copyWith(remoteLiveLocation: () => next);
      }
      return;
    }

    final tripStatus = m['trip_status']?.toString();

    TripStatus? fromType() {
      switch (type) {
        case 'trip_arrived':
          return TripStatus.arrived;
        case 'trip_started':
          return TripStatus.started;
        case 'trip_finished':
          return TripStatus.finished;
        case 'trip_cancelled':
          return TripStatus.finished;
        default:
          return null;
      }
    }

    final ts = parseServerTripStatus(tripStatus) ?? fromType();
    if (ts != null) {
      if (ts == TripStatus.finished) {
        final prev = state;
        _lastRemoteUiPoint = null;
        _lastRemoteUiAt = null;
        final cancelled = type == 'trip_cancelled';
        final req = prev.activeRequest;
        final fareMap = _wsPayloadFareMap(m);
        var fare = req?.fareSom;
        var dist = req?.distanceKm;
        if (fareMap != null) {
          fare ??= extractFareSomFromMap(fareMap);
          dist ??= extractDistanceKmFromMap(fareMap);
        }
        final odo = prev.clientOdometerKm;
        if ((dist == null || dist <= 0) && odo > 0) {
          dist = odo;
        }
        state = prev.copyWith(
          status: TripStatus.finished,
          activeRequest: () => null,
          remoteLiveLocation: () => null,
          fareCompletionPopup: () => cancelled
              ? null
              : TripFareCompletionPopup(fareSom: fare, distanceKm: dist),
          clientOdometerKm: 0,
        );
        scheduleMicrotask(_disconnectWs);
      } else {
        final prev = state;
        final guarded = _guardWithLocalAdvance(ts, state.activeRequest?.tripId);
        final nextOdo = guarded == TripStatus.started
            ? (prev.status == TripStatus.started ? prev.clientOdometerKm : 0.0)
            : 0.0;
        _publishTripState(
          state.copyWith(status: guarded, clientOdometerKm: nextOdo),
        );
        if (guarded == TripStatus.started) {
          _syncLiveTripPoll();
        }
      }
    }
  }

  void clearTripHydrationNotice() {
    if (state.hydrationIssue == TripHydrationIssue.none) return;
    state = state.copyWith(hydrationIssue: TripHydrationIssue.none);
  }

  void clearFareCompletionPopup() {
    if (state.fareCompletionPopup == null) return;
    state = state.copyWith(fareCompletionPopup: () => null);
  }

  /// Yo‘nalshsiz taxi: safar boshlangandan keyin GPS segmentlari yig‘iladi ([HomeScreen]).
  void addClientOdometerKm(double km) {
    if (state.status != TripStatus.started) return;
    if (km <= 0) return;
    state = state.copyWith(clientOdometerKm: state.clientOdometerKm + km);
  }

  void _pruneDismissedQueuePreviews(Set<String> currentRequestIds) {
    _dismissedQueuePreviewIds.removeWhere(
      (id) => !currentRequestIds.contains(id),
    );
    _queueOfferNotifiedAt.removeWhere(
      (id, _) => !currentRequestIds.contains(id),
    );
  }

  static bool _isQueueOnlyRequest(TripRequest req) {
    final tid = req.tripId?.trim();
    return tid == null || tid.isEmpty;
  }

  DateTime _queueOfferExpiresAt(String requestId) {
    final started = _queueOfferNotifiedAt[requestId] ?? DateTime.now();
    return started.add(kQueueOfferPreviewWindow);
  }

  bool _isQueueOfferPreviewExpired(String requestId) {
    final started = _queueOfferNotifiedAt[requestId];
    if (started == null) return false;
    return DateTime.now().difference(started) >= kQueueOfferPreviewWindow;
  }

  void _markQueueOfferNotified(String requestId) {
    _queueOfferNotifiedAt.putIfAbsent(requestId, () => DateTime.now());
  }

  /// Hide expired queue preview (poll path — works while app is backgrounded).
  void _expireQueueOfferPreviewIfNeeded(String requestId) {
    if (!_isQueueOfferPreviewExpired(requestId)) return;
    _dismissedQueuePreviewIds.add(requestId);
    final req = state.activeRequest;
    if (req != null && req.id == requestId && _isQueueOnlyRequest(req)) {
      state = state.copyWith(
        activeRequest: () => null,
        remoteLiveLocation: () => null,
        fareCompletionPopup: () => null,
        clientOdometerKm: 0,
        pendingQueueOfferExpiresAt: () => null,
      );
    }
  }

  /// Hide the dashboard queue offer after the local countdown; the request can remain in
  /// [GET /driver/available-requests] (see Available Requests screen).
  void dismissQueueOfferPreview() {
    final req = state.activeRequest;
    if (req == null) return;
    final tid = req.tripId;
    if (tid != null && tid.isNotEmpty) return;
    _dismissedQueuePreviewIds.add(req.id);
    state = state.copyWith(
      activeRequest: () => null,
      remoteLiveLocation: () => null,
      fareCompletionPopup: () => null,
      clientOdometerKm: 0,
      pendingQueueOfferExpiresAt: () => null,
    );
  }

  /// Accept current queue offer — `POST /driver/accept-request` with `request_id`.
  Future<void> acceptOffer() async {
    final req = state.activeRequest;
    if (req == null) return;
    await acceptOfferByRequestId(req.id);
  }

  /// Accept a row from the queue (e.g. Available Requests screen) by `request_id`.
  ///
  /// Throws [DriverUserException] on every failure path — including the ones where the
  /// server answers 200 without giving us a trip — so the caller never hides an offer
  /// that was not actually assigned.
  Future<void> acceptOfferByRequestId(String requestId) async {
    final id = requestId.trim();
    if (id.isEmpty) {
      throw DriverUserException('', userCode: 'ACCEPT_FAILED');
    }
    if (ref.read(driverStatusProvider) != DriverStatus.online) {
      throw DriverUserException('', userCode: 'ACCEPT_REQUIRES_ONLINE');
    }
    _dismissedQueuePreviewIds.remove(id);

    final repo = _repo;
    if (repo == null) {
      // Mock mode (no HTTP API configured).
      state = state.copyWith(
        status: TripStatus.waiting,
        fareCompletionPopup: () => null,
      );
      return;
    }

    try {
      final res = await repo.acceptRequest(requestId: id);
      String? tripId = res['trip_id']?.toString();
      if (tripId == null || tripId.isEmpty) {
        final tr = res['trip'];
        if (tr is Map) {
          tripId = tr['id']?.toString();
        }
      }
      if (tripId == null || tripId.isEmpty) {
        // 200 with no usable trip reference — treat as a failed accept rather than
        // silently dropping the offer from the dashboard.
        throw DriverUserException('', userCode: 'ACCEPT_FAILED');
      }

      // Use the trip the accept response already returned when it carries coordinates;
      // an unconditional `GET /trip/:id` doubled the latency of every Accept.
      final inlineTrip = res['trip'];
      TripRequest? merged;
      if (inlineTrip is Map) {
        final candidate = tripRequestFromTripJson(
          Map<String, dynamic>.from(
            inlineTrip.map((k, v) => MapEntry(k.toString(), v)),
          ),
          requestId: id,
        ).copyWith(tripId: () => tripId);
        if (candidate.pickup != null) merged = candidate;
      }
      if (merged == null) {
        final tripJson = await repo.getTrip(tripId);
        merged = tripRequestFromTripJson(
          tripJson,
          requestId: id,
        ).copyWith(tripId: () => tripId);
      }
      _publishTripState(
        state.copyWith(
          activeRequest: () => merged,
          status: TripStatus.waiting,
          remoteLiveLocation: () => null,
          hydrationIssue: TripHydrationIssue.none,
          fareCompletionPopup: () => null,
        ),
      );
      await _connectWsIfNeeded(tripId);
    } on DioException catch (e) {
      // Backend now forbids a second active trip. This is NOT "someone else took it" —
      // the offer is still in the driver's list, so showing "no longer available" would
      // loop them re-tapping. Route them to the trip they already have instead.
      if (isDriverHasActiveTripError(e)) {
        final activeTripId = activeTripIdFromError(e);
        if (activeTripId != null) {
          try {
            await hydrateAndActivateTrip(activeTripId, requestId: activeTripId);
          } catch (err) {
            debugPrint('[yetti_driver] failed to hydrate active trip: $err');
          }
        }
        throw DriverUserException(
          parseDriverApiErrorMessage(e) ?? '',
          userCode: 'DRIVER_HAS_ACTIVE_TRIP',
        );
      }
      throw _acceptException(e);
    }
  }

  /// Fetch [tripId], adopt its **server** status (it may already be ARRIVED/STARTED —
  /// e.g. advanced from the Telegram bot), publish it as the active trip, and attach the
  /// trip WebSocket. Used by the "you already have a trip" accept path and by resume.
  Future<void> hydrateAndActivateTrip(
    String tripId, {
    required String requestId,
  }) async {
    final repo = _repo;
    if (repo == null) return;
    final tripJson = await repo.getTrip(tripId);
    final merged = tripRequestFromTripJson(tripJson, requestId: requestId)
        .copyWith(tripId: () => tripId);
    final serverStatus =
        parseServerTripStatus(tripStatusStringFromJson(tripJson)) ?? TripStatus.waiting;
    if (serverStatus == TripStatus.finished) {
      // Nothing to route to; leave state as-is.
      return;
    }
    _clearLocalAdvance();
    _publishTripState(
      state.copyWith(
        activeRequest: () => merged,
        status: serverStatus,
        remoteLiveLocation: () => null,
        hydrationIssue: TripHydrationIssue.none,
        fareCompletionPopup: () => null,
        clientOdometerKm: 0,
      ),
    );
    await _connectWsIfNeeded(tripId);
    if (serverStatus == TripStatus.started) _syncLiveTripPoll();
  }

  DriverUserException _acceptException(DioException e) {
    final code = parseDriverApiErrorCode(e);
    final msg = parseDriverApiErrorMessage(e);
    final status = e.response?.statusCode;
    // Defensive: if this is ever reached for the active-trip conflict, do not mislabel it.
    if (isDriverHasActiveTripError(e)) {
      return DriverUserException(msg ?? '', userCode: 'DRIVER_HAS_ACTIVE_TRIP');
    }
    if (status == 409 ||
        code == 'REQUEST_UNAVAILABLE' ||
        code == 'REQUEST_TAKEN') {
      return DriverUserException(
        msg ?? 'Bu buyurtma endi mavjud emas yoki boshqa haydovchiga berilgan.',
      );
    }
    if (status == 403) {
      return DriverUserException(
        msg ?? 'Buyurtmani qabul qilishga ruxsat yo‘q.',
      );
    }
    if (status == 404 || code == 'NOT_FOUND') {
      return DriverUserException(msg ?? '', userCode: 'TRIP_NOT_FOUND');
    }
    return DriverUserException(msg ?? 'Qabul qilishda xatolik.');
  }

  DriverUserException _tripActionException(DioException e, String fallback) {
    final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase();
    final msg = parseDriverApiErrorMessage(e);
    if (code == 'DRIVER_LOCATION_STALE') {
      return DriverUserException(
        msg ??
            'Lokatsiya yangilanmadi. GPS yoqilganini tekshiring va biroz kuting.',
        userCode: 'DRIVER_LOCATION_STALE',
      );
    }
    if (code == 'LIVE_LOCATION_INACTIVE') {
      return DriverUserException(
        msg ??
            'Lokatsiya faol emas. Ilovaga lokatsiya ruxsatini bering va ONLINE bo‘ling.',
        userCode: 'LIVE_LOCATION_INACTIVE',
      );
    }
    // Go sometimes returns the full localized sentence in `code` (e.g. trip pickup/start guards).
    if (isTelegramLiveLocationBackendError(e)) {
      return DriverUserException(
        msg ?? fallback,
        userCode: 'LIVE_LOCATION_INACTIVE',
      );
    }
    return DriverUserException(msg ?? fallback);
  }

  /// [lat]/[lng]/[accuracy]/[fixTime]: native HTTP-live parity — same fix as [flushHttpNowAt] + optional WS ping.
  Future<void> toArrived({
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? fixTime,
  }) async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) {
      throw DriverUserException('', userCode: 'TRIP_ACTION_NO_TRIP');
    }
    final prevStatus = state.status;
    final prevOdometer = state.clientOdometerKm;
    _publishTripState(
      state.copyWith(status: TripStatus.arrived, clientOdometerKm: 0),
    );
    _noteLocalAdvance(TripStatus.arrived);
    final repo = _repo;
    if (repo != null) {
      if (lat != null && lng != null) {
        sendDriverLocationWs(lat: lat, lng: lng);
      }
      try {
        await repo.postTripArrived(
          tid,
          lat: lat,
          lng: lng,
          accuracy: accuracy,
          timestamp: fixTime,
        );
        // NOTE: deliberately do NOT clear the advance here. A 200 means the request was
        // accepted, not that `assigned_trip.status` is already updated — the next poll
        // frequently still returns the old status and would revert the button.
        // [LocalStatusAdvance] releases it when the server actually reports ARRIVED.
      } on DioException catch (e) {
        // UX requirement: do not block "Yetib keldim" based on distance/proximity.
        // If the backend enforces a proximity check, treat that specific rejection as non-fatal
        // and proceed to ARRIVED locally.
        if (kDebugMode) {
          final code = parseDriverApiErrorCode(e);
          debugPrint(
            '[yetti_driver] POST /trip/arrived failed: HTTP ${e.response?.statusCode ?? '—'} code=${code ?? '—'}',
          );
        }
        if (!isPickupProximityRejection(e)) {
          _clearLocalAdvance();
          _revertStatus(prevStatus, prevOdometer);
          throw _tripActionException(e, 'Yetib kelishni qayd etib bo‘lmadi.');
        }
        // Kept locally on purpose: the server will never confirm it, and
        // [LocalStatusAdvance] has no timeout, so it stays until the trip changes.
      }
    }
  }

  /// Roll the status back after a failed transition **without** clobbering anything a
  /// concurrent poll wrote meanwhile (balance, dashboard stats, rider live location).
  /// Restoring a whole pre-tap [TripState] snapshot used to discard those updates.
  void _revertStatus(TripStatus status, double odometerKm) {
    _publishTripState(
      state.copyWith(status: status, clientOdometerKm: odometerKm),
    );
  }

  Future<void> startTrip({
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? fixTime,
  }) async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) {
      throw DriverUserException('', userCode: 'TRIP_ACTION_NO_TRIP');
    }
    final prevStatus = state.status;
    final prevOdometer = state.clientOdometerKm;
    _publishTripState(
      state.copyWith(status: TripStatus.started, clientOdometerKm: 0),
    );
    // Tap feedback must be instant; do not wait for network round-trips.
    unawaited(TripStatusVoice.playStartTripSound());
    _noteLocalAdvance(TripStatus.started);
    _syncLiveTripPoll();
    final repo = _repo;
    if (repo != null) {
      if (lat != null && lng != null) {
        sendDriverLocationWs(lat: lat, lng: lng);
      }
      try {
        await repo.postTripStart(
          tid,
          lat: lat,
          lng: lng,
          accuracy: accuracy,
          timestamp: fixTime,
        );
        // See [toArrived]: a 200 does not mean the server has committed STARTED yet.
      } on DioException catch (e) {
        if (kDebugMode) {
          final code = parseDriverApiErrorCode(e);
          debugPrint(
            '[yetti_driver] POST /trip/start failed: HTTP ${e.response?.statusCode ?? '—'} code=${code ?? '—'}',
          );
        }
        // Same soft rejections as [toArrived] (proximity / Telegram-live wording) — advance locally for UX parity with web.
        if (!isPickupProximityRejection(e)) {
          _clearLocalAdvance();
          _revertStatus(prevStatus, prevOdometer);
          _cancelLiveTripPoll();
          throw _tripActionException(e, 'Safarni boshlab bo‘lmadi.');
        }
      }
    }
  }

  /// `POST /trip/finish` — end trip from driver; then disconnect WS (same local cleanup as cancel).
  Future<void> finishTrip() async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) {
      throw DriverUserException('', userCode: 'TRIP_ACTION_NO_TRIP');
    }
    final req = state.activeRequest;
    final odoKm = state.clientOdometerKm;
    double? mergeKm(double? api) {
      if (api != null && api > 0) return api;
      return odoKm > 0 ? odoKm : null;
    }

    // Fare/distance are already fresh: [_syncLiveTripPoll] refreshes `GET /trip/:id`
    // every 3s for the whole STARTED phase. Re-fetching it after the finish added a
    // second sequential round trip (~0.6s) before the driver saw anything happen.
    final popup = TripFareCompletionPopup(
      fareSom: req?.fareSom,
      distanceKm: mergeKm(req?.distanceKm),
    );
    final prevStatus = state.status;
    final prevRequest = req;
    final prevOdometer = odoKm;
    final prevRemoteLiveLocation = state.remoteLiveLocation;

    // Publish first so the UI settles on the tap; roll back if the server refuses.
    // A poll started before the finish landed can still carry `assigned_trip` for this
    // trip and would re-hydrate it as active, so suppress that id for a short window.
    _markTripFinishedLocally(tid);
    _cancelLiveTripPoll();
    _publishTripState(
      state.copyWith(
        status: TripStatus.finished,
        activeRequest: () => null,
        remoteLiveLocation: () => null,
        fareCompletionPopup: () => popup,
        clientOdometerKm: 0,
      ),
    );
    unawaited(TripStatusVoice.playFinishTripSound());

    final repo = _repo;
    if (repo != null) {
      try {
        await repo.postTripFinish(tid);
      } on DioException catch (e) {
        _unmarkTripFinishedLocally(tid);
        _publishTripState(
          state.copyWith(
            status: prevStatus,
            activeRequest: () => prevRequest,
            remoteLiveLocation: () => prevRemoteLiveLocation,
            fareCompletionPopup: () => null,
            clientOdometerKm: prevOdometer,
          ),
        );
        if (prevStatus == TripStatus.started) _syncLiveTripPoll();
        throw _tripActionException(e, 'Safarni tugatib bo‘lmadi.');
      }
    }
    await _disconnectWs();
  }

  void _markTripFinishedLocally(String tripId) {
    _finishedTripIds.add(tripId);
    // Bound growth over a very long session; UUIDs are tiny but keep it sane.
    if (_finishedTripIds.length > 200) {
      _finishedTripIds.remove(_finishedTripIds.first);
    }
  }

  /// Undo the local finish mark — used when `POST /trip/finish` fails and we roll back.
  void _unmarkTripFinishedLocally(String tripId) => _finishedTripIds.remove(tripId);

  /// True when [tripId] was completed/cancelled on this device. Such a trip must never be
  /// resurrected by a stale server snapshot, for the rest of the session.
  bool _isFinishedLocally(String? tripId) =>
      tripId != null && _finishedTripIds.contains(tripId);

  /// `POST /trip/cancel/driver` — driver cancel; then disconnect WS.
  Future<void> cancelTripAsDriver() async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) {
      throw DriverUserException('', userCode: 'TRIP_ACTION_NO_TRIP');
    }
    final repo = _repo;
    if (repo != null) {
      try {
        await repo.postTripCancelDriver(tid);
      } on DioException catch (e) {
        throw _tripActionException(e, 'Safarni bekor qilib bo‘lmadi.');
      }
    }
    _markTripFinishedLocally(tid);
    state = state.copyWith(
      status: TripStatus.finished,
      activeRequest: () => null,
      remoteLiveLocation: () => null,
      fareCompletionPopup: () => null,
      clientOdometerKm: 0,
    );
    await _disconnectWs();
  }

  /// WebSocket-only driver position (during active trip). `timestamp` = Unix seconds (int), same rule as HTTP
  /// [DriverApiClient.postDriverLocation]; distinct from inbound `emitted_at` (RFC3339) on server events.
  void sendDriverLocationWs({required double lat, required double lng}) {
    // Driver coordinates are personal data — never write them to release logs.
    if (kDebugMode && AppConfig.debugLocation) {
      debugPrint('[yetti_driver] Sending WS location -> lat: $lat, lng: $lng');
    }
    _ws?.sendJson({
      'type': 'driver_location',
      'lat': lat,
      'lng': lng,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }
}

double? _wsNum(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _wsInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

Map<String, dynamic>? _wsPayloadFareMap(Map<String, dynamic> m) {
  final payload = m['payload'];
  if (payload is! Map) return null;
  final flat = Map<String, dynamic>.from(
    payload.map((k, v) => MapEntry(k.toString(), v)),
  );
  final trip = flat['trip'];
  if (trip is Map) {
    for (final e in trip.entries) {
      flat.putIfAbsent(e.key.toString(), () => e.value);
    }
  }
  return flat;
}

final tripProvider = NotifierProvider<TripController, TripState>(
  TripController.new,
);
