import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/driver/domain/driver_status.dart';
import '../features/driver/presentation/driver_id_controller.dart';
import '../features/driver/presentation/driver_session_controller.dart';
import '../features/driver/presentation/driver_status_controller.dart';

/// Incremented when the server invalidates this device’s session (login elsewhere, revoked token).
final sessionRevokedMessageSignalProvider = StateProvider<int>((ref) => 0);

/// Clears local auth and offline state without calling [POST /driver/offline] (session is already dead).
Future<void> handleDriverSessionRevoked(Ref ref) async {
  if (ref.read(driverIdProvider).trim().isEmpty && ref.read(driverSessionProvider).trim().isEmpty) {
    return;
  }
  await ref.read(driverStatusProvider.notifier).setStatus(DriverStatus.offline, skipServerSync: true);
  await ref.read(driverIdProvider.notifier).clearDriverId();
  ref.read(sessionRevokedMessageSignalProvider.notifier).state++;
}
