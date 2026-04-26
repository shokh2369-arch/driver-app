import 'package:yetti_qanot_driver/features/trip/domain/driver_dashboard_stats.dart';

/// Best-effort parse for promo / referral JSON (snake_case keys vary by backend).
DriverDashboardStats? parseDriverDashboardStats(Map<String, dynamic> json) {
  final flat = _flattenData(json);
  final b = _firstString(flat, const [
    'referral_count',
    'referrals',
    'referrals_total',
    'bookmark_count',
    'saved_count',
  ]);
  final c = _firstString(flat, const [
    'online_hours',
    'hours_online',
    'shift_minutes',
    'active_minutes',
    'minutes_online',
  ]);
  final p = _firstString(flat, const [
    'trips_today',
    'completed_trips',
    'rides',
    'rides_count',
    'passengers',
  ]);
  if (b == null && c == null && p == null) return null;
  return DriverDashboardStats(bookmark: b, clock: c, person: p);
}

Map<String, dynamic> _flattenData(Map<String, dynamic> json) {
  final out = Map<String, dynamic>.from(json);
  final data = json['data'];
  if (data is Map) {
    for (final e in data.entries) {
      out.putIfAbsent(e.key.toString(), () => e.value);
    }
  }
  return out;
}

String? _firstString(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    if (v is num) return v.toString();
    final s = v.toString().trim();
    if (s.isNotEmpty) return s;
  }
  return null;
}
