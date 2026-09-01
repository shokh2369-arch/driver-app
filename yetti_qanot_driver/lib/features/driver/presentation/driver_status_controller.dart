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
    ref.read(tripProvider.notifier).refreshDispatchNow();
  }

  /// `POST /driver/online` with bounded backoff retry. Gives up quietly on a definitive
  /// server rejection (already handled elsewhere) and hands a revoked session to the
  /// revocation flow. Stops early if the driver toggled back offline mid-retry.
  Future<void> _ensureServerOnline() async {
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return;
    const maxAttempts = 4;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (state != DriverStatus.online) return; // driver went offline again
      try {
        await repo.postDriverOnline();
        return; // success — dispatch will resume
      } on DioException catch (e) {
        if (isSessionRevokedError(e)) {
          unawaited(handleDriverSessionRevoked(ref));
          return;
        }
        // A real server response other than a transient failure: stop retrying (e.g. a
        // legal gate, which the API interceptor already surfaces).
        if (e.response != null && !_isTransportFailure(e)) {
          debugPrint(
            '[yetti_driver] POST /driver/online rejected: HTTP ${e.response?.statusCode}',
          );
          return;
        }
        if (kDebugMode) {
          debugPrint(
            '[yetti_driver] POST /driver/online transient failure '
            '(${e.type}); attempt ${attempt + 1}/$maxAttempts',
          );
        }
      } catch (e) {
        debugPrint('[yetti_driver] POST /driver/online error: $e');
      }
      // Backoff before the next attempt (2s, 4s, 6s).
      await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
    }
    debugPrint(
      '[yetti_driver] POST /driver/online did not confirm after $maxAttempts tries; '
      'driver is online locally, will retry on next toggle/location cycle',
    );
  }
}

final driverStatusProvider = NotifierProvider<DriverStatusController, DriverStatus>(
  DriverStatusController.new,
);
