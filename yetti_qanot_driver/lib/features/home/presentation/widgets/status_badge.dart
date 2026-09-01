import 'package:flutter/material.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.online,
    required this.onlineText,
    required this.offlineText,
  });

  final bool online;
  final String onlineText;
  final String offlineText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = online
        ? Colors.green.withValues(alpha: 0.14)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8);
    final fg = online ? Colors.green.shade700 : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: online ? Colors.green : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            online ? onlineText : offlineText,
            style: theme.textTheme.labelLarge?.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}

