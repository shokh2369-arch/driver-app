import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/storage_providers.dart';

class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() {
    final tag = ref.watch(appPrefsProvider).localeTag;
    if (tag == null || tag.isEmpty) return null; // device locale
    return _localeFromTag(tag);
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    if (locale == null) {
      // fall back to device locale
      await ref.read(appPrefsProvider).setLocaleTag('');
      return;
    }
    await ref.read(appPrefsProvider).setLocaleTag(_tagFromLocale(locale));
  }

  static Locale _localeFromTag(String tag) {
    if (tag == 'uz') return const Locale('uz');
    if (tag.toLowerCase() == 'uz-cyrl' || tag == 'uz_Cyrl') {
      return const Locale.fromSubtags(languageCode: 'uz', scriptCode: 'Cyrl');
    }
    // Fallback to language only
    return Locale(tag);
  }

  static String _tagFromLocale(Locale locale) {
    if (locale.languageCode == 'uz' && locale.scriptCode == 'Cyrl') return 'uz-Cyrl';
    return locale.languageCode;
  }
}

final localeProvider = NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
);

