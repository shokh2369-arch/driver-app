/// Dashboard metrics from `GET /driver/promo-program` and/or `GET /driver/referral-status`.
class DriverDashboardStats {
  const DriverDashboardStats({
    this.bookmark,
    this.clock,
    this.person,
  });

  final String? bookmark;
  final String? clock;
  final String? person;

  String get displayBookmark => bookmark ?? '0';
  String get displayClock => clock ?? '0';
  String get displayPerson => person ?? '0';
}

DriverDashboardStats mergeDashboardStats(DriverDashboardStats? a, DriverDashboardStats? b) {
  if (a == null) return b ?? const DriverDashboardStats();
  if (b == null) return a;
  return DriverDashboardStats(
    bookmark: b.bookmark ?? a.bookmark,
    clock: b.clock ?? a.clock,
    person: b.person ?? a.person,
  );
}
