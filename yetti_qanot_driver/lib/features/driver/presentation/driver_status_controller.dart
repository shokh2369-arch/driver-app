import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_providers.dart';
import '../../../services/api_error_parser.dart';
import '../../../services/config.dart';
import '../../../services/driver_session_revocation.dart';
import '../../../services/service_providers.dart';
import '../../trip/presentation/trip_controller.dart';
import '../domain/driver_status.dart';
import 'driver_id_controller.dart';
import 'driver_location_sync_controller.dart';

/// Incremented when going OFFLINE could not be confirmed with the server (no network).
/// The UI shows a notice so the driver knows the state is local-only.
final offlineSyncFailedSignalProvider = StateProvider<int>((ref) => 0);

class DriverStatusController extends Notifier<DriverStatus> {
  /// True once the server acknowledged `POST /driver/online` for the current ONLINE
  /// stint. While false (and the stint is owed, see [_onlineNeedsServer]),
  /// [reassertServerOnlineIfNeeded] retries on the location cadence: the toggle flips
  /// the UI immediately, and on a flaky link the initial bounded retry can give up
  /// while the server still has `manual_offline = 1` — the driver then looks online
  /// but never receives orders.
  bool _serverOnlineConfirmed = false;

  /// Only stints started by an explicit toggle / login in this process re-send
  /// `POST /driver/online`. A cold start that merely restores ONLINE from prefs
  /// must not override a `manual_offline` a dispatcher set while the app was closed.
  bool _onlineNeedsServer = false;

  /// The server definitively rejected `POST /driver/online` for this stint (legal
  /// gate, not approved, …): stop re-sending until the next toggle.
  bool _onlineRejected = false;

  /// Increments on every [setStatus]; an in-flight online POST whose stint is no
  /// longer current must not confirm (or re-enable) anything.
  int _onlineStint = 0;

  /// The single in-flight `POST /driver/online`, shared by the bounded retry and the
  /// location-tick re-assert so a toggle never issues two concurrent posts.
  Future<bool>? _onlinePost;

  /// Network-level failure (no response from the server) vs. a real rejection.
  static bool _isTransportFailure(DioException e) {
    if (e.response != null) return false;
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.unknown;
  }

  @override
  DriverStatus build() {
    // [AppPrefs] does not notify Riverpod when SharedPreferences change — use [read], not [watch].
    // Default **offline** until the driver explicitly goes online (or login sets online).
    final stored = ref.read(appPrefsProvider).driverOnline;
    return (stored ?? false) ? DriverStatus.online : DriverStatus.offline;
  }

  bool _hasDriverAuth() =>
      AppConfig.driverId.trim().isNotEmpty ||
      ref.read(driverIdProvider).trim().isNotEmpty ||
      AppConfig.telegramInitData.trim().isNotEmpty;

  /// Going **ONLINE** flips the UI immediately, then calls `POST /driver/online` in the
  /// background **with retry**. Location pings no longer clear the server's `manual_offline`
  /// flag, so that call is required to actually receive orders — but it must NOT hard-block
  /// the toggle: this backend is flaky (cold starts, transient "Failed to fetch"), and a
  /// single failed attempt used to leave the driver unable to go online at all. Optimistic
  /// flip + backoff retry ([_ensureServerOnline]) lands the call as soon as the network
  /// recovers, and matches how location sync already behaves. A revoked session is handled
  /// (logs out); a legal gate is handled by the API interceptor.
  ///
  /// Going **OFFLINE** with HTTP + auth: `POST /driver/offline` clears the server's
  /// `live_location_active` / `is_active` flags, so it is attempted first.
  ///
  /// A **rejected** offline call (auth, legal gate, 4xx/5xx) still blocks the transition —
  /// the server explicitly refused. A **transport** failure (no signal, timeout, DNS) does
  /// not: a driver in a dead zone must still be able to go offline, otherwise they keep
  /// receiving orders they cannot see. Location posts stop immediately, so the backend's
  /// ~90s freshness guard drops them from dispatch shortly after anyway.
  /// [offlineSyncFailedSignalProvider] lets the UI tell the driver what happened.
  ///
  /// [skipServerSync]: do not call the API (e.g. session already invalidated — login on another device).
  Future<void> setStatus(DriverStatus status, {bool skipServerSync = false}) async {
    final wasOnline = state == DriverStatus.online;
    final goingOffline = status == DriverStatus.offline && wasOnline;
    final serverSync = AppConfig.hasHttpApi && _hasDriverAuth() && !skipServerSync;

    if (goingOffline && serverSync) {
      final repo = ref.read(driverRepositoryProvider);
      if (repo != null) {
        try {
          await repo.postDriverOffline();
        } on DioException catch (e) {
          if (!_isTransportFailure(e)) rethrow;
          debugPrint(
            '[yetti_driver] POST /driver/offline unreachable (${e.type}); '
            'going offline locally',
          );
          ref.read(offlineSyncFailedSignalProvider.notifier).state++;
        }
      }
    }

    _onlineStint++;
    _serverOnlineConfirmed = false;
    _onlineRejected = false;
    _onlineNeedsServer = status == DriverStatus.online && serverSync;
    state = status;
    await ref.read(appPrefsProvider).setDriverOnline(status == DriverStatus.online);

    if (status == DriverStatus.online &&
        AppConfig.hasHttpApi &&
        _hasDriverAuth()) {
      unawaited(_registerOnlineWithServer());
    }
  }

  /// Clear the server's `manual_offline` (so dispatch resumes), flush a location fix, and
  /// refetch offers. Fire-and-forget from [setStatus] — the driver is already online locally.
  Future<void> _registerOnlineWithServer() async {
    await _ensureServerOnline();
    try {
      await ref.read(driverLocationSyncProvider.notifier).flushHttpNow();
    } catch (_) {
      // GPS may be unavailable; periodic sync will retry.
    }
    if (!_serverOnlineConfirmed) {
      // Not confirmed (yet): still poll, offers may already be queued for us.
      ref.read(tripProvider.notifier).refreshDispatchNow();
    }
  }

  /// Re-send `POST /driver/online` when the UI is ONLINE for a stint this process
  /// started, the server has not confirmed it, and it has not definitively rejected
  /// it. Cheap no-op otherwise. Called from the periodic location sync, so a link
  /// that comes back after the bounded retries gave up still lands the call within
  /// one location tick.
  Future<void> reassertServerOnlineIfNeeded() async {
    if (!_onlineNeedsServer || _serverOnlineConfirmed || _onlineRejected) return;
    if (_onlinePost != null) return;
    if (state != DriverStatus.online) return;
    if (!AppConfig.hasHttpApi || !_hasDriverAuth()) return;
    await _postOnlineOnce();
  }

  /// One `POST /driver/online`, de-duplicated: concurrent callers share the in-flight
  /// future. Returns true when the server confirmed the *current* stint.
  Future<bool> _postOnlineOnce() {
    final inFlight = _onlinePost;
    if (inFlight != null) return inFlight;
    final f = _postOnline();
    _onlinePost = f;
    f.whenComplete(() {
      if (identical(_onlinePost, f)) _onlinePost = null;
    });
    return f;
  }

  Future<bool> _postOnline() async {
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return false;
    final stint = _onlineStint;
    try {
      await repo.postDriverOnline();
    } on DioException catch (e) {
      if (isSessionRevokedError(e)) {
        unawaited(handleDriverSessionRevoked(ref));
        return false;
      }
      // A real server response other than a transient failure: stop retrying (e.g. a
      // legal gate, which the API interceptor already surfaces).
      if (e.response != null && !_isTransportFailure(e)) {
        if (stint == _onlineStint) _onlineRejected = true;
        debugPrint(
          '[yetti_driver] POST /driver/online rejected: HTTP ${e.response?.statusCode}',
        );
        return false;
      }
      if (kDebugMode) {
        debugPrint('[yetti_driver] POST /driver/online transient failure (${e.type})');
      }
      return false;
    } catch (e) {
      debugPrint('[yetti_driver] POST /driver/online error: $e');
      return false;
    }
    if (stint != _onlineStint || state != DriverStatus.online) {
      // Landed after a later toggle. If the driver is OFFLINE now, the server was just
      // re-enabled behind their back — put it back.
      if (state == DriverStatus.offline) {
        debugPrint('[yetti_driver] stale POST /driver/online landed while OFFLINE; re-sending offline');
        unawaited(repo.postDriverOffline().catchError((Object _) {}));
      }
      return false;
    }
    _serverOnlineConfirmed = true;
    debugPrint('[yetti_driver] POST /driver/online confirmed; dispatch resumes');
    ref.read(tripProvider.notifier).refreshDispatchNow();
    return true;
  }

  /// `POST /driver/online` with bounded backoff retry. Gives up quietly on a definitive
  /// server rejection and hands a revoked session to the revocation flow. Stops early
  /// if the driver toggled again mid-retry or the location-tick path already landed it.
  Future<void> _ensureServerOnline() async {
    final stint = _onlineStint;
    const maxAttempts = 4;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (stint != _onlineStint || state != DriverStatus.online) return;
      if (_serverOnlineConfirmed || _onlineRejected) return;
      if (await _postOnlineOnce()) return;
      if (_onlineRejected) return;
      // Backoff before the next attempt (2s, 4s, 6s).
      await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
    }
    if (stint == _onlineStint && !_serverOnlineConfirmed) {
      debugPrint(
        '[yetti_driver] POST /driver/online did not confirm after $maxAttempts tries; '
        'driver is online locally, will retry on the next location tick',
      );
    }
  }
}

final driverStatusProvider = NotifierProvider<DriverStatusController, DriverStatus>(
  DriverStatusController.new,
);
