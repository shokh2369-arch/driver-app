import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/auth_repository.dart';
import '../data/repositories/driver_repository.dart';
import '../features/driver/presentation/driver_id_controller.dart';
import '../features/driver/presentation/driver_session_controller.dart';
import '../features/legal/presentation/legal_acceptance_gate.dart';
import 'auth_api_client.dart';
import 'config.dart';
import 'driver_api_client.dart';
import 'driver_session_revocation.dart';
import 'location_service.dart';

final locationServiceProvider = Provider<LocationService>((ref) => LocationService());

/// SMS / phone auth — no driver headers (`POST /auth/*`).
final authApiProvider = Provider<AuthApiClient>((ref) => AuthApiClient());

final authRepositoryProvider = Provider<AuthRepository?>((ref) {
  if (!AppConfig.hasHttpApi) return null;
  return AuthRepository(ref.watch(authApiProvider));
});

/// Live when [AppConfig.hasHttpApi] — use [DriverApiClient] for dispatch + trip HTTP.
/// Recreates when [driverIdProvider] / [driverSessionProvider] change so auth headers stay in sync.
final driverApiProvider = Provider<DriverApiClient?>((ref) {
  if (!AppConfig.hasHttpApi) return null;
  ref.watch(driverIdProvider);
  ref.watch(driverSessionProvider);
  return DriverApiClient(
    resolveDriverId: () => ref.read(driverIdProvider),
    resolveSessionToken: () => ref.read(driverSessionProvider),
    onForbidden: (_) {
      ref.read(legalAcceptanceGateProvider.notifier).requireAcceptance();
    },
    onSessionRevoked: () {
      unawaited(handleDriverSessionRevoked(ref));
    },
  );
});

final driverRepositoryProvider = Provider<DriverRepository?>((ref) {
  final api = ref.watch(driverApiProvider);
  if (api == null) return null;
  return DriverRepository(api);
});

