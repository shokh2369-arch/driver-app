import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'config.dart';

class LocationService {
  Future<bool> ensureServiceEnabled() async {
    if (AppConfig.mockLocation != null) return true;
    return Geolocator.isLocationServiceEnabled();
  }

  Future<LocationPermission> checkPermission() => AppConfig.mockLocation != null
      ? Future.value(LocationPermission.always)
      : Geolocator.checkPermission();

  Future<LocationPermission> requestPermission() =>
      AppConfig.mockLocation != null
          ? Future.value(LocationPermission.always)
          : Geolocator.requestPermission();

  /// Debug-only fixed position (see [AppConfig.mockLocation]) with a few metres
  /// of drift so bearing / follow logic still gets exercised.
  static Position _mockPosition(int tick) {
    final m = AppConfig.mockLocation!;
    final drift = (tick % 20) * 0.00003; // ≈ 3 m per tick, resets every 20 ticks
    return Position(
      latitude: m.lat + drift,
      longitude: m.lng + drift,
      timestamp: DateTime.now(),
      accuracy: 8,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 45,
      headingAccuracy: 0,
      speed: 4,
      speedAccuracy: 0,
    );
  }

  /// Position stream.
  ///
  /// When [background] is true on Android, geolocator starts a foreground
  /// service so the OS keeps the GPS stream and Dart timers alive while the
  /// app is backgrounded or the screen is off. On iOS, background location
  /// updates are enabled (requires `UIBackgroundModes=location` in Info.plist).
  ///
  /// The persistent notification is **required** by Android while a
  /// foreground-service location subscription is alive — that's why the app
  /// only requests background mode on actual lifecycle transitions, not
  /// while the driver is using the app in the foreground.
  Stream<Position> positionStream({
    bool background = false,
    String foregroundTitle = 'YettiQanot Driver',
    String foregroundBody = 'Sizning lokatsiyangiz buyurtma uchun yoqilgan.',
    String foregroundChannelName = 'Driver location',
  }) {
    if (AppConfig.mockLocation != null) {
      var tick = 0;
      return Stream<Position>.periodic(
        const Duration(seconds: 2),
        (_) => _mockPosition(tick++),
      );
    }
    return Geolocator.getPositionStream(
      locationSettings: _streamSettings(
        background: background,
        foregroundTitle: foregroundTitle,
        foregroundBody: foregroundBody,
        foregroundChannelName: foregroundChannelName,
      ),
    );
  }

  Future<Position> currentPosition() {
    if (AppConfig.mockLocation != null) return Future.value(_mockPosition(0));
    final settings = LocationSettings(
      accuracy: AppConfig.debugLocation
          ? LocationAccuracy.bestForNavigation
          : LocationAccuracy.high,
    );
    return Geolocator.getCurrentPosition(locationSettings: settings);
  }

  LocationSettings _streamSettings({
    required bool background,
    required String foregroundTitle,
    required String foregroundBody,
    required String foregroundChannelName,
  }) {
    final accuracy = AppConfig.debugLocation
        ? LocationAccuracy.bestForNavigation
        : LocationAccuracy.high;
    final distanceFilter = AppConfig.debugLocation ? 0 : 10;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        foregroundNotificationConfig: background
            ? ForegroundNotificationConfig(
                notificationTitle: foregroundTitle,
                notificationText: foregroundBody,
                notificationChannelName: foregroundChannelName,
                enableWakeLock: true,
                setOngoing: true,
              )
            : null,
      );
    }

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        // `allowBackgroundLocationUpdates` only takes effect when Info.plist
        // declares `UIBackgroundModes=location`. Toggle per-call so we don't
        // run background updates unnecessarily while in the foreground.
        allowBackgroundLocationUpdates: background,
        showBackgroundLocationIndicator: false,
      );
    }

    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }
}
