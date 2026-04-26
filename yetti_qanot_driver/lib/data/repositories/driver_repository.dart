import '../../services/driver_api_client.dart';

/// Thin facade over [DriverApiClient] — driver bot HTTP parity only.
class DriverRepository {
  DriverRepository(this._api);

  final DriverApiClient _api;

  Future<String> getHealth() => _api.getHealth();

  Future<Map<String, dynamic>> getAvailableRequests() => _api.getAvailableRequests();

  Future<Map<String, dynamic>> getDriverPromoProgram() => _api.getDriverPromoProgram();

  Future<Map<String, dynamic>> getDriverReferralStatus() => _api.getDriverReferralStatus();

  Future<String?> getDriverReferralLink() => _api.getDriverReferralLink();

  /// Only when `DRIVER_WALLET_HTTP_PATH` is a real documented GET on the same host.
  Future<Map<String, dynamic>> getRelativeJson(String path) => _api.getRelativeJson(path);

  Future<Map<String, dynamic>> acceptRequest({String? requestId, String? tripId}) =>
      _api.acceptRequest(requestId: requestId, tripId: tripId);

  Future<void> postDriverLocation({
    required double lat,
    required double lng,
    double? accuracy,
    DateTime? timestamp,
    bool useWebLocationPath = false,
  }) =>
      _api.postDriverLocation(
        lat: lat,
        lng: lng,
        accuracy: accuracy,
        timestamp: timestamp,
        useWebLocationPath: useWebLocationPath,
      );

  Future<void> postDriverOffline() => _api.postDriverOffline();

  Future<void> postTripArrived(
    String tripId, {
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? timestamp,
  }) =>
      _api.postTripArrived(
        tripId,
        lat: lat,
        lng: lng,
        accuracy: accuracy,
        timestamp: timestamp,
      );

  Future<void> postTripStart(
    String tripId, {
    double? lat,
    double? lng,
    double? accuracy,
    DateTime? timestamp,
  }) =>
      _api.postTripStart(
        tripId,
        lat: lat,
        lng: lng,
        accuracy: accuracy,
        timestamp: timestamp,
      );

  Future<void> postTripFinish(String tripId) => _api.postTripFinish(tripId);

  Future<void> postTripCancelDriver(String tripId) => _api.postTripCancelDriver(tripId);

  Future<Map<String, dynamic>> getTrip(String tripId) => _api.getTrip(tripId);

  Future<Map<String, dynamic>> getLegalActive() => _api.getLegalActive();

  Future<void> postLegalAccept([Map<String, dynamic>? body]) => _api.postLegalAccept(body);
}
