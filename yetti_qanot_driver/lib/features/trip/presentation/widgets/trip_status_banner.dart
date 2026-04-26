import 'package:flutter/material.dart';

import '../../../../core/theme/ios_tokens.dart';
import '../../domain/trip_status.dart';

class TripStatusBanner extends StatelessWidget {
  const TripStatusBanner({
    super.key,
    required this.status,
    required this.toPickupText,
    required this.arrivedText,
    required this.startedText,
  });

  final TripStatus status;
  final String toPickupText;
  final String arrivedText;
  final String startedText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color accent, String text, IconData icon) = switch (status) {
      TripStatus.waiting => (IosTokens.systemBlue, toPickupText, Icons.navigation),
      TripStatus.arrived => (const Color(0xFFFBBF24), arrivedText, Icons.flag),
      TripStatus.started => (const Color(0xFF4ADE80), startedText, Icons.directions_car),
      TripStatus.finished => (theme.colorScheme.surfaceContainerHighest, '', Icons.check),
    };

    if (status == TripStatus.finished) return const SizedBox.shrink();

    /// Telegram Mini App–style navy strip + status lamp.
    const bar = Color(0xFF102A43);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bar,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(blurRadius: 8, offset: Offset(0, 2), color: Colors.black26)],
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(blurRadius: 6, color: accent.withValues(alpha: 0.65))],
            ),
          ),
          const SizedBox(width: 12),
          Icon(icon, color: Colors.white.withValues(alpha: 0.9), size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

