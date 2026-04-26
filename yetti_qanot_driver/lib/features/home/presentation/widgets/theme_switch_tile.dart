import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/arb/app_localizations.dart';
import '../../../../core/theme/theme_controller.dart';

class ThemeSwitchTile extends ConsumerWidget {
  const ThemeSwitchTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final mode = ref.watch(themeProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.theme_title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<AppThemeMode>(
              segments: [
                ButtonSegment(value: AppThemeMode.system, label: Text(t.theme_system)),
                ButtonSegment(value: AppThemeMode.light, label: Text(t.theme_light)),
                ButtonSegment(value: AppThemeMode.dark, label: Text(t.theme_dark)),
              ],
              selected: {mode},
              onSelectionChanged: (set) {
                ref.read(themeProvider.notifier).setThemeMode(set.first);
              },
            ),
          ],
        ),
      ),
    );
  }
}

