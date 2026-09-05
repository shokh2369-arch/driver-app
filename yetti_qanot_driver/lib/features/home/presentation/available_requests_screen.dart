import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/money_uzs.dart';
import '../../../core/geo/lat_lng.dart';
import '../../../core/localization/arb/app_localizations.dart';
import '../../../core/theme/ios_tokens.dart';
import '../../../services/config.dart';
import '../../../services/driver_dispatch_parser.dart';
import '../../../services/driver_user_exception.dart';
import '../../../services/service_providers.dart';
import '../../trip/presentation/trip_controller.dart';
import '../../trip/presentation/widgets/distance_utils.dart';

/// Lists queue rows from `GET /driver/available-requests` with distance (API or haversine from [driverPosition]).
///
/// The list is **live**: it re-fetches every second while the screen is open, so new
/// orders appear and taken ones vanish without a pull-to-refresh. The refresh is
/// single-flight and only rebuilds the list when the rows actually changed, so it is
/// invisible unless there is news; a failed tick keeps the last good list on screen.
class AvailableRequestsScreen extends ConsumerStatefulWidget {
  const AvailableRequestsScreen({super.key, this.driverPosition});

  final MapLatLng? driverPosition;

  @override
  ConsumerState<AvailableRequestsScreen> createState() => _AvailableRequestsScreenState();
}

class _AvailableRequestsScreenState extends ConsumerState<AvailableRequestsScreen> {
  static const Duration _refreshEvery = Duration(seconds: 1);

  /// `null` until the first fetch answers; then always the last good list.
  List<QueueOfferItem>? _items;

  /// Only surfaced while there is no list to show yet.
  Object? _error;
  bool _inFlight = false;
  Timer? _timer;
  String? _acceptingRequestId;

  @override
  void initState() {
    super.initState();
    unawaited(_tick());
    _timer = Timer.periodic(_refreshEvery, (_) => unawaited(_tick()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<List<QueueOfferItem>> _load() async {
    if (!AppConfig.hasHttpApi) return [];
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return [];
    final raw = await repo.getAvailableRequests();
    return parseAvailableRequests(raw).queueItems;
  }

  /// One refresh: at most one request in flight, and no list reshuffle under a
  /// finger that is mid-accept.
  Future<void> _tick() async {
    if (_inFlight || !mounted || _acceptingRequestId != null) return;
    _inFlight = true;
    try {
      final items = _sortNearestFirst(await _load());
      if (!mounted) return;
      final current = _items;
      if (current == null || _error != null || !_sameRows(current, items)) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _items == null) setState(() => _error = e);
    } finally {
      _inFlight = false;
    }
  }

  static bool _sameRows(List<QueueOfferItem> a, List<QueueOfferItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_rowKey(a[i]) != _rowKey(b[i])) return false;
    }
    return true;
  }

  static String _rowKey(QueueOfferItem q) =>
      '${q.requestId}|${q.distanceKm}|${q.estimatedPriceSom}|'
      '${q.pickup.latitude},${q.pickup.longitude}';

  /// Distance to the pickup: the server's figure when it sent one, else straight-line
  /// from the driver's position, else unknown.
  double? _kmTo(QueueOfferItem item) {
    final dk = item.distanceKm;
    if (dk != null && dk > 0) return dk;
    final me = widget.driverPosition;
    return me != null ? haversineKm(me, item.pickup) : null;
  }

  String _distanceLine(QueueOfferItem item) => formatKm(_kmTo(item));

  /// Minutes to reach the customer at the same rough city speed the offer card uses.
  String _etaLine(QueueOfferItem item, AppLocalizations t) {
    final km = _kmTo(item);
    if (km == null) return '—';
    return t.trip_map_stats_minutes((km / 30.0 * 60.0).round().clamp(0, 9999));
  }

  /// Nearest first — that is how a driver reads the list. Rows with no known distance
  /// keep the server's order at the end. Stable, so unchanged data never reshuffles.
  List<QueueOfferItem> _sortNearestFirst(List<QueueOfferItem> items) {
    final indexed = items.asMap().entries.toList()
      ..sort((a, b) {
        final ka = _kmTo(a.value);
        final kb = _kmTo(b.value);
        if (ka == null && kb == null) return a.key.compareTo(b.key);
        if (ka == null) return 1;
        if (kb == null) return -1;
        final c = ka.compareTo(kb);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return [for (final e in indexed) e.value];
  }

  Future<void> _refresh() => _tick();

  String _acceptErrorMessage(DriverUserException e, AppLocalizations t) {
    switch (e.userCode) {
      case 'TRIP_NOT_FOUND':
        return t.trip_plan_not_found;
      case 'ACCEPT_REQUIRES_ONLINE':
        return t.accept_requires_online;
      case 'ACCEPT_FAILED':
        return e.message.trim().isEmpty ? t.accept_failed : e.message;
      case 'DRIVER_HAS_ACTIVE_TRIP':
        return e.message.trim().isEmpty ? t.accept_active_trip_exists : e.message;
    }
    if (e.message.trim().isEmpty) {
      return t.accept_failed;
    }
    return e.message;
  }

  Future<void> _accept(BuildContext context, QueueOfferItem item) async {
    final t = AppLocalizations.of(context);
    // Debounce: a second tap while a request is in flight can duplicate the accept.
    if (_acceptingRequestId != null) return;
    setState(() => _acceptingRequestId = item.requestId);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(tripProvider.notifier).acceptOfferByRequestId(item.requestId);
      if (!context.mounted) return;
      Navigator.of(context).pop();
    } on DriverUserException catch (e) {
      if (!context.mounted) return;
      // The driver already has an active trip: the controller has hydrated it, so pop back
      // to reveal it on Home rather than leaving them staring at the (still-listed) offer.
      // Use a captured messenger so the message survives the pop.
      if (e.userCode == 'DRIVER_HAS_ACTIVE_TRIP') {
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(content: Text(_acceptErrorMessage(e, t))),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(_acceptErrorMessage(e, t))),
      );
    } catch (e) {
      debugPrint('[yetti_driver] accept failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.accept_failed)),
      );
    } finally {
      if (mounted) setState(() => _acceptingRequestId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    if (!AppConfig.hasHttpApi) {
      return Scaffold(
        appBar: AppBar(title: Text(t.available_requests_title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              t.available_requests_no_api,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(t.available_requests_title)),
      body: Builder(
        builder: (context) {
          final items = _items;
          if (items == null && _error == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.wifi_off_rounded, size: 48, color: theme.colorScheme.error),
                    const SizedBox(height: 16),
                    Text(
                      t.available_requests_load_error,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _refresh,
                      child: Text(t.retry),
                    ),
                  ],
                ),
              ),
            );
          }
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: [
                  SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
                  Center(
                    child: Text(
                      t.available_requests_empty,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                final accepting = _acceptingRequestId == item.requestId;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Left: how far and how long to the customer — the two numbers a
                              // driver weighs before accepting.
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.dist_to_pickup,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _distanceLine(item),
                                      style: theme.textTheme.headlineSmall?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.schedule,
                                          size: 16,
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          _etaLine(item, t),
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              // Right: the money, in the same green the balance uses.
                              if (item.estimatedPriceSom > 0)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      t.estimated_price_label,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      formatSomInt(item.estimatedPriceSom, suffix: t.currency_som),
                                      style: theme.textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        color: theme.brightness == Brightness.dark
                                            ? IosTokens.systemGreenDark
                                            : IosTokens.systemGreen,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: accepting ? null : () => _accept(context, item),
                            icon: accepting
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: theme.colorScheme.onPrimary,
                                    ),
                                  )
                                : const Icon(Icons.check_circle_outline, size: 20),
                            label: Text(t.accept),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
