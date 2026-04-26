import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/localization/arb/app_localizations.dart';
import '../../../core/theme/ios_tokens.dart';

/// Shown when `POST /auth/request-code` returns **403 DRIVER_NOT_REGISTERED**.
///
/// Opens [YettiQanot Haydovchi](https://t.me/YettiQanot_Haydovchibot) for registration.
class DriverNotRegisteredScreen extends StatelessWidget {
  const DriverNotRegisteredScreen({super.key});

  static const telegramBotUrl = 'https://t.me/YettiQanot_Haydovchibot';

  Future<void> _openTelegram(BuildContext context) async {
    final uri = Uri.parse(telegramBotUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.not_registered_title),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.person_off_outlined,
                  size: 56,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 20),
                Text(
                  t.not_registered_title,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(
                  t.not_registered_message,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () => _openTelegram(context),
                  icon: const Icon(Icons.send_rounded, size: 22),
                  label: Text(t.not_registered_telegram_button),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.brightness == Brightness.dark
                        ? IosTokens.systemBlueDark
                        : IosTokens.systemBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  telegramBotUrl,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.not_registered_back),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
