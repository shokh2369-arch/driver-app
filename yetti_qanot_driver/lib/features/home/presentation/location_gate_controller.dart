import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../services/service_providers.dart';

sealed class LocationGateState {
  const LocationGateState();
}

class LocationGateChecking extends LocationGateState {
  const LocationGateChecking();
}

class LocationGateDenied extends LocationGateState {
  const LocationGateDenied({required this.serviceEnabled});
  final bool serviceEnabled;
}

class LocationGateReady extends LocationGateState {
  const LocationGateReady();
}

class LocationGateController extends Notifier<LocationGateState> {
  @override
  LocationGateState build() {
    _check();
    return const LocationGateChecking();
  }

  Future<void> _check() async {
    final loc = ref.read(locationServiceProvider);
    final serviceEnabled = await loc.ensureServiceEnabled();
    if (!serviceEnabled) {
      state = const LocationGateDenied(serviceEnabled: false);
      return;
    }

    final perm = await loc.checkPermission();
    if (perm == LocationPermission.always || perm == LocationPermission.whileInUse) {
      state = const LocationGateReady();
      return;
    }
    state = const LocationGateDenied(serviceEnabled: true);
  }

  Future<void> request() async {
    final loc = ref.read(locationServiceProvider);
    final perm = await loc.requestPermission();
    if (perm == LocationPermission.always || perm == LocationPermission.whileInUse) {
      state = const LocationGateReady();
    } else {
      final serviceEnabled = await loc.ensureServiceEnabled();
      state = LocationGateDenied(serviceEnabled: serviceEnabled);
    }
  }
}

final locationGateProvider = NotifierProvider<LocationGateController, LocationGateState>(
  LocationGateController.new,
);

