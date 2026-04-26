import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_providers.dart';
import '../../../services/config.dart';
import '../../../services/service_providers.dart';
import '../domain/driver_status.dart';
import 'driver_id_controller.dart';

class DriverStatusController extends Notifier<DriverStatus> {
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

  /// Going **ONLINE**: local state only (location + poll resume elsewhere).
  ///
  /// Going **OFFLINE** with HTTP + auth: **`POST /driver/offline` must succeed** before flipping
  /// state so the server clears `live_location_active` / `is_active`; on failure, throws and state stays **ONLINE**.
  ///
  /// [skipServerSync]: do not call the API (e.g. session already invalidated — login on another device).
  Future<void> setStatus(DriverStatus status, {bool skipServerSync = false}) async {
    final wasOnline = state == DriverStatus.online;
    final goingOffline = status == DriverStatus.offline && wasOnline;

    if (goingOffline && AppConfig.hasHttpApi && _hasDriverAuth() && !skipServerSync) {
      final repo = ref.read(driverRepositoryProvider);
      if (repo != null) {
        await repo.postDriverOffline();
      }
    }

    state = status;
    await ref.read(appPrefsProvider).setDriverOnline(status == DriverStatus.online);
  }
}

final driverStatusProvider = NotifierProvider<DriverStatusController, DriverStatus>(
  DriverStatusController.new,
);
