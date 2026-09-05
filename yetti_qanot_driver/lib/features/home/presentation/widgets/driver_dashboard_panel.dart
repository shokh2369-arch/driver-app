import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/formatting/money_uzs.dart';
import '../../../../core/geo/lat_lng.dart';
import '../../../../core/localization/arb/app_localizations.dart';
import '../../../../core/theme/ios_tokens.dart';
import '../../../trip/domain/commission_info.dart';
import '../../../trip/domain/driver_dashboard_stats.dart';
import '../../../trip/domain/trip_request.dart';
import '../../../trip/domain/trip_status.dart';
import '../../../trip/presentation/trip_state.dart';
import '../../../trip/presentation/widgets/distance_utils.dart';

/// Driver home dashboard — an "instrument panel": calm neutral cards, readouts in tabular
/// figures, and colour used only for meaning (green = money/go, blue = brand/navigation,
/// red = alert). Boldness is spent in one place: the live incoming offer.
///
/// Public API is unchanged — [HomeScreen] passes the same fields as before.
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
    this.pendingOfferExpiresAt,
    this.commission,
    this.online = false,
  });

  final String promoValue;
  final String cashValue;
  final String totalBalanceText;
  final VoidCallback onBalanceTap;

  /// From `GET /driver/promo-program` / `GET /driver/referral-status`. Not rendered as the
  /// old bookmark/clock/person triple — those fields arrive unlabeled, so "0 0 0" under
  /// mystery icons read as broken data. Kept on the API surface; surface them again once
  /// their meaning is defined (see the two labeled tiles below).
  final DriverDashboardStats? dashboardStats;

  /// When set, the middle slot becomes the live incoming-order card.
  final TripRequest? pendingOffer;
  final MapLatLng? driverPosition;

  /// Active trip stranded on the dashboard (e.g. session lost the “Accept” flag).
  final TripStatus? unfinishedTripStatus;
  final VoidCallback? onContinueUnfinishedTrip;

  /// Async so the offer card can show progress and block a duplicate accept.
  final Future<void> Function()? onAcceptOffer;
  final String? acceptOfferLabel;

  final VoidCallback? onTripHistoryTap;
  final VoidCallback? onAvailableRequestsTap;

  /// Fires when the auto-offer countdown reaches 0.
  final VoidCallback? onPendingOfferTimeout;

  /// Wall-clock expiry for the auto-offer countdown (anchored to notification time).
  final DateTime? pendingOfferExpiresAt;

  /// Current commission from the backend. Null → the row is hidden (not loaded / older
  /// backend). Never a hardcoded or guessed rate — it's deducted from the wallet.
  final CommissionInfo? commission;

  /// Driver is ONLINE. With no offer on screen the dashboard says it is listening —
  /// otherwise an empty panel reads as "the app stopped".
  final bool online;

  static const _radius = 18.0;
  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final palette = _DashPalette.of(context);

    final hasInlineOffer =
        pendingOffer != null && onAcceptOffer != null && acceptOfferLabel != null;
    final hasUnfinishedTrip =
        unfinishedTripStatus != null &&
        onContinueUnfinishedTrip != null &&
        unfinishedTripStatus != TripStatus.finished;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Balance — the anchor. It is what a driver checks and it gates dispatch, so it
        //    leads. Neutral card, earnings in a large green tabular readout.
        _BalanceCard(
          palette: palette,
          total: totalBalanceText,
          promoLabel: t.promo_balance,
          promoValue: promoValue,
          cashLabel: t.cash_balance,
          cashValue: cashValue,
          onTap: onBalanceTap,
        ),
        const SizedBox(height: _gap),

        // 2. The money moment (offer) or resume-trip sits ABOVE the two work tiles, never
        //    in their place: Buyurtmalar and Safarlar tarixi must stay reachable while an
        //    offer counts down.
        if (hasInlineOffer) ...[
          _OfferCard(
            palette: palette,
            radius: _radius,
            child: _DashboardIncomingOffer(
              request: pendingOffer!,
              expiresAt: pendingOfferExpiresAt ??
                  DateTime.now().add(kQueueOfferPreviewWindow),
              driverPosition: driverPosition,
              onAccept: onAcceptOffer!,
              acceptLabel: acceptOfferLabel!,
              onOfferTimeout: onPendingOfferTimeout,
            ),
          ),
          const SizedBox(height: _gap),
        ] else if (hasUnfinishedTrip) ...[
          _Card(
            palette: palette,
            radius: _radius,
            child: _DashboardUnfinishedTrip(
              palette: palette,
              status: unfinishedTripStatus!,
              onContinue: onContinueUnfinishedTrip!,
            ),
          ),
          const SizedBox(height: _gap),
        ],
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _WorkTile(
                  palette: palette,
                  icon: Icons.hail_rounded,
                  label: t.orders,
                  onTap: onAvailableRequestsTap,
                ),
              ),
              const SizedBox(width: _gap),
              Expanded(
                child: _WorkTile(
                  palette: palette,
                  icon: Icons.receipt_long_rounded,
                  label: t.trip_history_title,
                  onTap: onTripHistoryTap,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: _gap),

        // 3. Standing info, demoted to quiet strips: the commission rate and, while ONLINE
        //    with nothing on offer, a steady "waiting for orders" lamp. Neither competes
        //    with money or offers.
        // Commission is admin-editable and money-relevant, so the row shows the real
        // backend value, "no commission" when it's off/0, or nothing at all when the
        // backend hasn't sent it — never a guessed number.
        if (commission != null) ...[
          _InfoStrip(
            palette: palette,
            icon: Icons.percent_rounded,
            text: commission!.isOff
                ? t.commission_off
                : t.commission_rate('${commission!.percent}'),
          ),
          const SizedBox(height: _gap),
        ],
        if (online && !hasInlineOffer && !hasUnfinishedTrip)
          _InfoStrip(
            palette: palette,
            leading: _LiveDot(color: palette.money),
            text: t.waiting_for_orders,
          ),
      ],
    );
  }
}

/// Resolved semantic colours for the dashboard, derived once per build.
class _DashPalette {
  const _DashPalette({
    required this.surface,
    required this.border,
    required this.onSurface,
    required this.muted,
    required this.accent,
    required this.money,
    required this.shadow,
    required this.isDark,
  });

  final Color surface;
  final Color border;
  final Color onSurface;
  final Color muted;
  final Color accent; // brand / navigation
  final Color money; // earnings / go
  final Color? shadow;
  final bool isDark;

  factory _DashPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return _DashPalette(
      isDark: isDark,
      surface: isDark ? IosTokens.darkElevated : Colors.white,
      border: isDark
          ? Colors.white.withValues(alpha: 0.09)
          : IosTokens.separatorOpaque.withValues(alpha: 0.45),
      onSurface: isDark ? Colors.white : IosTokens.labelPrimary,
      muted: theme.colorScheme.onSurfaceVariant,
      accent: isDark ? IosTokens.systemBlueDark : IosTokens.systemBlue,
      money: isDark ? IosTokens.systemGreenDark : IosTokens.systemGreen,
      // A soft lift in light mode so white cards read against a near-white page.
      shadow: isDark ? null : Colors.black.withValues(alpha: 0.06),
    );
  }
}

/// Neutral surface card — the base of the instrument-panel look.
class _Card extends StatelessWidget {
  const _Card({
    required this.palette,
    required this.radius,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  final _DashPalette palette;
  final double radius;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: palette.border),
        boxShadow: palette.shadow == null
            ? null
            : [BoxShadow(color: palette.shadow!, blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(radius),
                child: Padding(padding: padding, child: child),
              ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.palette,
    required this.total,
    required this.promoLabel,
    required this.promoValue,
    required this.cashLabel,
    required this.cashValue,
    required this.onTap,
  });

  final _DashPalette palette;
  final String total;
  final String promoLabel;
  final String promoValue;
  final String cashLabel;
  final String cashValue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      palette: palette,
      radius: DriverDashboardPanel._radius,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _GlyphBox(
                palette: palette,
                icon: Icons.account_balance_wallet_rounded,
                tint: palette.money,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(context).balance,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: palette.muted,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      total,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: palette.money,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: palette.muted, size: 24),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, thickness: 1, color: palette.border),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  palette: palette,
                  label: promoLabel,
                  value: promoValue,
                ),
              ),
              Container(width: 1, height: 28, color: palette.border),
              Expanded(
                child: _MiniStat(
                  palette: palette,
                  label: cashLabel,
                  value: cashValue,
                  alignEnd: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.palette,
    required this.label,
    required this.value,
    this.alignEnd = false,
  });

  final _DashPalette palette;
  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cross = alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Padding(
      padding: EdgeInsets.only(left: alignEnd ? 12 : 0, right: alignEnd ? 0 : 12),
      child: Column(
        crossAxisAlignment: cross,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: palette.muted),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: palette.onSurface,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkTile extends StatelessWidget {
  const _WorkTile({
    required this.palette,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final _DashPalette palette;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      palette: palette,
      radius: DriverDashboardPanel._radius,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlyphBox(palette: palette, icon: icon, tint: palette.accent),
          const SizedBox(height: 12),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: palette.onSurface,
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small rounded glyph container — the recurring instrument motif.
class _GlyphBox extends StatelessWidget {
  const _GlyphBox({required this.palette, required this.icon, required this.tint});

  final _DashPalette palette;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: palette.isDark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: tint, size: 24),
    );
  }
}

class _InfoStrip extends StatelessWidget {
  const _InfoStrip({
    required this.palette,
    required this.text,
    this.icon,
    this.leading,
  });

  final _DashPalette palette;
  final String text;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      palette: palette,
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          leading ??
              Icon(icon, size: 20, color: palette.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Steady status lamp for a quiet strip — the same idiom as the trip status banner.
class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(blurRadius: 6, color: color.withValues(alpha: 0.6))],
          ),
        ),
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.palette,
    required this.radius,
    required this.child,
  });

  final _DashPalette palette;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.money,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: palette.money.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _DashboardUnfinishedTrip extends StatelessWidget {
  const _DashboardUnfinishedTrip({
    required this.palette,
    required this.status,
    required this.onContinue,
  });

  final _DashPalette palette;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _GlyphBox(palette: palette, icon: Icons.route_rounded, tint: palette.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.unfinished_trip_title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: palette.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (phase.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      phase,
                      style: theme.textTheme.bodyMedium?.copyWith(color: palette.muted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: onContinue,
            style: FilledButton.styleFrom(
              backgroundColor: palette.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              t.unfinished_trip_continue,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DashboardIncomingOffer extends StatefulWidget {
  const _DashboardIncomingOffer({
    required this.request,
    required this.expiresAt,
    this.driverPosition,
    required this.onAccept,
    required this.acceptLabel,
    this.onOfferTimeout,
  });

  final TripRequest request;
  final DateTime expiresAt;
  final MapLatLng? driverPosition;

  /// May be async (network accept) — the button shows progress until it settles.
  final Future<void> Function() onAccept;
  final String acceptLabel;
  final VoidCallback? onOfferTimeout;

  @override
  State<_DashboardIncomingOffer> createState() => _DashboardIncomingOfferState();
}

class _DashboardIncomingOfferState extends State<_DashboardIncomingOffer> {
  late int _seconds;
  Timer? _timer;

  /// Accepting hits the network; without this the driver can fire a second
  /// `POST /driver/accept-request`, and the duplicate comes back 409 "already taken"
  /// on an order they actually won.
  bool _accepting = false;

  int _remainingSeconds() {
    final left = widget.expiresAt.difference(DateTime.now()).inSeconds;
    if (left <= 0) return 0;
    return left;
  }

  void _fireTimeoutIfNeeded() {
    // Never yank the offer out from under an accept that is already in flight.
    if (_accepting) return;
    final cb = widget.onOfferTimeout;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => cb());
  }

  Future<void> _handleAccept() async {
    if (_accepting) return;
    setState(() => _accepting = true);
    try {
      await widget.onAccept();
    } finally {
      if (!mounted) return;
      setState(() => _accepting = false);
      // If the accept call returns after local expiry, dismiss immediately.
      if (_remainingSeconds() <= 0) {
        _fireTimeoutIfNeeded();
      }
    }
  }

  void _armTimer() {
    _timer?.cancel();
    _seconds = _remainingSeconds();
    if (_seconds <= 0) {
      _fireTimeoutIfNeeded();
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = _remainingSeconds();
      if (next <= 0) {
        setState(() => _seconds = 0);
        _timer?.cancel();
        _timer = null;
        _fireTimeoutIfNeeded();
        return;
      }
      if (next != _seconds) {
        setState(() => _seconds = next);
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
    if (oldWidget.request.id != widget.request.id ||
        oldWidget.expiresAt != widget.expiresAt) {
      if (oldWidget.request.id != widget.request.id) {
        HapticFeedback.mediumImpact();
      }
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

    // Either endpoint can be absent when the backend omits coordinates.
    final pickup = widget.request.pickup;
    final destination = widget.request.destination;
    final tripKm = (pickup != null && destination != null)
        ? haversineKm(pickup, destination)
        : null;
    final me = widget.driverPosition;
    final toPickupKm =
        (me != null && pickup != null) ? haversineKm(me, pickup) : tripKm;
    // ETA is the time to REACH the customer, so it must be derived from the distance to
    // pickup, not the ride length.
    final etaMinutes = toPickupKm != null ? (toPickupKm / 30.0) * 60.0 : null;
    final estimated = widget.request.estimatedPriceSom;

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
            _CountdownPill(seconds: _seconds),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _OfferMetric(
                label: t.dist_to_pickup,
                value: formatKm(toPickupKm),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _OfferMetric(
                label: t.eta_to_pickup,
                value: formatMinutes(etaMinutes),
              ),
            ),
          ],
        ),
        if (estimated > 0) ...[
          const SizedBox(height: 8),
          _OfferMetric(
            label: t.estimated_price_label,
            value: formatSomInt(estimated, suffix: t.currency_som),
            wide: true,
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          height: 52,
          width: double.infinity,
          child: FilledButton(
            onPressed: _accepting ? null : _handleAccept,
            style: FilledButton.styleFrom(
              // White action on the green card: maximum contrast for the one tap that matters.
              backgroundColor: Colors.white,
              foregroundColor: IosTokens.systemGreen,
              disabledBackgroundColor: Colors.white.withValues(alpha: 0.8),
              disabledForegroundColor: IosTokens.systemGreen,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_accepting)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: IosTokens.systemGreen,
                    ),
                  )
                else
                  const Icon(Icons.check_circle_rounded, size: 22),
                const SizedBox(width: 8),
                Text(
                  widget.acceptLabel,
                  // Explicit: on the white button the label must be green, not the theme's
                  // onSurface (which is white in dark mode → invisible).
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: IosTokens.systemGreen,
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

class _CountdownPill extends StatelessWidget {
  const _CountdownPill({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined, size: 15, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            '${seconds}s',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _OfferMetric extends StatelessWidget {
  const _OfferMetric({required this.label, required this.value, this.wide = false});

  final String label;
  final String value;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: wide ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
