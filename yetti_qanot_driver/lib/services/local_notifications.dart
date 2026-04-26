import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class LocalNotifications {
  LocalNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static const AndroidNotificationChannel _ordersChannel = AndroidNotificationChannel(
    'orders',
    'Orders',
    description: 'Order notifications for drivers',
    importance: Importance.high,
  );

  static Future<void> ensureInitialized() async {
    if (_inited) return;
    _inited = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      await androidImpl.createNotificationChannel(_ordersChannel);
      // Android 13+ runtime permission.
      await androidImpl.requestNotificationsPermission();
    }
  }

  static Future<void> notifyNewOrder({
    required String title,
    required String body,
    required int id,
  }) async {
    if (kIsWeb) return; // No OS notifications here (webapp handles separately).
    await ensureInitialized();

    const androidDetails = AndroidNotificationDetails(
      'orders',
      'Orders',
      channelDescription: 'Order notifications for drivers',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(id, title, body, details);
  }
}

