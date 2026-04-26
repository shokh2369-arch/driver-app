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

/// Mini App–style rider block: Mijoz, phone, pickup coords, [Qo'ng'iroq].
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
    final coord =
        '${request.pickup.latitude.toStringAsFixed(5)}, ${request.pickup.longitude.toStringAsFixed(5)}';

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
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.location_on_outlined, size: 18, color: Colors.red.shade400),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          coord,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                            fontFeatures: const [FontFeature.tabularFigures()],
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating pill: remaining km + ETA minutes (Mini App strip on the map).
class TripMapStatsPill extends StatelessWidget {
  const TripMapStatsPill({super.key, required this.trip, required this.driverPos});

  final TripState trip;
  final MapLatLng? driverPos;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final req = trip.activeRequest;
    if (req == null) return const SizedBox.shrink();

    final target = trip.status == TripStatus.started ? req.destination : req.pickup;
    final km = driverPos != null ? haversineKm(driverPos!, target) : null;
    final minutes = km != null ? (km / 30.0) * 60.0 : null;
    final minRounded = minutes?.round().clamp(0, 9999);

    final isDark = theme.brightness == Brightness.dark;
    final pillBg = isDark ? IosTokens.darkBackground : theme.colorScheme.surface.withValues(alpha: 0.97);
    final onPill = isDark ? Colors.white.withValues(alpha: 0.95) : theme.colorScheme.onSurface;
    final muted = isDark ? Colors.white.withValues(alpha: 0.55) : theme.colorScheme.onSurfaceVariant;

    return Center(
      child: Material(
        elevation: isDark ? 0 : 2,
        color: pillBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(
            color: isDark ? Colors.white.withValues(alpha: 0.1) : theme.dividerColor.withValues(alpha: 0.4),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.place_outlined, size: 18, color: Colors.red.shade400),
              const SizedBox(width: 6),
              Text(
                km != null ? formatKm(km) : '—',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: onPill),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Container(
                  width: 1,
                  height: 18,
                  color: isDark ? Colors.white.withValues(alpha: 0.2) : theme.dividerColor,
                ),
              ),
              Icon(Icons.schedule, size: 18, color: muted),
              const SizedBox(width: 6),
              Text(
                minRounded != null ? t.trip_map_stats_minutes(minRounded) : '—',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: onPill),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two tiles: Narx | Masofa (below map, above action buttons).
class TripFareDistanceStrip extends StatelessWidget {
  const TripFareDistanceStrip({super.key, required this.trip});

  final TripState trip;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final req = trip.activeRequest;
    if (req == null) return const SizedBox.shrink();

    final preStart = trip.status == TripStatus.waiting || trip.status == TripStatus.arrived;
    final price = preStart ? '—' : formatDisplayFareSom(req.fareSom);
    final distKm = (req.distanceKm != null && req.distanceKm! > 0)
        ? req.distanceKm!
        : (trip.clientOdometerKm > 0 ? trip.clientOdometerKm : null);
    final dist = preStart
        ? '—'
        : (distKm != null ? '${distKm.toStringAsFixed(1)} km' : '—');

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
        tile(icon: Icons.payments_outlined, label: t.trip_price_label, value: price),
        const SizedBox(width: 10),
        tile(icon: Icons.straighten, label: t.trip_distance_label, value: dist),
      ],
    );
  }
}

Future<void> launchRiderOrDispatchCall(TripRequest? request) async {
  var raw = (request?.riderPhone != null && request!.riderPhone!.trim().isNotEmpty)
      ? request.riderPhone!.trim()
      : AppConfig.dispatchPhoneE164.trim();
  raw = raw.replaceAll(RegExp(r'\s'), '');
  if (raw.isEmpty) return;
  if (raw.startsWith('tel:')) {
    raw = raw.substring(4);
  }
  if (!raw.startsWith('+') && RegExp(r'^\d+$').hasMatch(raw)) {
    raw = '+$raw';
  }
  final uri = Uri.parse('tel:$raw');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
