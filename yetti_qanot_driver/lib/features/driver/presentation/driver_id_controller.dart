import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_providers.dart';
import 'driver_session_controller.dart';

/// Saved driver id for `X-Driver-Id` — internal `users.id` or Telegram id (backend `AUTH.md`, `DRIVER_HTTP_API_HANDOFF.md`).
class DriverIdController extends Notifier<String> {
  @override
  String build() {
    return ref.read(appPrefsProvider).driverId ?? '';
  }

  Future<void> setDriverId(String value) async {
    final v = value.trim();
    await ref.read(appPrefsProvider).setDriverId(v);
    state = v;
  }

  Future<void> clearDriverId() async {
    final prefs = ref.read(appPrefsProvider);
    await prefs.clearDriverId();
    await prefs.clearDriverSessionToken();
    state = '';
    ref.invalidate(driverSessionProvider);
  }
}

final driverIdProvider = NotifierProvider<DriverIdController, String>(DriverIdController.new);
