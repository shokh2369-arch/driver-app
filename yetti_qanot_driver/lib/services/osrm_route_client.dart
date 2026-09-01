import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'config.dart';

/// Fetches a **road-following** polyline (car profile) via a public OSRM-compatible API.
///
/// Default host is the [Project OSRM demo](https://github.com/Project-OSRM/osrm-backend/wiki/Demo-server)
/// — fair-use only; production should use `--dart-define=OSRM_ROUTING_BASE_URL=…` (self-hosted or allowed host).
class OsrmRouteClient {
  OsrmRouteClient._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
      headers: const {'User-Agent': 'YettiQanotDriver/1.0 (routing)'},
    ),
  );

  /// Returns **lat, lng** points along drivable roads, or `null` to fall back to a straight line.
  static Future<List<LatLng>?> fetchDrivingRoute(
    LatLng from,
    LatLng to, {
    CancelToken? cancelToken,
  }) async {
    final base = AppConfig.osrmRoutingBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return null;

    final coord =
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final uri = Uri.parse('$base/route/v1/driving/$coord').replace(
      queryParameters: const {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'false',
      },
    );

    try {
      final res = await _dio.get<Map<String, dynamic>>(uri.toString(), cancelToken: cancelToken);
      final data = res.data;
      if (data == null) return null;

      final routes = data['routes'];
      if (routes is! List || routes.isEmpty) return null;

      final first = routes.first;
      if (first is! Map<String, dynamic>) return null;
      final geometry = first['geometry'];
      if (geometry is! Map<String, dynamic>) return null;

      final coords = geometry['coordinates'];
      if (coords is! List) return null;

      final out = <LatLng>[];
      for (final c in coords) {
        if (c is List && c.length >= 2) {
          final lon = (c[0] as num).toDouble();
          final lat = (c[1] as num).toDouble();
          out.add(LatLng(lat, lon));
        }
      }
      if (out.length < 2) return null;
      return out;
    } catch (e, st) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        return null;
      }
      if (kDebugMode) {
        debugPrint('[yetti_driver] OSRM route request failed: $e\n$st');
      }
      return null;
    }
  }
}
