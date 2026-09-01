import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'arb/app_localizations.dart';
import 'locale_controller.dart';

/// Localized strings for code that runs **outside** the widget tree — e.g. OS
/// notifications fired from [TripController] while the app is backgrounded, where
/// there is no [BuildContext] to call `AppLocalizations.of` on.
///
/// Falls back to the template locale (`uz`) when the stored tag is unsupported.
AppLocalizations l10nFor(Ref ref) {
  final locale = ref.read(localeProvider);
  if (locale != null) {
    try {
      return lookupAppLocalizations(locale);
    } catch (_) {
      // Unsupported stored locale — fall through to the default below.
    }
  }
  return lookupAppLocalizations(const Locale('uz'));
}
