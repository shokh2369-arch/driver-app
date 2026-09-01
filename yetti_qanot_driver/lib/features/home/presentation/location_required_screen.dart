import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/arb/app_localizations.dart';
import 'location_gate_controller.dart';

class LocationRequiredScreen extends ConsumerWidget {
  const LocationRequiredScreen({super.key, required this.state});

  final LocationGateDenied state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_on, size: 72, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    state.serviceEnabled ? t.allow_location : t.enable_location,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'YettiQanot driver app requires location before opening.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton(
                      onPressed: () => ref.read(locationGateProvider.notifier).request(),
                      child: Text(state.serviceEnabled ? t.allow_location : t.enable_location),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

