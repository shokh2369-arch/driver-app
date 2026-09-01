import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'trip_status_voice.dart';

class LocalNotifications {
  LocalNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  /// Channel id is versioned so a config change (importance / sound / vibration)
  /// takes effect on existing installs — Android does not let you re-configure
  /// a channel once it has been created, only create a new one with a new id.
  static const String _ordersChannelId = 'orders_v5';
  static const String _ordersChannelName = 'New orders';
  static const String _ordersChannelDescription =
      'Heads-up alerts for new ride requests and assigned trips.';

  /// Bundled in `android/app/src/main/res/raw/yettiqanot_ringtone.mp3`.
  static const RawResourceAndroidNotificationSound _orderAlertSound =
      RawResourceAndroidNotificationSound('yettiqanot_ringtone');

  /// iOS/macOS custom sound. Must be added to the Xcode target as a bundle resource
  /// (`Runner/Sounds/yettiqanot_ringtone.caf` or `.aiff`); when it is missing iOS falls
  /// back to the default alert tone rather than staying silent.
  static const String _orderAlertSoundDarwin = 'yettiqanot_ringtone.caf';

  static final Int64List _ordersVibration = Int64List.fromList(<int>[
    0,
    350,
    200,
    350,
    200,
    600,
  ]);

  static AndroidNotificationChannel _buildOrdersChannel() {
    return AndroidNotificationChannel(
      _ordersChannelId,
      _ordersChannelName,
      description: _ordersChannelDescription,
      importance: Importance.max,
      playSound: true,
      sound: _orderAlertSound,
      enableVibration: true,
      enableLights: true,
      vibrationPattern: _ordersVibration,
    );
  }

  /// True once [ensureInitialized] has run to completion. Stays false when the platform
  /// plugin is unavailable so [notifyNewOrder] can skip straight to the in-app cue.
  static bool _ready = false;

  /// Best-effort. The plugin is absent in unit tests and can fail to register on some
  /// OEM builds; callers use `unawaited(notifyNewOrder(...))`, so letting anything throw
  /// here surfaces as an unhandled async error inside the dispatch poll.
  static Future<void> ensureInitialized() async {
    if (_inited) return;
    _inited = true;

    try {
      await _initializePlugin();
      _ready = true;
    } catch (e, st) {
      debugPrint('[yetti_driver] local notifications unavailable: $e');
      assert(() {
        debugPrintStack(stackTrace: st, label: 'local notifications init');
        return true;
      }());
    }
  }

  static Future<void> _initializePlugin() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Permissions are requested explicitly below so the prompt is not tied to init order.
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
    );
    await _plugin.initialize(initSettings);

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidImpl != null) {
      await androidImpl.createNotificationChannel(_buildOrdersChannel());
      // Android 13+ runtime permission.
      await androidImpl.requestNotificationsPermission();
    }

    // Without this, iOS drivers get no new-order alerts at all.
    final iosImpl = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosImpl != null) {
      await iosImpl.requestPermissions(alert: true, badge: true, sound: true);
    }
    final macImpl = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    if (macImpl != null) {
      await macImpl.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  static Future<void> notifyNewOrder({
    required String title,
    required String body,
    required int id,
    /// Custom ringtone — only for queue offers ("Yangi buyurtma"), not assigned trips.
    bool playRingtone = false,
    /// When the app is open, play the ringtone in-app and skip the OS sound so
    /// drivers are not hit with a double alert.
    bool appInForeground = false,
  }) async {
    if (kIsWeb) return; // No OS notifications here (webapp handles separately).
    await ensureInitialized();

    final useRingtone = playRingtone;
    if (useRingtone && appInForeground) {
      unawaited(TripStatusVoice.playNewOrderSound());
    }

    final androidDetails = AndroidNotificationDetails(
      _ordersChannelId,
      _ordersChannelName,
      channelDescription: _ordersChannelDescription,
      importance: Importance.max,
      priority: Priority.max,
      // Treat as a message so heads-up shows even when the phone is in Do Not
      // Disturb "priority only" mode (drivers commonly use that while driving).
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.public,
      playSound: useRingtone && !appInForeground,
      sound: useRingtone && !appInForeground ? _orderAlertSound : null,
      enableVibration: true,
      enableLights: true,
      vibrationPattern: _ordersVibration,
      ticker: title,
      styleInformation: BigTextStyleInformation(body),
    );
    final darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      // In the foreground the in-app ringtone above already played.
      presentSound: !appInForeground,
      sound: useRingtone && !appInForeground ? _orderAlertSoundDarwin : null,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    if (!_ready) return; // In-app ringtone above already fired; OS channel is unavailable.

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );
    try {
      await _plugin.show(id, title, body, details);
    } catch (e) {
      debugPrint('[yetti_driver] notification show failed: $e');
    }
  }
}
