import 'package:shared_preferences/shared_preferences.dart';

class AppPrefs {
  AppPrefs(this._prefs);

  final SharedPreferences _prefs;

  static const _keyThemeMode = 'theme_mode'; // system|light|dark
  static const _keyLocaleTag = 'locale_tag'; // e.g. uz, uz-Cyrl
  static const _keyDriverOnline = 'driver_online';
  static const _keyDriverId = 'driver_id';
  /// Opaque session secret from [POST /auth/verify-code] — sent as `X-Driver-Session` when set.
  static const _keyDriverSessionToken = 'driver_session_token';

  String? get themeMode => _prefs.getString(_keyThemeMode);
  Future<void> setThemeMode(String value) => _prefs.setString(_keyThemeMode, value);

  String? get localeTag => _prefs.getString(_keyLocaleTag);
  Future<void> setLocaleTag(String value) => _prefs.setString(_keyLocaleTag, value);

  bool? get driverOnline => _prefs.getBool(_keyDriverOnline);
  Future<void> setDriverOnline(bool value) => _prefs.setBool(_keyDriverOnline, value);

  /// Persisted `X-Driver-Id` for API auth (digits: internal user id or Telegram id). Empty / absent means “not set”.
  String? get driverId {
    final s = _prefs.getString(_keyDriverId);
    if (s == null || s.trim().isEmpty) return null;
    return s.trim();
  }

  Future<void> setDriverId(String value) => _prefs.setString(_keyDriverId, value.trim());

  Future<void> clearDriverId() => _prefs.remove(_keyDriverId);

  String? get driverSessionToken {
    final s = _prefs.getString(_keyDriverSessionToken);
    if (s == null || s.trim().isEmpty) return null;
    return s.trim();
  }

  Future<void> setDriverSessionToken(String value) =>
      _prefs.setString(_keyDriverSessionToken, value.trim());

  Future<void> clearDriverSessionToken() => _prefs.remove(_keyDriverSessionToken);
}

