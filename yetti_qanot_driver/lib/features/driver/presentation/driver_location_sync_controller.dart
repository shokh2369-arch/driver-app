import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../services/api_error_parser.dart';
import '../../../services/app_lifecycle_provider.dart';
import '../../../services/config.dart';
import '../../../services/service_providers.dart';
import '../../trip/presentation/trip_controller.dart';
import '../domain/driver_status.dart';
import 'driver_id_controller.dart';
import 'driver_status_controller.dart';

/// While ONLINE with HTTP API + driver auth: steady `POST /driver/location/app` (native app) plus extra posts on
/// meaningful movement. Matches backend `DRIVER_HTTP_API_HANDOFF.md` / `DRIVER_CLIENT.md` / `AUTH.md` (Unix `timestamp`,
/// no ISO). Timer cadence stays **under the server ~90s** live guard, tighter during assigned trips.
///
/// [AppConfig.driverHttpLiveLocationEnabled] should match server `ENABLE_DRIVER_HTTP_LIVE_LOCATION`.
///
/// WebSocket `driver_location` frames are sent from [ingestPosition] only during an active trip.
class DriverLocationSyncController extends Notifier<int> {
  Timer? _httpTimer;
  Timer? _lifecycleDebounce;
  Position? _last;

  /// Last position successfully sent over HTTP (for movement threshold).
  Position? _lastHttpPosted;

  DateTime? _lastHttpPostWallClock;

  static const _movementMeters = 40.0;

  Duration _minIntervalBetweenPosts() {
    final tripHeavy = ref.read(tripProvider).requiresContinuousLiveLocation;
    return Duration(seconds: tripHeavy ? 8 : 12);
  }

  Duration _foregroundTick() {
    final tripHeavy = ref.read(tripProvider).requiresContinuousLiveLocation;
    return Duration(seconds: tripHeavy ? 16 : 22);
  }

  Duration _backgroundTick() {
    final tripHeavy = ref.read(tripProvider).requiresContinuousLiveLocation;
    return Duration(seconds: tripHeavy ? 40 : 50);
  }

  @override
  int build() {
    ref.onDispose(() {
      _httpTimer?.cancel();
      _lifecycleDebounce?.cancel();
    });

    ref.listen(driverStatusProvider, (DriverStatus? previous, DriverStatus next) {
      _reschedule(immediatePost: true);
    });
    ref.listen(driverIdProvider, (String? previous, String next) {
      _reschedule(immediatePost: true);
    });
    ref.listen<String>(
      tripProvider.select(
        (s) =>
            '${s.requiresContinuousLiveLocation}|${s.status.name}|${s.activeRequest?.tripId ?? ''}',
      ),
      (String? previous, String next) {
        if (previous != next) _reschedule(immediatePost: false);
      },
    );
    ref.listen(appLifecycleProvider, (AppLifecyclePhase? previous, AppLifecyclePhase next) {
      if (previous == next) return;
      _debouncedLifecycleReschedule();
    });
    _reschedule(immediatePost: true);
    return 0;
  }

  void _debouncedLifecycleReschedule() {
    _lifecycleDebounce?.cancel();
    _lifecycleDebounce = Timer(const Duration(milliseconds: 450), () {
      _reschedule(immediatePost: false);
    });
  }

  bool _hasAuth() =>
      AppConfig.driverId.trim().isNotEmpty ||
      ref.read(driverIdProvider).trim().isNotEmpty ||
      AppConfig.telegramInitData.trim().isNotEmpty;

  void _reschedule({required bool immediatePost}) {
    _httpTimer?.cancel();
    _httpTimer = null;
    if (!AppConfig.hasHttpApi || !_hasAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;

    void scheduleNext() {
      _httpTimer?.cancel();
      final bg = ref.read(appLifecycleProvider) == AppLifecyclePhase.backgrounded;
      final interval = bg ? _backgroundTick() : _foregroundTick();
      _httpTimer = Timer(interval, () {
        unawaited(_postHttp(ignoreMinInterval: false, throwOnFail: false));
        scheduleNext();
      });
    }

    if (immediatePost) {
      unawaited(_postHttp(ignoreMinInterval: false, throwOnFail: false));
    }
    scheduleNext();
  }

  Future<void> _postHttp({
    required bool ignoreMinInterval,
    required bool throwOnFail,
    bool useWebLocationPath = false,
  }) async {
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    final p = _last;
    if (p == null) return;

    final now = DateTime.now();
    if (!AppConfig.debugLocation &&
        !ignoreMinInterval &&
        _lastHttpPostWallClock != null &&
        now.difference(_lastHttpPostWallClock!) < _minIntervalBetweenPosts()) {
      return;
    }

    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return;
    try {
      // Required debug log (no secrets): verify coordinate order + accuracy + timestamp.
      // Matches backend expectation: WGS84 lat/lng.
      if (AppConfig.debugLocation) {
        // ignore: avoid_print
        print(
          'APP LOCATION -> lat: ${p.latitude}, lng: ${p.longitude}, acc: ${p.accuracy}',
        );
      }
      await repo.postDriverLocation(
        lat: p.latitude,
        lng: p.longitude,
        accuracy: p.accuracy,
        timestamp: p.timestamp,
        useWebLocationPath: useWebLocationPath,
      );
      _lastHttpPostWallClock = DateTime.now();
      _lastHttpPosted = p;
    } on DioException catch (e) {
      if (!AppConfig.driverHttpLiveLocationEnabled && isTelegramLiveLocationBackendError(e)) {
        if (kDebugMode) {
          debugPrint('[yetti_driver] location post ignored (Telegram-only server mode)');
        }
        return;
      }
      if (throwOnFail) rethrow;
    } catch (_) {
      if (throwOnFail) rethrow;
    }
  }

  /// Force an immediate location POST with the latest GPS fix.
  ///
  /// Uses **`POST /driver/location`** on native (same as Flutter web before trip actions) so server live guards
  /// match Chrome; periodic timer still uses `/driver/location/app`.
  Future<void> flushHttpNow() async {
    if (!AppConfig.hasHttpApi || !_hasAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    await _postHttp(ignoreMinInterval: true, throwOnFail: true, useWebLocationPath: true);
  }

  /// Same as [flushHttpNow] but sends [lat]/[lng] from the map/UI (Android may lag syncing [ingestPosition] → [_last]).
  ///
  /// [fixTimestamp]: GPS fix time when known (matches `docs/DRIVER_APP.md`); otherwise uses clock time.
  Future<void> flushHttpNowAt(
    double lat,
    double lng, {
    double? accuracy,
    DateTime? fixTimestamp,
  }) async {
    if (!AppConfig.hasHttpApi || !_hasAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return;
    final ts = fixTimestamp ?? DateTime.now();
    final acc = accuracy;
    try {
      await repo.postDriverLocation(
        lat: lat,
        lng: lng,
        accuracy: acc,
        timestamp: ts,
        useWebLocationPath: true,
      );
    } on DioException catch (e) {
      if (!AppConfig.driverHttpLiveLocationEnabled && isTelegramLiveLocationBackendError(e)) {
        if (kDebugMode) {
          debugPrint('[yetti_driver] flushHttpNowAt ignored (Telegram-only server mode)');
        }
      } else {
        rethrow;
      }
    }
    _lastHttpPostWallClock = DateTime.now();
    final p = Position(
      latitude: lat,
      longitude: lng,
      timestamp: ts,
      accuracy: acc ?? 0,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    _lastHttpPosted = p;
    _last = p;
  }

  void ingestPosition(Position p) {
    final hadPosition = _last != null;
    _last = p;
    if (AppConfig.debugLocation) {
      // ignore: avoid_print
      print(
        '[yetti_driver] GPS fix -> lat: ${p.latitude}, lng: ${p.longitude}, '
        'acc_m: ${p.accuracy}, ts: ${p.timestamp?.toIso8601String() ?? '—'}',
      );
    }

    if (ref.read(driverStatusProvider) == DriverStatus.online &&
        AppConfig.hasHttpApi &&
        _hasAuth() &&
        !hadPosition) {
      unawaited(_postHttp(ignoreMinInterval: false, throwOnFail: false));
    }

    if (ref.read(tripProvider).hasActiveTrip) {
      if (AppConfig.debugLocation) {
        // ignore: avoid_print
        print('[yetti_driver] WS driver_location -> lat: ${p.latitude}, lng: ${p.longitude}');
      }
      ref.read(tripProvider.notifier).sendDriverLocationWs(
            lat: p.latitude,
            lng: p.longitude,
          );
    }

    _maybePostOnMovement(p);
  }

  void _maybePostOnMovement(Position p) {
    if (!AppConfig.hasHttpApi || !_hasAuth()) return;
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;

    if (AppConfig.debugLocation) {
      unawaited(_postHttp(ignoreMinInterval: false, throwOnFail: false));
      return;
    }

    final prev = _lastHttpPosted;
    if (prev == null) return;

    final d = Geolocator.distanceBetween(
      prev.latitude,
      prev.longitude,
      p.latitude,
      p.longitude,
    );
    if (d < _movementMeters) return;

    unawaited(_postHttp(ignoreMinInterval: false, throwOnFail: false));
  }
}

final driverLocationSyncProvider = NotifierProvider<DriverLocationSyncController, int>(
  DriverLocationSyncController.new,
);
