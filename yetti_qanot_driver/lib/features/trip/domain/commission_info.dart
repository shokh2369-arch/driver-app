/// The commission the platform takes from each completed trip, as reported by the backend
/// (`commission_percent` + `commission_charged` on `GET /driver/available-requests`).
///
/// Deducted from the driver's wallet (promo balance first, then cash), so the driver reads
/// this against their balance — it must be the real, current, admin-set value, never a
/// guess. "Unknown" (backend didn't send it / not loaded yet) is represented by a **null**
/// [CommissionInfo], not by a fabricated rate.
class CommissionInfo {
  const CommissionInfo({required this.charged, required this.percent});

  /// Whether commission is actually taken right now (admin can switch it off).
  final bool charged;

  /// Integer percentage taken from each order's fare (0–100).
  final int percent;

  /// True when no commission is taken — deliberately switched off, or 0%. Both are
  /// legitimate settings and must read as "no commission", not "0%".
  bool get isOff => !charged || percent <= 0;

  @override
  bool operator ==(Object other) =>
      other is CommissionInfo &&
      other.charged == charged &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(charged, percent);
}
