import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/formatting/money_uzs.dart';
import '../../../core/localization/arb/app_localizations.dart';
import '../../../services/config.dart';
import '../../../services/driver_trip_history_parser.dart';
import '../../../services/service_providers.dart';
import '../../trip/domain/driver_trip_history_item.dart';

/// Trip ledger from `GET /driver/trips` (path overridable via `DRIVER_TRIP_HISTORY_HTTP_PATH`).
class TripHistoryScreen extends ConsumerStatefulWidget {
  const TripHistoryScreen({super.key});

  @override
  ConsumerState<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends ConsumerState<TripHistoryScreen> {
  late Future<List<DriverTripHistoryItem>> _future;

  @override
  void initState() {
    super.initState();
    // After synchronous initState; avoids edge cases where provider-backed HTTP
    // runs before the [ConsumerStatefulElement] is fully mounted.
    _future = Future.microtask(() => _load());
  }

  Future<List<DriverTripHistoryItem>> _load() async {
    if (!AppConfig.hasHttpApi) return [];
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return [];
    final raw = await repo.getDriverTripHistory();
    return parseDriverTripHistoryResponse(raw);
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
    });
    await _future;
  }

  String _statusTitle(AppLocalizations t, DriverTripHistoryItem item) {
    switch (item.kind) {
      case DriverTripHistoryKind.completed:
        return t.trip_history_status_completed;
      case DriverTripHistoryKind.cancelled:
        return t.trip_history_status_cancelled;
      case DriverTripHistoryKind.inProgress:
        return t.trip_history_status_in_progress;
      case DriverTripHistoryKind.unknown:
        final r = item.rawStatus?.trim();
        if (r != null && r.isNotEmpty) return r;
        return t.trip_history_status_unknown;
    }
  }

  Color _statusColor(ThemeData theme, DriverTripHistoryKind kind) {
    switch (kind) {
      case DriverTripHistoryKind.completed:
        return theme.colorScheme.tertiary;
      case DriverTripHistoryKind.cancelled:
        return theme.colorScheme.error;
      case DriverTripHistoryKind.inProgress:
        return theme.colorScheme.primary;
      case DriverTripHistoryKind.unknown:
        return theme.colorScheme.outline;
    }
  }

  String? _dateLine(BuildContext context, DateTime? at) {
    if (at == null) return null;
    final loc = Localizations.localeOf(context);
    final df = DateFormat.yMMMd(loc.toString()).add_Hm();
    return df.format(at);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    if (!AppConfig.hasHttpApi) {
      return Scaffold(
        appBar: AppBar(title: Text(t.trip_history_title)),
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
      appBar: AppBar(title: Text(t.trip_history_title)),
      body: FutureBuilder<List<DriverTripHistoryItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.wifi_off_rounded, size: 48, color: theme.colorScheme.error),
                    const SizedBox(height: 16),
                    Text(
                      t.trip_history_load_error,
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
          final items = snapshot.data ?? [];
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
                      t.trip_history_empty,
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
                final statusColor = _statusColor(theme, item.kind);
                final dateStr = _dateLine(context, item.occurredAt);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.trip_history_status_label,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _statusTitle(t, item),
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: statusColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (dateStr != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              t.trip_history_date_label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              dateStr,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ],
                          const SizedBox(height: 10),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.trip_price_label,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      formatDisplayFareSom(
                                        item.totalFareSom,
                                        suffix: t.currency_som,
                                      ),
                                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      t.trip_history_service_fee_label,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      formatDisplayFareSom(
                                        item.serviceFeeSom,
                                        suffix: t.currency_som,
                                      ),
                                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ],
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
