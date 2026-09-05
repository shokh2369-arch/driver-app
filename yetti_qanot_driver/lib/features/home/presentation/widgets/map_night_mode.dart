/// Time-based night mode for the trip map.
///
/// Drivers work in Uzbekistan, so the schedule is fixed to Tashkent time
/// (UTC+5, no daylight saving) regardless of the phone's time zone setting.
/// Night tiles run from [nightStartHour]:00 until [nightEndHour]:00.
library;

const int tashkentUtcOffsetHours = 5;

/// Local Tashkent wall-clock time for [utc].
DateTime tashkentTime(DateTime utc) =>
    utc.toUtc().add(const Duration(hours: tashkentUtcOffsetHours));

/// True when the map should use night tiles at [now] (any time zone).
bool isMapNight(DateTime now, {int nightStartHour = 17, int nightEndHour = 6}) {
  final hour = tashkentTime(now).hour;
  if (nightStartHour == nightEndHour) return false;
  if (nightStartHour > nightEndHour) {
    // Window wraps midnight, e.g. 17 → 6.
    return hour >= nightStartHour || hour < nightEndHour;
  }
  return hour >= nightStartHour && hour < nightEndHour;
}

/// Next instant (UTC) at which [isMapNight] changes value after [now].
DateTime nextMapNightChange(
  DateTime now, {
  int nightStartHour = 17,
  int nightEndHour = 6,
}) {
  final local = tashkentTime(now);
  final today = DateTime.utc(local.year, local.month, local.day);
  DateTime atHour(DateTime day, int h) => day.add(Duration(hours: h));
  final candidates = <DateTime>[
    atHour(today, nightStartHour),
    atHour(today, nightEndHour),
    atHour(today.add(const Duration(days: 1)), nightStartHour),
    atHour(today.add(const Duration(days: 1)), nightEndHour),
  ]..sort();
  final localNow = DateTime.utc(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
  );
  final next = candidates.firstWhere((c) => c.isAfter(localNow));
  // Back to a real UTC instant.
  return next.subtract(const Duration(hours: tashkentUtcOffsetHours));
}
