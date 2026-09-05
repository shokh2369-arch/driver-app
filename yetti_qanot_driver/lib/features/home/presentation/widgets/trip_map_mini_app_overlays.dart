import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/formatting/money_uzs.dart';
import '../../../../core/geo/lat_lng.dart';
import '../../../../core/localization/arb/app_localizations.dart';
import '../../../../core/theme/ios_tokens.dart';
import '../../../../services/config.dart';
import '../../../trip/domain/trip_request.dart';
import '../../../trip/domain/trip_status.dart';
import '../../../trip/presentation/trip_state.dart';
import '../../../trip/presentation/widgets/distance_utils.dart';

Color _tripCardSurface(ThemeData theme) => theme.brightness == Brightness.dark
    ? IosTokens.darkElevated
    : theme.colorScheme.surface;

Color _tripCardOnSurface(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.96)
    : theme.colorScheme.onSurface;

Color _tripCardMuted(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.62)
    : theme.colorScheme.onSurfaceVariant;

/// Rider block on the approach: Mijoz + phone on the left, [Qo'ng'iroq] and [Navigator]
/// on the right. No raw coordinates — a driver cannot act on them; the map and the
/// navigator button carry the where.
class TripRiderInfoCard extends StatelessWidget {
  const TripRiderInfoCard({
    super.key,
    required this.request,
    required this.onCall,
    this.onNavigateToPickup,
  });

  final TripRequest request;
  final VoidCallback onCall;
  final VoidCallback? onNavigateToPickup;

  static String _prettyPhone(String raw) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.length == 12 && d.startsWith('998')) {
      return '+998 ${d.substring(3, 5)} ${d.substring(5, 8)} ${d.substring(8, 12)}';
    }
    if (d.length == 9 && !raw.contains('+')) {
      return '+998 ${d.substring(0, 2)} ${d.substring(2, 5)} ${d.substring(5, 9)}';
    }
    return raw.startsWith('+') ? raw : '+$d';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final phoneRaw = request.riderPhone?.trim();
    final phone = phoneRaw != null && phoneRaw.isNotEmpty ? _prettyPhone(phoneRaw) : '—';

    final cardBg = _tripCardSurface(theme);
    final onCard = _tripCardOnSurface(theme);
    final muted = _tripCardMuted(theme);
    final accentBlue =
        theme.brightness == Brightness.dark ? IosTokens.systemBlueDark : IosTokens.systemBlue;

    return Material(
      elevation: theme.brightness == Brightness.dark ? 0 : 2,
      shadowColor: Colors.black38,
      color: cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.08)
              : theme.dividerColor.withValues(alpha: 0.35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.person_outline, size: 20, color: accentBlue),
                      const SizedBox(width: 8),
                      Text(
                        t.trip_customer_label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: onCard,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.phone_outlined, size: 18, color: muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          phone,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: onCard,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints.tightFor(width: 120),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onCall,
                      icon: Icon(Icons.call, size: 20, color: onCard),
                      label: Text(
                        t.call,
                        style: TextStyle(fontWeight: FontWeight.w700, color: onCard),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.brightness == Brightness.dark
                            ? IosTokens.darkElevated2
                            : theme.colorScheme.surfaceContainerHigh,
                        foregroundColor: onCard,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  if (onNavigateToPickup != null) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onNavigateToPickup,
                        icon: const Icon(Icons.navigation_rounded, size: 20, color: Colors.white),
                        label: Text(
                          t.navigate_to_pickup,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: accentBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two tiles below the map, above the action button. Phase-aware, never two dashes:
/// on the way to the customer — distance to the pickup and the minutes it takes;
/// once the ride is running — the live fare and the distance driven.
class TripFareDistanceStrip extends StatelessWidget {
  const TripFareDistanceStrip({super.key, required this.trip, this.driverPos});

  final TripState trip;

  /// Driver position for the approach metrics; null → those tiles show a dash.
  final MapLatLng? driverPos;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final req = trip.activeRequest;
    if (req == null) return const SizedBox.shrink();

    final preStart = trip.status == TripStatus.waiting || trip.status == TripStatus.arrived;

    final IconData leftIcon;
    final IconData rightIcon;
    final String leftLabel;
    final String leftValue;
    final String rightLabel;
    final String rightValue;
    if (preStart) {
      final pickup = req.pickup;
      final km = (driverPos != null && pickup != null) ? haversineKm(driverPos!, pickup) : null;
      // Same rough city speed the offer card quotes, so the two numbers agree.
      final minutes = km != null ? (km / 30.0) * 60.0 : null;
      leftIcon = Icons.place_outlined;
      leftLabel = t.dist_to_pickup;
      leftValue = formatKm(km);
      rightIcon = Icons.schedule;
      rightLabel = t.eta_short;
      rightValue = minutes != null
          ? t.trip_map_stats_minutes(minutes.round().clamp(0, 9999))
          : '—';
    } else {
      final estimated = req.estimatedPriceSom;
      leftIcon = Icons.payments_outlined;
      leftLabel = t.trip_price_label;
      // Until the server's metered fare arrives, the estimate from the offer beats a dash.
      leftValue = req.fareSom != null
          ? formatDisplayFareSom(req.fareSom, suffix: t.currency_som)
          : (estimated > 0 ? formatSomInt(estimated, suffix: t.currency_som) : '—');
      final distKm = (req.distanceKm != null && req.distanceKm! > 0)
          ? req.distanceKm!
          : (trip.clientOdometerKm > 0 ? trip.clientOdometerKm : null);
      rightIcon = Icons.straighten;
      rightLabel = t.trip_distance_label;
      rightValue = distKm != null ? '${distKm.toStringAsFixed(1)} km' : '—';
    }

    final cardBg = _tripCardSurface(theme);
    final onCard = _tripCardOnSurface(theme);
    final muted = _tripCardMuted(theme);
    final accentBlue =
        theme.brightness == Brightness.dark ? IosTokens.systemBlueDark : IosTokens.systemBlue;

    Widget tile({required IconData icon, required String label, required String value}) {
      return Expanded(
        child: Material(
          elevation: theme.brightness == Brightness.dark ? 0 : 1,
          color: cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : theme.dividerColor.withValues(alpha: 0.35),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 20, color: accentBlue),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: onCard,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tile(icon: leftIcon, label: leftLabel, value: leftValue),
        const SizedBox(width: 10),
        tile(icon: rightIcon, label: rightLabel, value: rightValue),
      ],
    );
  }
}

/// Dial the rider (or the dispatch line as a fallback). Reports failure to [context]
/// instead of no-op'ing when no dialer can be resolved.
Future<void> launchRiderOrDispatchCall(
  BuildContext context,
  TripRequest? request,
) async {
  final t = AppLocalizations.of(context);
  var raw = (request?.riderPhone != null && request!.riderPhone!.trim().isNotEmpty)
      ? request.riderPhone!.trim()
      : AppConfig.dispatchPhoneE164.trim();
  raw = raw.replaceAll(RegExp(r'\s'), '');
  if (raw.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.launch_dialer_failed)),
    );
    return;
  }
  if (raw.startsWith('tel:')) {
    raw = raw.substring(4);
  }
  if (!raw.startsWith('+') && RegExp(r'^\d+$').hasMatch(raw)) {
    raw = '+$raw';
  }
  final uri = Uri.parse('tel:$raw');
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('[yetti_driver] tel: launch failed: $e');
  }
  if (ok || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(t.launch_dialer_failed)),
  );
}
