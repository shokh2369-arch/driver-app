import 'package:flutter/material.dart';

class OnlineToggleButton extends StatelessWidget {
  const OnlineToggleButton({
    super.key,
    required this.online,
    required this.goOnlineText,
    required this.goOfflineText,
    required this.onPressed,
  });

  final bool online;
  final String goOnlineText;
  final String goOfflineText;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = online ? Colors.red : Colors.green;
    final label = online ? goOfflineText : goOnlineText;
    final icon = online ? Icons.pause_circle_filled : Icons.play_circle_fill;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: SizedBox(
        width: double.infinity,
        height: 62,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 22),
          label: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
      ),
    );
  }
}

