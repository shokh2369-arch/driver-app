import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_providers.dart';

/// Opaque session from [POST /auth/verify-code], sent as `X-Driver-Session` on driver API calls.
class DriverSessionController extends Notifier<String> {
  @override
  String build() => ref.read(appPrefsProvider).driverSessionToken ?? '';

  Future<void> setSessionToken(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await clear();
      return;
    }
    await ref.read(appPrefsProvider).setDriverSessionToken(v);
    state = v;
  }

  Future<void> clear() async {
    await ref.read(appPrefsProvider).clearDriverSessionToken();
    state = '';
  }
}

final driverSessionProvider = NotifierProvider<DriverSessionController, String>(DriverSessionController.new);
