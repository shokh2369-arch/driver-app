import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/geo/lat_lng.dart';
import '../../../data/repositories/driver_repository.dart';
import '../../../services/api_error_parser.dart';
import '../../../services/app_lifecycle_provider.dart';
import '../../../services/config.dart';
import '../../../services/driver_session_revocation.dart';
import '../../../services/driver_dashboard_parser.dart';
import '../../../services/driver_dispatch_parser.dart'
    show
        extractDistanceKmFromMap,
        extractFareSomFromMap,
        mergeDriverBalanceSnapshots,
        parseAvailableRequests,
        parseDriverBalanceFromDispatchJson,
        parseServerTripStatus,
        tripRequestFromQueueItem,
        tripRequestFromTripJson;
import '../../../services/driver_user_exception.dart';
import '../../../services/service_providers.dart';
import '../../../services/websocket_service.dart';
import '../../../services/local_notifications.dart';
import '../../driver/domain/driver_status.dart';
import '../../driver/presentation/driver_id_controller.dart';
import '../../driver/presentation/driver_status_controller.dart';
import '../domain/driver_dashboard_stats.dart';
import '../domain/trip_request.dart';
import '../domain/trip_status.dart';
import 'trip_state.dart';

bool _walletKeysLogged = false;

bool _looksLikeProximityArrivedRejection(DioException e) {
  // Backend implementations vary; some return a structured `code`, others only a localized message.
  final codeRaw = parseDriverApiErrorCode(e) ?? '';
  final code = codeRaw.toUpperCase();
  if (code.contains('CLOSER') || code.contains('PROXIM') || code.contains('DIST')) return true;
  if (isTelegramLiveLocationBackendError(e)) return true;

  final msgRaw = parseDriverApiErrorMessage(e) ?? '';
  final msg = msgRaw.toLowerCase();
  if (msg.isEmpty) return false;
  // Uzbek/Russian UI strings historically used for the “Yetib keldim” proximity gate.
  return msg.contains('yaqin') || // "yaqin bo‘ling"
      msg.contains('hali yetib bormagansiz') ||
      msg.contains('olib ketish') ||
      msg.contains('pickup') ||
      msg.contains('100') ||
      msg.contains('м') || // Cyrillic meters
      msg.contains('метр') ||
      msg.contains('ближе') ||
      msg.contains('near');
}

String? _formatOfferDistanceKm(double? km) {
  if (km == null || !km.isFinite || km <= 0) return null;
  if (km < 1) return 'Masofa: ${(km * 1000).round()} m';
  return 'Masofa: ${km.toStringAsFixed(1)} km';
}

/// Promo / referral HTTP is heavy; refresh less often than [GET /driver/available-requests].
const Duration _ancillaryMinGap = Duration(seconds: 60);

/// Live metered stats from `GET /trip/:id` while [TripStatus.started] (mini-app LIVE_TRIP_POLL_INTERVAL_MS).
const Duration _liveTripPollInterval = Duration(seconds: 3);

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

  /// Queue preview rows dismissed after the dashboard countdown — do not auto-show again until
  /// the request id disappears from [GET /driver/available-requests] (see [_pruneDismissedQueuePreviews]).
  final Set<String> _dismissedQueuePreviewIds = {};
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
      await _wsSub?.cancel();
      await _ws?.dispose();
    });

    if (AppConfig.hasHttpApi) {
      ref.listen(driverStatusProvider, (prev, next) {
        if (next == DriverStatus.online) {
          _startPollingWithImmediateRun();
        } else {
          _lifecyclePollDebounce?.cancel();
          _pollTimer?.cancel();
          _pollTimer = null;
          _cancelLiveTripPoll();
          _clearDispatchStateWhenGoingOffline();
        }
      });
      ref.listen(driverIdProvider, (prev, next) {
        if (next.isNotEmpty || AppConfig.driverId.isNotEmpty) {
          if (ref.read(driverStatusProvider) == DriverStatus.online) {
            _startPollingWithImmediateRun();
          }
        } else if (AppConfig.driverId.isEmpty) {
          _lifecyclePollDebounce?.cancel();
          _pollTimer?.cancel();
          _pollTimer = null;
          unawaited(_disconnectWs());
          _dismissedQueuePreviewIds.clear();
          _lastNotifiedOfferId = null;
          _lastNotifiedAssignedTripId = null;
          state = const TripState(status: TripStatus.waiting, activeRequest: null);
        }
      });
      ref.listen(appLifecycleProvider, (AppLifecyclePhase? previous, AppLifecyclePhase next) {
        if (previous == next) return;
        if (ref.read(driverStatusProvider) != DriverStatus.online) return;
        _debounceReschedulePollTimerOnly();
      });
      if (ref.read(driverStatusProvider) == DriverStatus.online && _hasDriverAuth()) {
        _startPollingWithImmediateRun();
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
    _mockTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (ref.read(driverStatusProvider) != DriverStatus.online) return;
      if (state.activeRequest != null) return;
      final r = Random();
      const base = MapLatLng(41.311081, 69.240562);
      final pickup = MapLatLng(base.latitude + (r.nextDouble() - 0.5) * 0.02, base.longitude + (r.nextDouble() - 0.5) * 0.02);
      final destination = MapLatLng(base.latitude + (r.nextDouble() - 0.5) * 0.05, base.longitude + (r.nextDouble() - 0.5) * 0.05);
      state = state.copyWith(
        activeRequest: () => TripRequest(id: 'mock_${DateTime.now().millisecondsSinceEpoch}', pickup: pickup, destination: destination),
        status: TripStatus.waiting,
      );
    });
  }

  bool _hasDriverAuth() =>
      AppConfig.driverId.trim().isNotEmpty ||
      ref.read(driverIdProvider).trim().isNotEmpty ||
      AppConfig.telegramInitData.trim().isNotEmpty;

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

  void _armNextDispatchPollTimer() {
    _pollTimer?.cancel();
    if (!_hasDriverAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    final bg = ref.read(appLifecycleProvider) == AppLifecyclePhase.backgrounded;
    final seconds = bg ? 45 : 8;
    _pollTimer = Timer(Duration(seconds: seconds), () {
      scheduleMicrotask(() async {
        await _pollAvailableRequests();
        _armNextDispatchPollTimer();
      });
    });
  }

  Future<void> _pollAvailableRequests() async {
    final repo = _repo;
    if (repo == null) return;
    if (!_hasDriverAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;

    try {
      final raw = await repo.getAvailableRequests();
      var bal = parseDriverBalanceFromDispatchJson(raw);
      final walletPath = AppConfig.driverWalletHttpPath.trim();
      if (walletPath.isNotEmpty) {
        try {
          final w = await repo.getRelativeJson(walletPath);
          bal = mergeDriverBalanceSnapshots(bal, parseDriverBalanceFromDispatchJson(w));
        } catch (_) {}
      }

      final now = DateTime.now();
      final runAncillary = _lastAncillaryPoll == null ||
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
        bal = mergeDriverBalanceSnapshots(bal, parseDriverBalanceFromDispatchJson(promoJson!));
      }
      if (refStatusJson != null) {
        bal = mergeDriverBalanceSnapshots(bal, parseDriverBalanceFromDispatchJson(refStatusJson!));
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
        state = state.copyWith(
          driverBalance: bal != null ? () => bal : null,
        );
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
      final snap = parseAvailableRequests(raw);
      _pruneDismissedQueuePreviews(
        snap.queueItems.map((q) => q.requestId).toSet(),
      );

      if (snap.assignedTripId != null && snap.assignedTripStatus != null) {
        if (_lastNotifiedAssignedTripId != snap.assignedTripId) {
          _lastNotifiedAssignedTripId = snap.assignedTripId;
          unawaited(
            LocalNotifications.notifyNewOrder(
              id: snap.assignedTripId.hashCode & 0x7fffffff,
              title: 'Yangi buyurtma biriktirildi',
              body: 'Ilovani ochib batafsil ko‘ring.',
            ),
          );
        }
        final st = snap.assignedTripStatus!.toUpperCase();
        if (st == 'FINISHED') {
          final req = state.activeRequest;
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
          );
          return;
        }
        try {
          final tripJson = await repo.getTrip(snap.assignedTripId!);
          final req = tripRequestFromTripJson(
            tripJson,
            requestId: tripJson['request_id']?.toString() ?? snap.assignedTripId!,
          );
          final mapped = parseServerTripStatus(st) ?? TripStatus.waiting;
          final prev = state;
          // UX requirement: do not enforce proximity gating for "Yetib keldim".
          // Some backend deployments still reject ARRIVED by distance and keep returning WAITING.
          // Preserve the local ARRIVED state once the driver taps the button, until the server
          // advances the trip (STARTED/FINISHED) or the trip id changes.
          final effectiveStatus =
              (prev.status == TripStatus.arrived && mapped == TripStatus.waiting) ? TripStatus.arrived : mapped;
          state = state.copyWith(
            activeRequest: () => req,
            status: effectiveStatus,
            remoteLiveLocation: () => null,
            hydrationIssue: TripHydrationIssue.none,
            fareCompletionPopup: () => null,
          );
          if (effectiveStatus == TripStatus.started) {
            if (prev.status != TripStatus.started || prev.activeRequest?.tripId != req.tripId) {
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
        return;
      }

      if (state.activeRequest != null && state.activeRequest!.tripId != null) {
        return;
      }

      if (snap.queueItems.isEmpty) return;
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
          );
        }
        return;
      }

      final first = snap.queueItems.first;
      if (_dismissedQueuePreviewIds.contains(first.requestId)) {
        return;
      }

      if (_lastNotifiedOfferId != first.requestId) {
        _lastNotifiedOfferId = first.requestId;
        final dist = _formatOfferDistanceKm(first.distanceKm);
        unawaited(
          LocalNotifications.notifyNewOrder(
            id: first.requestId.hashCode & 0x7fffffff,
            title: 'Yangi buyurtma',
            body: dist == null
                ? 'Qabul qilish uchun ilovani oching.'
                : '$dist\nQabul qilish uchun ilovani oching.',
          ),
        );
      }

      state = state.copyWith(
        activeRequest: () => tripRequestFromQueueItem(first),
        status: TripStatus.waiting,
        remoteLiveLocation: () => null,
        fareCompletionPopup: () => null,
      );
    } catch (e, st) {
      debugPrint('available-requests poll failed: $e\n$st');
    }
  }

  Future<void> _connectWsIfNeeded(String tripId) async {
    final did =
        AppConfig.driverId.trim().isNotEmpty ? AppConfig.driverId.trim() : ref.read(driverIdProvider).trim();
    final url = AppConfig.wsUrlStringForTrip(tripId, driverIdForQuery: did.isNotEmpty ? did : null);
    if (url.isEmpty) return;
    if (_ws != null && _lastWsTripId == tripId) return;

    await _wsSub?.cancel();
    await _ws?.dispose();
    _lastWsTripId = tripId;
    _ws = WebSocketService(url: url);
    await _ws!.connect();
    _wsSub = _ws!.messages.listen(_onWsEvent);
  }

  String? _lastWsTripId;

  Future<void> _disconnectWs() async {
    _cancelLiveTripPoll();
    _lastWsTripId = null;
    _lastRemoteUiPoint = null;
    _lastRemoteUiAt = null;
    await _wsSub?.cancel();
    _wsSub = null;
    await _ws?.dispose();
    _ws = null;
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
      final req = tripRequestFromTripJson(json, requestId: rid).copyWith(tripId: () => tid);
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

    if (type == 'driver_location_update') {
      final payload = m['payload'];
      Map<String, dynamic>? map;
      if (payload is Map) {
        map = Map<String, dynamic>.from(payload.map((k, v) => MapEntry(k.toString(), v)));
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
          if (dt < const Duration(seconds: 2) && dLat < 0.00012 && dLng < 0.00012) {
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
        _lastRemoteUiPoint = null;
        _lastRemoteUiAt = null;
        final cancelled = type == 'trip_cancelled';
        final req = state.activeRequest;
        final fareMap = _wsPayloadFareMap(m);
        var fare = req?.fareSom;
        var dist = req?.distanceKm;
        if (fareMap != null) {
          fare ??= extractFareSomFromMap(fareMap);
          dist ??= extractDistanceKmFromMap(fareMap);
        }
        final odo = state.clientOdometerKm;
        if ((dist == null || dist <= 0) && odo > 0) {
          dist = odo;
        }
        state = state.copyWith(
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
        final nextOdo = ts == TripStatus.started
            ? (prev.status == TripStatus.started ? prev.clientOdometerKm : 0.0)
            : 0.0;
        state = state.copyWith(
          status: ts,
          clientOdometerKm: nextOdo,
        );
        if (ts == TripStatus.started) {
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
    _dismissedQueuePreviewIds.removeWhere((id) => !currentRequestIds.contains(id));
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
    );
  }

  /// Accept current queue offer — `POST /driver/accept-request` with `request_id`.
  Future<void> acceptOffer() async {
    final req = state.activeRequest;
    if (req == null) return;
    await acceptOfferByRequestId(req.id);
  }

  /// Accept a row from the queue (e.g. Available Requests screen) by `request_id`.
  Future<void> acceptOfferByRequestId(String requestId) async {
    final id = requestId.trim();
    if (id.isEmpty) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    _dismissedQueuePreviewIds.remove(id);

    final repo = _repo;
    if (repo != null) {
      try {
        final res = await repo.acceptRequest(requestId: id);
        String? tripId = res['trip_id']?.toString();
        if (tripId == null || tripId.isEmpty) {
          final tr = res['trip'];
          if (tr is Map) {
            tripId = tr['id']?.toString();
          }
        }

        if (res['already_assigned'] == true && tripId != null) {
          final tripJson = await repo.getTrip(tripId);
          final merged = tripRequestFromTripJson(tripJson, requestId: id).copyWith(tripId: () => tripId);
          state = state.copyWith(
            activeRequest: () => merged,
            status: TripStatus.waiting,
            remoteLiveLocation: () => null,
            hydrationIssue: TripHydrationIssue.none,
            fareCompletionPopup: () => null,
          );
          await _connectWsIfNeeded(tripId);
          return;
        }

        if (res['assigned'] == true && tripId != null) {
          final tripJson = await repo.getTrip(tripId);
          final merged = tripRequestFromTripJson(tripJson, requestId: id).copyWith(tripId: () => tripId);
          state = state.copyWith(
            activeRequest: () => merged,
            status: TripStatus.waiting,
            remoteLiveLocation: () => null,
            hydrationIssue: TripHydrationIssue.none,
            fareCompletionPopup: () => null,
          );
          await _connectWsIfNeeded(tripId);
          return;
        }

        if (tripId != null) {
          final tripJson = await repo.getTrip(tripId);
          final merged = tripRequestFromTripJson(tripJson, requestId: id).copyWith(tripId: () => tripId);
          state = state.copyWith(
            activeRequest: () => merged,
            status: TripStatus.waiting,
            remoteLiveLocation: () => null,
            hydrationIssue: TripHydrationIssue.none,
            fareCompletionPopup: () => null,
          );
          await _connectWsIfNeeded(tripId);
        }
      } on DioException catch (e) {
        throw _acceptException(e);
      }
      return;
    }

    state = state.copyWith(status: TripStatus.waiting, fareCompletionPopup: () => null);
  }

  DriverUserException _acceptException(DioException e) {
    final code = parseDriverApiErrorCode(e);
    final msg = parseDriverApiErrorMessage(e);
    final status = e.response?.statusCode;
    if (status == 409 || code == 'REQUEST_UNAVAILABLE' || code == 'REQUEST_TAKEN') {
      return DriverUserException(msg ?? 'Bu buyurtma endi mavjud emas yoki boshqa haydovchiga berilgan.');
    }
    if (status == 403) {
      return DriverUserException(msg ?? 'Buyurtmani qabul qilishga ruxsat yo‘q.');
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
        msg ?? 'Lokatsiya yangilanmadi. GPS yoqilganini tekshiring va biroz kuting.',
        userCode: 'DRIVER_LOCATION_STALE',
      );
    }
    if (code == 'LIVE_LOCATION_INACTIVE') {
      return DriverUserException(
        msg ?? 'Lokatsiya faol emas. Ilovaga lokatsiya ruxsatini bering va ONLINE bo‘ling.',
        userCode: 'LIVE_LOCATION_INACTIVE',
      );
    }
    // Go sometimes returns the full localized sentence in `code` (e.g. trip pickup/start guards).
    if (isTelegramLiveLocationBackendError(e)) {
      return DriverUserException(msg ?? fallback, userCode: 'LIVE_LOCATION_INACTIVE');
    }
    return DriverUserException(msg ?? fallback);
  }

  /// @deprecated Use [acceptOffer].
  void acceptRequest() {
    scheduleMicrotask(() => acceptOffer());
  }

  /// [lat]/[lng]/[accuracy]/[fixTime]: native HTTP-live parity — same fix as [flushHttpNowAt] + optional WS ping.
  Future<void> toArrived({
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? fixTime,
  }) async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) return;
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
      } on DioException catch (e) {
        // UX requirement: do not block "Yetib keldim" based on distance/proximity.
        // If the backend enforces a proximity check, treat that specific rejection as non-fatal
        // and proceed to ARRIVED locally.
        if (kDebugMode) {
          final code = parseDriverApiErrorCode(e);
          debugPrint('[yetti_driver] POST /trip/arrived failed: HTTP ${e.response?.statusCode ?? '—'} code=${code ?? '—'}');
        }
        if (!_looksLikeProximityArrivedRejection(e)) {
          throw _tripActionException(e, 'Yetib kelishni qayd etib bo‘lmadi.');
        }
      }
    }
    state = state.copyWith(status: TripStatus.arrived, clientOdometerKm: 0);
  }

  Future<void> startTrip({
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? fixTime,
  }) async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) return;
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
      } on DioException catch (e) {
        if (kDebugMode) {
          final code = parseDriverApiErrorCode(e);
          debugPrint('[yetti_driver] POST /trip/start failed: HTTP ${e.response?.statusCode ?? '—'} code=${code ?? '—'}');
        }
        // Same soft rejections as [toArrived] (proximity / Telegram-live wording) — advance locally for UX parity with web.
        if (!_looksLikeProximityArrivedRejection(e)) {
          throw _tripActionException(e, 'Safarni boshlab bo‘lmadi.');
        }
      }
    }
    state = state.copyWith(status: TripStatus.started, clientOdometerKm: 0);
    _syncLiveTripPoll();
  }

  /// `POST /trip/finish` — end trip from driver; then disconnect WS (same local cleanup as cancel).
  Future<void> finishTrip() async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) return;
    final req = state.activeRequest;
    final odoKm = state.clientOdometerKm;
    double? mergeKm(double? api) {
      if (api != null && api > 0) return api;
      return odoKm > 0 ? odoKm : null;
    }

    final repo = _repo;
    TripFareCompletionPopup popup = TripFareCompletionPopup(
      fareSom: req?.fareSom,
      distanceKm: mergeKm(req?.distanceKm),
    );
    if (repo != null) {
      try {
        await repo.postTripFinish(tid);
        try {
          final json = await repo.getTrip(tid);
          final parsed = tripRequestFromTripJson(json, requestId: req?.id ?? '');
          popup = TripFareCompletionPopup(
            fareSom: parsed.fareSom,
            distanceKm: mergeKm(parsed.distanceKm),
          );
        } catch (_) {}
      } on DioException catch (e) {
        throw _tripActionException(e, 'Safarni tugatib bo‘lmadi.');
      }
    }
    state = state.copyWith(
      status: TripStatus.finished,
      activeRequest: () => null,
      remoteLiveLocation: () => null,
      fareCompletionPopup: () => popup,
      clientOdometerKm: 0,
    );
    await _disconnectWs();
  }

  /// `POST /trip/cancel/driver` — driver cancel; then disconnect WS.
  Future<void> cancelTripAsDriver() async {
    final tid = state.activeRequest?.tripId;
    if (tid == null) return;
    final repo = _repo;
    if (repo != null) {
      try {
        await repo.postTripCancelDriver(tid);
      } on DioException catch (e) {
        throw _tripActionException(e, 'Safarni bekor qilib bo‘lmadi.');
      }
    }
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
    if (AppConfig.debugLocation) {
      // ignore: avoid_print
      print('[yetti_driver] Sending WS location -> lat: $lat, lng: $lng');
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

final tripProvider = NotifierProvider<TripController, TripState>(TripController.new);
