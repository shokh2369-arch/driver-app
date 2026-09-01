/// How a past trip should be summarized in the driver trip history list.
enum DriverTripHistoryKind {
  completed,
  cancelled,
  inProgress,
  unknown,
}

class DriverTripHistoryItem {
  const DriverTripHistoryItem({
    this.tripId,
    required this.kind,
    this.occurredAt,
    this.totalFareSom,
    this.serviceFeeSom,
    this.rawStatus,
  });

  final String? tripId;
  final DriverTripHistoryKind kind;
  final DateTime? occurredAt;

  /// Total trip price in soʻm when the API sends it.
  final double? totalFareSom;

  /// Platform / commission slice in soʻm when present.
  final double? serviceFeeSom;

  /// Original server status string when [kind] is [DriverTripHistoryKind.unknown].
  final String? rawStatus;
}
