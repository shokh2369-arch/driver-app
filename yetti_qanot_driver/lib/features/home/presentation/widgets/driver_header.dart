import 'package:flutter/material.dart';

import 'status_badge.dart';

class DriverHeader extends StatelessWidget {
  const DriverHeader({
    super.key,
    required this.name,
    required this.phone,
    required this.online,
    required this.onlineText,
    required this.offlineText,
  });

  final String name;
  final String phone;
  final bool online;
  final String onlineText;
  final String offlineText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = name.trim().isNotEmpty ? name.trim().split(' ').take(2).map((e) => e.characters.first).join() : 'YQ';

    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14),
          foregroundColor: theme.colorScheme.primary,
          child: Text(
            initials.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                phone,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        StatusBadge(
          online: online,
          onlineText: onlineText,
          offlineText: offlineText,
        ),
      ],
    );
  }
}

