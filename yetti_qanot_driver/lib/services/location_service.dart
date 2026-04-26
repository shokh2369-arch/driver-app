import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'config.dart';

class LocationService {
  Future<bool> ensureServiceEnabled() async {
    return Geolocator.isLocationServiceEnabled();
  }

  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  Future<LocationPermission> requestPermission() => Geolocator.requestPermission();

  Stream<Position> positionStream() {
    final settings = LocationSettings(
      // Keep existing default behavior; only go "bestForNavigation" while debugging.
      accuracy: AppConfig.debugLocation ? LocationAccuracy.bestForNavigation : LocationAccuracy.high,
      // Disable client-side movement filtering while debugging location issues.
      distanceFilter: AppConfig.debugLocation ? 0 : 10,
    );
    return Geolocator.getPositionStream(locationSettings: settings);
  }

  Future<Position> currentPosition() {
    final settings = LocationSettings(
      accuracy: AppConfig.debugLocation ? LocationAccuracy.bestForNavigation : LocationAccuracy.high,
    );
    return Geolocator.getCurrentPosition(locationSettings: settings);
  }
}

