import '../features/trip/domain/driver_trip_history_item.dart';
import 'driver_dispatch_parser.dart' show extractFareSomFromMap;

/// Parses `GET /driver/trips` (or alias JSON) into a flat list. Accepts several
/// envelope shapes and per-row key aliases used by the Go service / variants.
List<DriverTripHistoryItem> parseDriverTripHistoryResponse(dynamic data) {
  final rawList = _extractTripMaps(data);
  final out = <DriverTripHistoryItem>[];
  for (final m in rawList) {
    final item = _parseOneTrip(m);
    if (item != null) out.add(item);
  }
  out.sort((a, b) {
    final da = a.occurredAt?.millisecondsSinceEpoch ?? 0;
    final db = b.occurredAt?.millisecondsSinceEpoch ?? 0;
    return db.compareTo(da);
  });
  return out;
}

List<Map<String, dynamic>> _extractTripMaps(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry(k.toString(), v))))
        .toList();
  }
  if (data is! Map) return const [];

  final root = Map<String, dynamic>.from(data.map((k, v) => MapEntry(k.toString(), v)));

  for (final key in const [
    'trips',
    'items',
    'history',
    'completed_trips',
    'rides',
    'data',
    'results',
  ]) {
    final v = root[key];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.map((k, val) => MapEntry(k.toString(), val))))
          .toList();
    }
    if (key == 'data' && v is Map) {
      final inner = Map<String, dynamic>.from(v.map((k, val) => MapEntry(k.toString(), val)));
      for (final ik in const ['trips', 'items', 'history']) {
        final innerList = inner[ik];
        if (innerList is List) {
          return innerList
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e.map((k2, val) => MapEntry(k2.toString(), val))))
              .toList();
        }
      }
    }
  }
  return const [];
}

DriverTripHistoryItem? _parseOneTrip(Map<String, dynamic> m) {
  final flat = _flattenTripRow(m);
  final tripId = _firstString(flat, const ['trip_id', 'id', 'uuid']);
  final statusRaw = _firstString(flat, const ['status', 'trip_status', 'state', 'phase']);
  final kind = _classifyStatus(statusRaw);

  final at = _parseDateTime(
    flat,
    const [
      'finished_at',
      'completed_at',
      'ended_at',
      'cancelled_at',
      'canceled_at',
      'updated_at',
      'started_at',
      'created_at',
      'trip_date',
      'date',
    ],
  );

  final fare = extractFareSomFromMap(flat) ?? _firstDouble(flat, const ['total_som', 'amount_som', 'fare_amount']);
  final fee = _firstDouble(flat, const [
    'service_fee_som',
    'commission_som',
    'platform_fee_som',
    'fee_som',
    'service_fee',
    'commission',
    'platform_fee',
    'commission_amount',
    'app_fee_som',
  ]);

  if (tripId == null && statusRaw == null && at == null && fare == null && fee == null) {
    return null;
  }

  return DriverTripHistoryItem(
    tripId: tripId,
    kind: kind,
    occurredAt: at,
    totalFareSom: fare,
    serviceFeeSom: fee,
    rawStatus: kind == DriverTripHistoryKind.unknown ? statusRaw : null,
  );
}

Map<String, dynamic> _flattenTripRow(Map<String, dynamic> json) {
  final out = Map<String, dynamic>.from(json);
  for (final key in const ['trip', 'details', 'meta']) {
    final o = json[key];
    if (o is Map) {
      final inner = Map<String, dynamic>.from(o.map((k, v) => MapEntry(k.toString(), v)));
      for (final e in inner.entries) {
        out.putIfAbsent(e.key, () => e.value);
      }
    }
  }
  return out;
}

DriverTripHistoryKind _classifyStatus(String? s) {
  if (s == null) return DriverTripHistoryKind.unknown;
  final t = s.trim().toLowerCase();
  if (t.isEmpty) return DriverTripHistoryKind.unknown;
  if (const {
    'finished',
    'completed',
    'done',
    'complete',
    'paid',
    'closed',
  }.contains(t)) {
    return DriverTripHistoryKind.completed;
  }
  if (const {
    'cancelled',
    'canceled',
    'cancelled_by_driver',
    'cancelled_by_rider',
    'driver_cancelled',
    'driver_canceled',
    'rider_cancelled',
    'passenger_cancelled',
    'cancel',
  }.contains(t)) {
    return DriverTripHistoryKind.cancelled;
  }
  if (const {
    'started',
    'in_progress',
    'inprogress',
    'active',
    'assigned',
    'arrived',
    'waiting',
    'pending',
  }.contains(t)) {
    return DriverTripHistoryKind.inProgress;
  }
  return DriverTripHistoryKind.unknown;
}

DateTime? _parseDateTime(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    if (v is DateTime) return v;
    final s = v.toString().trim();
    if (s.isEmpty) continue;
    final parsed = DateTime.tryParse(s);
    if (parsed != null) return parsed.toLocal();
    final asInt = int.tryParse(s);
    if (asInt != null && asInt > 1000000000) {
      if (asInt > 20000000000) {
        return DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true).toLocal();
      }
      return DateTime.fromMillisecondsSinceEpoch(asInt * 1000, isUtc: true).toLocal();
    }
  }
  return null;
}

String? _firstString(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isNotEmpty) return s;
  }
  return null;
}

double? _firstDouble(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    if (v is num) return v.toDouble();
    final d = double.tryParse(v.toString());
    if (d != null) return d;
  }
  return null;
}
