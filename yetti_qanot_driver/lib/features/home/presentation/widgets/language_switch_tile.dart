import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/arb/app_localizations.dart';
import '../../../../core/localization/locale_controller.dart';
import '../../../../core/localization/supported_locales.dart';

class LanguageSwitchTile extends ConsumerWidget {
  const LanguageSwitchTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final locale = ref.watch(localeProvider);
    final selected = locale ?? Localizations.localeOf(context);

    Locale pick(SupportedLocale v) => switch (v) {
      SupportedLocale.uz => const Locale('uz'),
      SupportedLocale.uzCyrl => const Locale.fromSubtags(languageCode: 'uz', scriptCode: 'Cyrl'),
    };

    final current = isUzCyrl(selected) ? SupportedLocale.uzCyrl : SupportedLocale.uz;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.language_title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<SupportedLocale>(
              segments: [
                ButtonSegment(value: SupportedLocale.uz, label: Text(t.language_option_latin)),
                ButtonSegment(value: SupportedLocale.uzCyrl, label: Text(t.language_option_cyrillic)),
              ],
              selected: {current},
              onSelectionChanged: (set) {
                ref.read(localeProvider.notifier).setLocale(pick(set.first));
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.read(localeProvider.notifier).setLocale(null),
              child: Text(t.language_use_device),
            ),
          ],
        ),
      ),
    );
  }
}

enum SupportedLocale { uz, uzCyrl }

