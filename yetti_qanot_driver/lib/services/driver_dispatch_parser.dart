import '../core/geo/lat_lng.dart';
import '../features/trip/domain/commission_info.dart';
import '../features/trip/domain/driver_balance.dart';
import '../features/trip/domain/trip_request.dart';
import '../features/trip/domain/trip_status.dart';

/// Parses `GET /driver/available-requests` per backend contract:
/// - `assigned_trip`: null or `{ trip_id, status }`
/// - Six aliases to the same slice: [available_requests, requests, pending_requests, queue, orders, jobs]
/// - Items: `request_id`, optional `trip_id`, `pickup_lat`, `pickup_lng`, `distance_km`, `radius_km`, optional `expires_at`
class AvailableRequestsSnapshot {
  const AvailableRequestsSnapshot({
    this.assignedTripId,
    this.assignedTripStatus,
    this.queueItems = const [],
  });

  final String? assignedTripId;
  final String? assignedTripStatus;
  final List<QueueOfferItem> queueItems;
}

class QueueOfferItem {
  const QueueOfferItem({
    required this.requestId,
    this.tripId,
    required this.pickup,
    this.distanceKm,
    this.radiusKm,
    this.estimatedPriceSom = 0,
    this.expiresAt,
    this.raw = const {},
  });

  final String requestId;
  final String? tripId;
  final MapLatLng pickup;
  final double? distanceKm;
  final double? radiusKm;
  final int estimatedPriceSom;
  final String? expiresAt;
  final Map<String, dynamic> raw;
}

const _queueKeys = [
  'available_requests',
  'requests',
  'pending_requests',
  'queue',
  'orders',
  'jobs',
];

AvailableRequestsSnapshot parseAvailableRequests(Map<String, dynamic> json) {
  String? assignedId;
  String? assignedStatus;
  final at = json['assigned_trip'];
  if (at is Map) {
    assignedId = at['trip_id']?.toString();
    assignedStatus = at['status']?.toString();
  }

  final seen = <String>{};
  final items = <QueueOfferItem>[];

  for (final key in _queueKeys) {
    final list = json[key];
    if (list is! List) continue;
    for (final e in list) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e.map((k, v) => MapEntry(k.toString(), v)));
      final rid = m['request_id']?.toString() ?? m['id']?.toString();
      if (rid == null || rid.isEmpty || seen.contains(rid)) continue;
      seen.add(rid);

      final plat = _num(m['pickup_lat']);
      final plng = _num(m['pickup_lng']);
      if (plat == null || plng == null) continue;

      final pickup = MapLatLng(plat, plng);
      final tid = m['trip_id']?.toString();
      items.add(
        QueueOfferItem(
          requestId: rid,
          tripId: tid != null && tid.isEmpty ? null : tid,
          pickup: pickup,
          distanceKm: _num(m['distance_km']),
          radiusKm: _num(m['radius_km']),
          estimatedPriceSom: _int(m['estimated_price']) ?? 0,
          expiresAt: m['expires_at']?.toString(),
          raw: m,
        ),
      );
    }
  }

  return AvailableRequestsSnapshot(
    assignedTripId: assignedId,
    assignedTripStatus: assignedStatus,
    queueItems: items,
  );
}

double? _num(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse(v.toString());
}

String? _extractRiderPhone(Map<String, dynamic> m) {
  final direct = m['rider_phone'] ?? m['passenger_phone'] ?? m['customer_phone'] ?? m['rider_phone_number'];
  if (direct != null && direct.toString().trim().isNotEmpty) {
    return direct.toString().trim();
  }
  for (final key in ['rider', 'passenger', 'customer', 'rider_info', 'user', 'client']) {
    final o = m[key];
    if (o is Map) {
      final inner = Map<String, dynamic>.from(o.map((k, v) => MapEntry(k.toString(), v)));
      final p = inner['phone'] ?? inner['phone_number'] ?? inner['mobile'] ?? inner['tel'];
      if (p != null && p.toString().trim().isNotEmpty) return p.toString().trim();
    }
  }
  return null;
}

double? extractFareSomFromMap(Map<String, dynamic> m) {
  final fareRaw = m['fare'];
  if (fareRaw is Map) {
    final fm = Map<String, dynamic>.from(fareRaw.map((k, v) => MapEntry(k.toString(), v)));
    final nested = _num(fm['amount'] ?? fm['value'] ?? fm['fare']);
    if (nested != null) return nested;
  }

  return _num(
    m['fare_som'] ??
        m['price_som'] ??
        m['estimated_fare_som'] ??
        m['narx'] ??
        m['total_fare'] ??
        m['amount'] ??
        m['fare'] ??
        m['price'] ??
        m['total_price'] ??
        m['total_som'] ??
        m['trip_fare'],
  );
}

/// Metered trip distance from `GET /trip/:id` (not client GPS billing).
double? extractDistanceKmFromMap(Map<String, dynamic> m) {
  return _num(
    m['distance_km'] ??
        m['trip_distance'] ??
        m['trip_distance_km'] ??
        m['distance'] ??
        m['route_km'] ??
        m['estimated_distance_km'],
  );
}

Map<String, dynamic> _flattenTripJson(Map<String, dynamic> json) {
  final out = Map<String, dynamic>.from(json);
  final data = json['data'];
  if (data is Map) {
    for (final e in data.entries) {
      out.putIfAbsent(e.key.toString(), () => e.value);
    }
  }
  final trip = json['trip'] ?? (data is Map ? data['trip'] : null);
  if (trip is Map) {
    final tm = Map<String, dynamic>.from(trip.map((k, v) => MapEntry(k.toString(), v)));
    for (final e in tm.entries) {
      out.putIfAbsent(e.key, () => e.value);
    }
  }
  return out;
}

/// Build [TripRequest] for UI: stable `id` = `request_id`. Destination comes from the
/// optional drop coords in [raw]; when absent it stays **null** so the UI can say
/// "no destination yet" instead of pointing the driver at a made-up location.
TripRequest tripRequestFromQueueItem(QueueOfferItem item) {
  final raw = item.raw;
  final dlat = _num(raw['dropoff_lat'] ?? raw['destination_lat'] ?? raw['drop_lat']);
  final dlng = _num(raw['dropoff_lng'] ?? raw['destination_lng'] ?? raw['drop_lng']);
  final destination = (dlat != null && dlng != null) ? MapLatLng(dlat, dlng) : null;

  return TripRequest(
    id: item.requestId,
    pickup: item.pickup,
    destination: destination,
    tripId: item.tripId,
    distanceKm: item.distanceKm,
    radiusKm: item.radiusKm,
    expiresAt: item.expiresAt,
    riderPhone: _extractRiderPhone(raw),
    fareSom: extractFareSomFromMap(raw),
    estimatedPriceSom: item.estimatedPriceSom,
  );
}

/// Read the current commission from a dispatch body (`GET /driver/available-requests`):
/// integer `commission_percent` + boolean `commission_charged`. This is the live source —
/// an admin change shows up on the next poll.
///
/// Returns **null** when the fields are absent (older backend, or not loaded yet) so the
/// caller can hide the row rather than invent a rate. A `data` envelope is tolerated.
CommissionInfo? parseCommissionFromJson(Map<String, dynamic> root) {
  var m = root;
  if (!root.containsKey('commission_percent')) {
    final data = root['data'];
    if (data is Map && data.containsKey('commission_percent')) {
      m = Map<String, dynamic>.from(data.map((k, v) => MapEntry(k.toString(), v)));
    }
  }
  if (!m.containsKey('commission_percent')) return null;
  final pct = _int(m['commission_percent']);
  if (pct == null) return null;

  final chargedRaw = m['commission_charged'];
  final bool charged;
  if (chargedRaw is bool) {
    charged = chargedRaw;
  } else if (chargedRaw == null) {
    charged = true; // field present rate but no flag → assume charged
  } else {
    charged = chargedRaw.toString().toLowerCase() == 'true';
  }

  final clamped = pct < 0 ? 0 : (pct > 100 ? 100 : pct);
  return CommissionInfo(charged: charged, percent: clamped);
}

/// Pull a trip status string out of a `GET /trip/:id` body, tolerating the flat shape and
/// the `trip` / `data` envelopes the Go service uses. Returns the raw string for
/// [parseServerTripStatus] to map.
String? tripStatusStringFromJson(Map<String, dynamic> j) {
  final direct = j['status'] ?? j['trip_status'];
  if (direct != null) return direct.toString();
  for (final k in const ['trip', 'data']) {
    final nested = j[k];
    if (nested is Map) {
      final s = nested['status'] ?? nested['trip_status'];
      if (s != null) return s.toString();
    }
  }
  return null;
}

TripStatus? parseServerTripStatus(String? s) {
  switch ((s ?? '').toUpperCase()) {
    case 'WAITING':
      return TripStatus.waiting;
    case 'ARRIVED':
      return TripStatus.arrived;
    case 'STARTED':
      return TripStatus.started;
    case 'FINISHED':
      return TripStatus.finished;
    default:
      return null;
  }
}

/// Best-effort parse for `GET /trip/:id` — tries common flat and nested keys.
TripRequest tripRequestFromTripJson(
  Map<String, dynamic> json, {
  required String requestId,
}) {
  final merged = _flattenTripJson(json);
  final tripId = merged['id']?.toString() ?? merged['trip_id']?.toString();

  var plat = _num(merged['pickup_lat']);
  var plng = _num(merged['pickup_lng']);
  final pickupMap = merged['pickup'];
  if (plat == null && pickupMap is Map) {
    plat = _num(pickupMap['lat'] ?? pickupMap['latitude']);
    plng = _num(pickupMap['lng'] ?? pickupMap['longitude']);
  }

  var dlat = _num(merged['dropoff_lat'] ?? merged['destination_lat'] ?? merged['drop_lat']);
  var dlng = _num(merged['dropoff_lng'] ?? merged['destination_lng'] ?? merged['drop_lng']);
  final destMap = merged['destination'] ?? merged['dropoff'];
  if (dlat == null && destMap is Map) {
    dlat = _num(destMap['lat'] ?? destMap['latitude']);
    dlng = _num(destMap['lng'] ?? destMap['longitude']);
  }

  // Missing coordinates stay null. Falling back to a city-centre point would silently
  // route the driver to the wrong place.
  final pickup = (plat != null && plng != null) ? MapLatLng(plat, plng) : null;
  final dest = (dlat != null && dlng != null) ? MapLatLng(dlat, dlng) : null;

  final dist = extractDistanceKmFromMap(merged);
  final est = _int(merged['estimated_price']) ?? 0;

  return TripRequest(
    id: merged['request_id']?.toString() ?? requestId,
    pickup: pickup,
    destination: dest,
    tripId: tripId,
    distanceKm: dist,
    riderPhone: _extractRiderPhone(merged),
    fareSom: extractFareSomFromMap(merged),
    estimatedPriceSom: est,
  );
}

Map<String, dynamic> _mergeDataEnvelope(Map<String, dynamic> json) {
  final out = Map<String, dynamic>.from(json);
  final data = json['data'];
  if (data is Map) {
    for (final e in data.entries) {
      out.putIfAbsent(e.key.toString(), () => e.value);
    }
  }
  return out;
}

DriverBalanceSnapshot? mergeDriverBalanceSnapshots(DriverBalanceSnapshot? a, DriverBalanceSnapshot? b) {
  if (a == null) return b == null ? null : _inferTotalFromParts(b);
  if (b == null) return _inferTotalFromParts(a);
  return _inferTotalFromParts(
    DriverBalanceSnapshot(
      totalSom: a.totalSom ?? b.totalSom,
      promoSom: a.promoSom ?? b.promoSom,
      cashSom: a.cashSom ?? b.cashSom,
    ),
  );
}

/// When the API omits aggregate `total_*` but sends promo and/or cash, use their sum for the headline total.
DriverBalanceSnapshot _inferTotalFromParts(DriverBalanceSnapshot s) {
  if (s.totalSom != null) return s;
  if (s.promoSom == null && s.cashSom == null) return s;
  return DriverBalanceSnapshot(
    totalSom: (s.promoSom ?? 0) + (s.cashSom ?? 0),
    promoSom: s.promoSom,
    cashSom: s.cashSom,
  );
}

const _nestedBalanceParentKeys = [
  'stats',
  'dashboard',
  'summary',
  'finance',
  'ledger',
  'driver_info',
  'profile',
  'economy',
  'referral',
  'driver_wallet',
  'wallet_info',
  'assigned_trip',
];

/// Optional wallet fields on `GET /driver/available-requests` (or same-shaped JSON).
/// Returns non-null only when at least one known key is present so callers can keep
/// the previous snapshot when the server omits wallet data on a given response.
DriverBalanceSnapshot? parseDriverBalanceFromDispatchJson(Map<String, dynamic> root) {
  DriverBalanceSnapshot? acc = _parseBalanceFromFlatMap(_mergeDataEnvelope(root));
  for (final nk in _nestedBalanceParentKeys) {
    final v = root[nk];
    if (v is Map) {
      final inner = Map<String, dynamic>.from(v.map((k, v) => MapEntry(k.toString(), v)));
      acc = mergeDriverBalanceSnapshots(acc, _parseBalanceFromFlatMap(_mergeDataEnvelope(inner)));
    }
  }
  return acc;
}

DriverBalanceSnapshot? _parseBalanceFromFlatMap(Map<String, dynamic> json) {
  double? total;
  double? promo;
  double? cash;
  var any = false;

  // First matching alias wins — the lists are ordered most-specific first, and the
  // nested `wallet` / `driver` / `balances` blocks below already use `??=`. Overwriting
  // let a trailing alias (e.g. `balance_tiyin`) silently beat `total_balance`.
  void takeTotal(String key) {
    if (total != null) return;
    final v = _money(json[key], key: key);
    if (v != null) {
      any = true;
      total = v;
    }
  }

  void takePromo(String key) {
    if (promo != null) return;
    final v = _money(json[key], key: key);
    if (v != null) {
      any = true;
      promo = v;
    }
  }

  void takeCash(String key) {
    if (cash != null) return;
    final v = _money(json[key], key: key);
    if (v != null) {
      any = true;
      cash = v;
    }
  }

  for (final k in [
    'total_balance',
    'balance_total',
    'balance',
    'wallet_balance',
    'driver_balance',
    'main_balance',
    'primary_balance',
    'account_balance',
    'available_balance',
    'real_balance',
    'som_balance',
    'balance_som',
    'total_som',
    'money',
    'funds',
    'balance_tiyin',
    'total_tiyin',
  ]) {
    if (json.containsKey(k)) takeTotal(k);
  }
  for (final k in [
    'promo_balance',
    'promo',
    'bonus_balance',
    'promo_som',
    'bonus_som',
    'referral_balance',
    'gift_balance',
    'promo_tiyin',
  ]) {
    if (json.containsKey(k)) takePromo(k);
  }
  for (final k in [
    'cash_balance',
    'cash',
    'cash_som',
    'main_cash',
    'liquid_balance',
    'cash_tiyin',
  ]) {
    if (json.containsKey(k)) takeCash(k);
  }

  final wallet = json['wallet'];
  if (wallet is Map) {
    final w = Map<String, dynamic>.from(wallet.map((k, v) => MapEntry(k.toString(), v)));
    for (final k in ['total', 'balance', 'total_balance']) {
      if (w.containsKey(k)) {
        final v = _money(w[k], key: k);
        if (v != null) {
          any = true;
          total ??= v;
          break;
        }
      }
    }
    for (final k in ['promo', 'promo_balance', 'bonus']) {
      if (w.containsKey(k)) {
        final v = _money(w[k], key: k);
        if (v != null) {
          any = true;
          promo ??= v;
          break;
        }
      }
    }
    for (final k in ['cash', 'cash_balance']) {
      if (w.containsKey(k)) {
        final v = _money(w[k], key: k);
        if (v != null) {
          any = true;
          cash ??= v;
          break;
        }
      }
    }
  }

  final balances = json['balances'];
  if (balances is Map) {
    for (final e in balances.entries) {
      final name = e.key.toString().toLowerCase();
      final val = _money(e.value, key: name);
      if (val == null) continue;
      any = true;
      if (name.contains('promo') || name.contains('bonus') || name.contains('gift')) {
        promo ??= val;
      } else if (name.contains('cash') || name.contains('main') || name.contains('primary')) {
        cash ??= val;
      } else if (name.contains('total') || name.contains('sum')) {
        total ??= val;
      }
    }
  }

  final driver = json['driver'];
  if (driver is Map) {
    final d = Map<String, dynamic>.from(driver.map((k, v) => MapEntry(k.toString(), v)));
    for (final k in ['total_balance', 'balance', 'balance_som']) {
      if (d.containsKey(k)) {
        final v = _money(d[k], key: k);
        if (v != null) {
          any = true;
          total ??= v;
          break;
        }
      }
    }
    for (final k in ['promo_balance', 'promo']) {
      if (d.containsKey(k)) {
        final v = _money(d[k], key: k);
        if (v != null) {
          any = true;
          promo ??= v;
          break;
        }
      }
    }
    for (final k in ['cash_balance', 'cash']) {
      if (d.containsKey(k)) {
        final v = _money(d[k], key: k);
        if (v != null) {
          any = true;
          cash ??= v;
          break;
        }
      }
    }
  }

  if (!any) return null;

  if (total == null && (promo != null || cash != null)) {
    total = (promo ?? 0) + (cash ?? 0);
  }

  return DriverBalanceSnapshot(totalSom: total, promoSom: promo, cashSom: cash);
}

double? _money(dynamic v, {String? key}) {
  if (v == null) return null;
  double? n;
  if (v is num) {
    n = v.toDouble();
  } else {
    final s = v.toString().trim().replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');
    n = double.tryParse(s);
  }
  if (n == null) return null;
  final k = (key ?? '').toLowerCase();
  if (k.contains('tiyin') || k.contains('tiyn')) {
    return n / 100.0;
  }
  return n;
}
