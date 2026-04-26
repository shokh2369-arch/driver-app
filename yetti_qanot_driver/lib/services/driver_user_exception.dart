/// Thrown when the API failed in a way we can show to the driver (no secrets).
class DriverUserException implements Exception {
  DriverUserException(this.message, {this.userCode});

  final String message;

  /// Optional stable code for localized UI (e.g. `TRIP_NOT_FOUND` → trip plan not found string).
  final String? userCode;

  @override
  String toString() => message;
}
