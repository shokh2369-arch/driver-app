import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/localization/arb/app_localizations.dart';
import '../../../../core/theme/ios_tokens.dart';

/// iOS-style top bar: frosted material (non-web), system green online capsule, adaptive switch.
class DriverAppBarOverlay extends StatelessWidget {
  const DriverAppBarOverlay({
    super.key,
    required this.online,
    required this.onMenu,
    required this.onPhone,
    required this.onOnlineToggle,
    this.tripMapChrome = false,
  });

  final bool online;
  final VoidCallback onMenu;
  final VoidCallback onPhone;
  final Future<void> Function(bool nextOnline) onOnlineToggle;

  /// Solid black bar + light icons (active trip map), matching Mini App reference.
  final bool tripMapChrome;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final useDarkTripHeader = tripMapChrome && theme.brightness == Brightness.dark;
    final onBar = useDarkTripHeader ? Colors.white : theme.colorScheme.onSurface;

    final barChild = Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              IconButton(
                tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
                onPressed: onMenu,
                icon: Icon(Icons.menu_rounded, color: onBar),
              ),
              Expanded(
                child: Center(
                  child: _OnlinePill(
                    online: online,
                    onlineLabel: t.online,
                    offlineLabel: t.offline,
                    onChanged: onOnlineToggle,
                  ),
                ),
              ),
              IconButton(
                tooltip: t.call,
                onPressed: onPhone,
                icon: Icon(Icons.phone_in_talk_rounded, color: onBar),
              ),
            ],
          ),
        ),
      ),
    );

    final surface = theme.colorScheme.surface;
    final tint = theme.brightness == Brightness.light
        ? Colors.white.withValues(alpha: 0.72)
        : surface.withValues(alpha: 0.82);

    final bgColor = useDarkTripHeader
        ? IosTokens.darkBackground
        : (kIsWeb ? surface : tint);
    final borderColor = useDarkTripHeader
        ? Colors.white.withValues(alpha: 0.12)
        : (theme.brightness == Brightness.light
            ? IosTokens.separatorOpaque.withValues(alpha: 0.65)
            : Colors.white.withValues(alpha: 0.12));

    return ClipRect(
      child: Stack(
        children: [
          if (!kIsWeb && !useDarkTripHeader)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: const SizedBox.expand(),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: bgColor,
              border: Border(
                bottom: BorderSide(
                  color: borderColor,
                  width: 0.5,
                ),
              ),
            ),
            child: barChild,
          ),
        ],
      ),
    );
  }
}

class _OnlinePill extends StatelessWidget {
  const _OnlinePill({
    required this.online,
    required this.onlineLabel,
    required this.offlineLabel,
    required this.onChanged,
  });

  final bool online;
  final String onlineLabel;
  final String offlineLabel;
  final Future<void> Function(bool nextOnline) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = online
        ? (isDark ? IosTokens.systemGreenDark : IosTokens.systemGreen)
        : (isDark ? IosTokens.darkElevated2 : IosTokens.systemGray4);
    final fg = online ? Colors.white : theme.colorScheme.onSurface.withValues(alpha: 0.85);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(100),
        elevation: online ? 0 : 0,
        shadowColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 4, top: 4, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  online ? onlineLabel : offlineLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Switch.adaptive(
                value: online,
                onChanged: (nextOnline) async {
                  await onChanged(nextOnline);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
