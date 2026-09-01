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
///
/// Built **once**: the interceptor resolves `X-Driver-Id` / `X-Driver-Session` per request
/// via [ref.read], so an id or session change is picked up without rebuilding the client.
/// Watching those providers here would discard the Dio connection pool on every login /
/// session refresh and leak the old one.
final driverApiProvider = Provider<DriverApiClient?>((ref) {
  if (!AppConfig.hasHttpApi) return null;
  final client = DriverApiClient(
    resolveDriverId: () => ref.read(driverIdProvider),
    resolveSessionToken: () => ref.read(driverSessionProvider),
    onForbidden: (_) {
      ref.read(legalAcceptanceGateProvider.notifier).requireAcceptance();
    },
    onSessionRevoked: () {
      unawaited(handleDriverSessionRevoked(ref));
    },
  );
  ref.onDispose(client.close);
  return client;
});

final driverRepositoryProvider = Provider<DriverRepository?>((ref) {
  final api = ref.watch(driverApiProvider);
  if (api == null) return null;
  return DriverRepository(api);
});

