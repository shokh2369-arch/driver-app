import 'package:flutter/material.dart';

import '../../../core/localization/arb/app_localizations.dart';

/// Shown when the driver is **registered but not yet approved** — backend returns
/// **403 `DRIVER_NOT_APPROVED`** (see `docs/BACKEND_SETUP_CHECKLIST.md` §6). The token is
/// valid, so this is NOT a dead session and NOT a generic failure: the driver simply waits
/// for approval. Popping returns to the code screen so they can re-check after approval.
class AwaitingApprovalScreen extends StatelessWidget {
  const AwaitingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(t.awaiting_approval_title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Icon(
                  Icons.hourglass_top_rounded,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  t.awaiting_approval_title,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(
                  t.awaiting_approval_message,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.awaiting_approval_check_again),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
