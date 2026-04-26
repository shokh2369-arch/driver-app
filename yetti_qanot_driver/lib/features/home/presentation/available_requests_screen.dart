import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/geo/lat_lng.dart';
import '../../../core/localization/arb/app_localizations.dart';
import '../../../services/config.dart';
import '../../../services/driver_dispatch_parser.dart';
import '../../../services/driver_user_exception.dart';
import '../../../services/service_providers.dart';
import '../../trip/presentation/trip_controller.dart';
import '../../trip/presentation/widgets/distance_utils.dart';

/// Lists queue rows from `GET /driver/available-requests` with distance (API or haversine from [driverPosition]).
class AvailableRequestsScreen extends ConsumerStatefulWidget {
  const AvailableRequestsScreen({super.key, this.driverPosition});

  final MapLatLng? driverPosition;

  @override
  ConsumerState<AvailableRequestsScreen> createState() => _AvailableRequestsScreenState();
}

class _AvailableRequestsScreenState extends ConsumerState<AvailableRequestsScreen> {
  late Future<List<QueueOfferItem>> _future;
  String? _acceptingRequestId;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<QueueOfferItem>> _load() async {
    if (!AppConfig.hasHttpApi) return [];
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return [];
    final raw = await repo.getAvailableRequests();
    return parseAvailableRequests(raw).queueItems;
  }

  String _distanceLine(QueueOfferItem item) {
    final dk = item.distanceKm;
    if (dk != null && dk > 0) {
      return formatKm(dk);
    }
    final me = widget.driverPosition;
    if (me != null) {
      return formatKm(haversineKm(me, item.pickup));
    }
    return '—';
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
    });
    await _future;
  }

  String _acceptErrorMessage(DriverUserException e, AppLocalizations t) {
    if (e.userCode == 'TRIP_NOT_FOUND') {
      return t.trip_plan_not_found;
    }
    if (e.message.trim().isEmpty) {
      return t.trip_plan_not_found;
    }
    return e.message;
  }

  Future<void> _accept(BuildContext context, QueueOfferItem item) async {
    final t = AppLocalizations.of(context);
    setState(() => _acceptingRequestId = item.requestId);
    try {
      await ref.read(tripProvider.notifier).acceptOfferByRequestId(item.requestId);
      if (!context.mounted) return;
      Navigator.of(context).pop();
    } on DriverUserException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_acceptErrorMessage(e, t))),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Accept failed')),
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
      body: FutureBuilder<List<QueueOfferItem>>(
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
                              CircleAvatar(
                                backgroundColor: theme.colorScheme.primaryContainer,
                                child: Icon(Icons.place_outlined, color: theme.colorScheme.onPrimaryContainer),
                              ),
                              const SizedBox(width: 12),
                              const Spacer(),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    t.trip_distance_label,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  Text(
                                    _distanceLine(item),
                                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
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
