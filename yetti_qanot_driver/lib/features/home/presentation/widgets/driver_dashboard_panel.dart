import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/geo/lat_lng.dart';
import '../../../../core/localization/arb/app_localizations.dart';
import '../../../../core/theme/ios_tokens.dart';
import '../../../trip/domain/driver_dashboard_stats.dart';
import '../../../trip/domain/trip_request.dart';
import '../../../trip/domain/trip_status.dart';
import '../../../trip/presentation/widgets/distance_utils.dart';

/// Reference #2: bento cards — teal · indigo/orange · green balance · sky parking.
class DriverDashboardPanel extends StatelessWidget {
  const DriverDashboardPanel({
    super.key,
    required this.promoValue,
    required this.cashValue,
    required this.totalBalanceText,
    required this.onBalanceTap,
    this.dashboardStats,
    this.pendingOffer,
    this.driverPosition,
    this.unfinishedTripStatus,
    this.onContinueUnfinishedTrip,
    this.onAcceptOffer,
    this.acceptOfferLabel,
    this.onTripHistoryTap,
    this.onAvailableRequestsTap,
    this.onPendingOfferTimeout,
  });

  final String promoValue;
  final String cashValue;
  final String totalBalanceText;
  final VoidCallback onBalanceTap;

  /// Stats from `GET /driver/promo-program` / `GET /driver/referral-status` when parseable.
  final DriverDashboardStats? dashboardStats;

  /// When set, the middle “free” row is replaced by an inline incoming-order card.
  final TripRequest? pendingOffer;
  final MapLatLng? driverPosition;

  /// Active trip stuck on dashboard (e.g. session lost “Accept” flag) — full-width resume card.
  final TripStatus? unfinishedTripStatus;
  final VoidCallback? onContinueUnfinishedTrip;

  final VoidCallback? onAcceptOffer;
  final String? acceptOfferLabel;

  /// Commission strip + orange stat icons (bookmark / clock / person).
  final VoidCallback? onTripHistoryTap;

  /// Indigo hail tile — open available-requests list.
  final VoidCallback? onAvailableRequestsTap;

  /// Fires when the auto-offer countdown reaches 0 — hide dashboard card; request may stay in queue.
  final VoidCallback? onPendingOfferTimeout;

  static const _r = 20.0;

  /// iOS system–style accents (cards stay vibrant on grouped background).
  static Color _bannerColor(Brightness b) =>
      b == Brightness.dark ? IosTokens.systemBlueDark : IosTokens.systemBlue;
  static Color _offerColor(Brightness b) =>
      b == Brightness.dark ? IosTokens.systemIndigo : IosTokens.systemIndigo;
  static Color _statsColor(Brightness b) =>
      b == Brightness.dark ? IosTokens.systemOrange : IosTokens.systemOrange;
  static Color _walletColor(Brightness b) =>
      b == Brightness.dark ? IosTokens.systemGreenDark : IosTokens.systemGreen;
  static Color _parkingColor(Brightness b) =>
      b == Brightness.dark ? IosTokens.systemTeal : IosTokens.systemTeal;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final hasInlineOffer =
        pendingOffer != null && onAcceptOffer != null && acceptOfferLabel != null;
    final hasUnfinishedTrip =
        unfinishedTripStatus != null &&
        onContinueUnfinishedTrip != null &&
        unfinishedTripStatus != TripStatus.finished;
    final b = theme.brightness;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SolidCard(
          color: _bannerColor(b),
          radius: _r,
          onTap: onTripHistoryTap,
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.local_taxi, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.commission_banner,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.calendar_today, size: 15, color: Colors.white.withValues(alpha: 0.9)),
                        const SizedBox(width: 6),
                        Text('30', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white)),
                        const SizedBox(width: 16),
                        Icon(Icons.schedule, size: 15, color: Colors.white.withValues(alpha: 0.9)),
                        const SizedBox(width: 6),
                        Text('23:24', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (hasInlineOffer)
          _SolidCard(
            color: _offerColor(b),
            radius: _r,
            child: _DashboardIncomingOffer(
              request: pendingOffer!,
              driverPosition: driverPosition,
              onAccept: onAcceptOffer!,
              acceptLabel: acceptOfferLabel!,
              onOfferTimeout: onPendingOfferTimeout,
            ),
          )
        else if (hasUnfinishedTrip)
          _SolidCard(
            color: _offerColor(b),
            radius: _r,
            child: _DashboardUnfinishedTrip(
              status: unfinishedTripStatus!,
              onContinue: onContinueUnfinishedTrip!,
            ),
          )
        else
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 26,
                  child: _SolidCard(
                    color: _offerColor(b),
                    radius: _r,
                    onTap: onAvailableRequestsTap,
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Center(
                        child: Icon(Icons.hail_rounded, color: Colors.white.withValues(alpha: 0.95), size: 40),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 44,
                  child: _SolidCard(
                    color: _statsColor(b),
                    radius: _r,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _StatIcon(
                            icon: Icons.bookmark_border,
                            value: dashboardStats?.displayBookmark ?? '0',
                            onTap: onTripHistoryTap,
                          ),
                          _StatIcon(
                            icon: Icons.schedule,
                            value: dashboardStats?.displayClock ?? '0',
                            onTap: onTripHistoryTap,
                          ),
                          _StatIcon(
                            icon: Icons.person_outline,
                            value: dashboardStats?.displayPerson ?? '0',
                            onTap: onTripHistoryTap,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Material(
          color: _walletColor(b),
          borderRadius: BorderRadius.circular(_r),
          elevation: 0,
          shadowColor: Colors.transparent,
          child: InkWell(
            onTap: onBalanceTap,
            borderRadius: BorderRadius.circular(_r),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.account_balance_wallet, color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      totalBalanceText,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: Colors.white.withValues(alpha: 0.95), size: 28),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${t.promo_balance}: $promoValue',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                '${t.cash_balance}: $cashValue',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SolidCard(
          color: _parkingColor(b),
          radius: _r,
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text(
                    'P',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  t.parking_off,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DashboardUnfinishedTrip extends StatelessWidget {
  const _DashboardUnfinishedTrip({
    required this.status,
    required this.onContinue,
  });

  final TripStatus status;
  final VoidCallback onContinue;

  String _phaseLine(AppLocalizations t) {
    switch (status) {
      case TripStatus.waiting:
        return t.to_pickup;
      case TripStatus.arrived:
        return t.arrived;
      case TripStatus.started:
        return t.unfinished_trip_phase_started;
      case TripStatus.finished:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final phase = _phaseLine(t);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.route_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.unfinished_trip_title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (phase.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        phase,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.92),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: onContinue,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: IosTokens.systemIndigo,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              t.unfinished_trip_continue,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardIncomingOffer extends StatefulWidget {
  const _DashboardIncomingOffer({
    required this.request,
    this.driverPosition,
    required this.onAccept,
    required this.acceptLabel,
    this.onOfferTimeout,
  });

  final TripRequest request;
  final MapLatLng? driverPosition;
  final VoidCallback onAccept;
  final String acceptLabel;
  final VoidCallback? onOfferTimeout;

  @override
  State<_DashboardIncomingOffer> createState() => _DashboardIncomingOfferState();
}

class _DashboardIncomingOfferState extends State<_DashboardIncomingOffer> {
  static const _countdownSeconds = 15;

  late int _seconds = _countdownSeconds;
  Timer? _timer;

  void _armTimer() {
    _timer?.cancel();
    _seconds = _countdownSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_seconds <= 0) return;
      var hitZero = false;
      setState(() {
        _seconds -= 1;
        if (_seconds == 0) {
          hitZero = true;
          _timer?.cancel();
          _timer = null;
        }
      });
      if (hitZero) {
        final cb = widget.onOfferTimeout;
        if (cb != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => cb());
        }
      }
    });
  }

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
    _armTimer();
  }

  @override
  void didUpdateWidget(covariant _DashboardIncomingOffer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.id != widget.request.id) {
      HapticFeedback.mediumImpact();
      _armTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final tripKm = haversineKm(widget.request.pickup, widget.request.destination);
    final toPickupKm = widget.driverPosition != null
        ? haversineKm(widget.driverPosition!, widget.request.pickup)
        : tripKm;
    final etaMinutes = (tripKm / 30.0) * 60.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.auto_offer,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${_seconds}s',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _InlineMetric(
                label: t.dist_to_pickup,
                value: formatKm(toPickupKm),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _InlineMetric(
          label: 'ETA',
          value: formatMinutes(etaMinutes),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 50,
          width: double.infinity,
          child: FilledButton(
            onPressed: widget.onAccept,
            style: FilledButton.styleFrom(
              backgroundColor: theme.brightness == Brightness.dark
                  ? IosTokens.systemGreenDark
                  : IosTokens.systemGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle, size: 22),
                const SizedBox(width: 8),
                Text(
                  widget.acceptLabel,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InlineMetric extends StatelessWidget {
  const _InlineMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _SolidCard extends StatelessWidget {
  const _SolidCard({
    required this.color,
    required this.radius,
    required this.child,
    this.onTap,
  });

  final Color color;
  final double radius;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final padded = Padding(
      padding: const EdgeInsets.all(14),
      child: child,
    );
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      elevation: 0,
      shadowColor: Colors.transparent,
      child: onTap != null
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(radius),
              child: padded,
            )
          : padded,
    );
  }
}

class _StatIcon extends StatelessWidget {
  const _StatIcon({required this.icon, required this.value, this.onTap});

  final IconData icon;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white, size: 22),
        const SizedBox(width: 6),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
        ),
      ],
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: row,
        ),
      ),
    );
  }
}
