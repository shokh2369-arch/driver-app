import '../core/localization/arb/app_localizations.dart';
import 'config.dart';

/// User-facing hint when trip guards fail on live location (HTTP vs Telegram-only deploy).
String tripLiveLocationStaleHint(AppLocalizations t) {
  if (AppConfig.driverHttpLiveLocationEnabled) {
    return t.live_location_keep_app_gps;
  }
  return t.live_location_telegram_required;
}
