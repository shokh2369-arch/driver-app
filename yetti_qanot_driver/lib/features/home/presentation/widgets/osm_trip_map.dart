import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/geo/lat_lng.dart' show MapLatLng, isValidGeoDegrees, isValidMapLatLng;
import '../../../../core/theme/ios_tokens.dart';
import '../../../trip/domain/trip_status.dart';
import '../../../trip/presentation/trip_state.dart';
import '../../../trip/presentation/widgets/distance_utils.dart';
import '../../../../services/osrm_route_client.dart';

/// OpenStreetMap raster tiles via [flutter_map] (Leaflet-style driver map).
///
/// Pickup: OSRM driver → pickup (**blue**). Yo‘nalshsiz taxi: safar boshlangach manzilga yo‘l
/// chizilmaydi; faqat **yurilgan GPS izi** (**#16a34a**, weight 7) va haydovchi belgisi.
/// Kamera: dastlabki fit, keyin haydovchini kuzatish.
class OsmTripMap extends StatefulWidget {
  const OsmTripMap({
    super.key,
    required this.me,
    required this.trip,
    this.bottomOverlayInset = 0,
    this.carBearingDegrees = 0,
  });

  final MapLatLng? me;
  final TripState trip;
  final double bottomOverlayInset;
  final double carBearingDegrees;

  @override
  State<OsmTripMap> createState() => _OsmTripMapState();
}

class _OsmTripMapState extends State<OsmTripMap> {
  static final LatLng _defaultCenter = LatLng(41.311081, 69.240562);

  final MapController _mapController = MapController();

  List<LatLng>? _roadRoute;
  CancelToken? _routeCancel;
  int _routeGen = 0;

  String? _routeTripSignature;
  DateTime? _lastRouteFetchTime;

  /// GPS trail while [TripStatus.started] (mini-app green path).
  List<LatLng> _drivenPath = [];
  LatLng? _lastDrivenAnchor;
  String? _pathTripSig;

  bool _didInitialFit = false;

  LatLng? _latLngFromMap(MapLatLng? p) {
    if (p == null || !isValidMapLatLng(p)) return null;
    return LatLng(p.latitude, p.longitude);
  }

  bool _validLm(LatLng p) => isValidGeoDegrees(p.latitude, p.longitude);

  List<LatLng> _onlyFiniteCoords(Iterable<LatLng> pts) =>
      pts.where(_validLm).toList(growable: false);

  double _km(LatLng a, LatLng b) {
    if (!_validLm(a) || !_validLm(b)) return double.infinity;
    return haversineKm(MapLatLng(a.latitude, a.longitude), MapLatLng(b.latitude, b.longitude));
  }

  String? _routeSignature() {
    final req = widget.trip.activeRequest;
    if (req == null) return null;
    return '${req.id}_${widget.trip.status.name}';
  }

  List<LatLng>? _straightFallback() {
    if (widget.trip.status == TripStatus.started) return null;
    final me = _latLngFromMap(widget.me);
    final req = widget.trip.activeRequest;
    final pu = req != null ? _latLngFromMap(req.pickup) : null;
    if (me == null || pu == null) return null;
    return [me, pu];
  }

  void _refreshRoadRoute() {
    final me = widget.me;
    final req = widget.trip.activeRequest;

    if (widget.trip.status == TripStatus.started) {
      _routeCancel?.cancel();
      _routeCancel = null;
      _routeTripSignature = null;
      _lastRouteFetchTime = null;
      if (_roadRoute != null && mounted) {
        setState(() => _roadRoute = null);
      } else {
        _roadRoute = null;
      }
      return;
    }

    if (me == null || req == null) {
      _routeCancel?.cancel();
      _routeCancel = null;
      _routeTripSignature = null;
      _lastRouteFetchTime = null;
      if (_roadRoute != null && mounted) {
        setState(() => _roadRoute = null);
      } else {
        _roadRoute = null;
      }
      return;
    }

    final sig = _routeSignature();
    final tripChanged = sig != null && sig != _routeTripSignature;
    if (tripChanged) {
      _routeTripSignature = sig;
      _lastRouteFetchTime = null;
      if (_roadRoute != null && mounted) {
        setState(() => _roadRoute = null);
      } else {
        _roadRoute = null;
      }
    } else if (_lastRouteFetchTime != null &&
        DateTime.now().difference(_lastRouteFetchTime!) < const Duration(seconds: 10)) {
      return;
    }
    _lastRouteFetchTime = DateTime.now();

    final meLm = _latLngFromMap(me);
    final targetLm = _latLngFromMap(req.pickup);
    if (meLm == null || targetLm == null) {
      if (_roadRoute != null && mounted) {
        setState(() => _roadRoute = null);
      } else {
        _roadRoute = null;
      }
      return;
    }

    final gen = ++_routeGen;
    _routeCancel?.cancel();
    _routeCancel = CancelToken();
    final token = _routeCancel!;

    OsrmRouteClient.fetchDrivingRoute(
      meLm,
      targetLm,
      cancelToken: token,
    ).then((pts) {
      if (!mounted || gen != _routeGen) return;
      final cleaned = pts == null ? null : _onlyFiniteCoords(pts);
      setState(() => _roadRoute = (cleaned != null && cleaned.length >= 2) ? cleaned : null);
    });
  }

  CameraFit? _fitForTrip() {
    final req = widget.trip.activeRequest;
    final tripInProgress = widget.trip.status == TripStatus.started;

    if (tripInProgress) {
      if (req == null) return null;
      final meLm = _latLngFromMap(widget.me);
      final pts = <LatLng>[
        if (_drivenPath.length >= 2) ..._onlyFiniteCoords(_drivenPath),
        if (_drivenPath.length < 2) ?meLm,
      ];
      // `CameraFit.coordinates` with 0/1 points can produce invalid camera state on some platforms.
      if (pts.length < 2) return null;
      return CameraFit.coordinates(
        coordinates: pts,
        padding: EdgeInsets.fromLTRB(48, 120, 48, 180 + widget.bottomOverlayInset),
        maxZoom: 17,
      );
    }

    if (req == null) return null;
    final remote = widget.trip.remoteLiveLocation;
    final route = _roadRoute;
    final meLm = _latLngFromMap(widget.me);
    final pickupLm = _latLngFromMap(req.pickup);
    final remoteLm = _latLngFromMap(remote);
    final pts = <LatLng>[
      if (route != null && route.isNotEmpty) ..._onlyFiniteCoords(route),
      if (route == null || route.isEmpty) ...[?meLm, ?pickupLm],
      ?remoteLm,
    ];
    final validPts = _onlyFiniteCoords(pts);
    if (validPts.length < 2) return null;
    return CameraFit.coordinates(
      coordinates: validPts,
      padding: EdgeInsets.fromLTRB(48, 120, 48, 180 + widget.bottomOverlayInset),
      maxZoom: 17,
    );
  }

  LatLng _fallbackCenterForTrip() {
    final meLm = _latLngFromMap(widget.me);
    if (meLm != null) return meLm;
    final req = widget.trip.activeRequest;
    final pickupLm = req != null ? _latLngFromMap(req.pickup) : null;
    if (pickupLm != null) return pickupLm;
    return _defaultCenter;
  }

  void _safeFitCamera(CameraFit fit) {
    // `flutter_map` can crash if camera center becomes NaN; guard with a post-check fallback.
    try {
      _mapController.fitCamera(fit);
    } catch (_) {
      _mapController.move(_fallbackCenterForTrip(), _mapController.camera.zoom.clamp(3.0, 19.0));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = _mapController.camera.center;
      if (!_validLm(c)) {
        _mapController.move(_fallbackCenterForTrip(), _mapController.camera.zoom.clamp(3.0, 19.0));
      }
    });
  }

  void _resetPathForTrip() {
    _drivenPath = [];
    _lastDrivenAnchor = null;
    _pathTripSig = null;
  }

  /// Returns true if the driven polyline changed.
  bool _appendDrivenPath(LatLng p) {
    if (!_validLm(p)) return false;
    if (widget.trip.status != TripStatus.started) return false;
    final sig = '${widget.trip.activeRequest?.id}_started';
    if (_pathTripSig != sig) {
      _pathTripSig = sig;
      _drivenPath = [p];
      _lastDrivenAnchor = p;
      return true;
    }
    final anchor = _lastDrivenAnchor ?? _drivenPath.last;
    if (_km(anchor, p) >= 0.005) {
      _drivenPath = [..._drivenPath, p];
      _lastDrivenAnchor = p;
      return true;
    }
    return false;
  }

  void _followDriver(LatLng driver) {
    if (!_validLm(driver)) return;
    if (!mounted) return;
    final cam = _mapController.camera;
    if (!_validLm(cam.center)) {
      _mapController.move(driver, cam.zoom.clamp(3.0, 19.0));
      return;
    }
    final bounds = cam.visibleBounds;
    final tripInProgress = widget.trip.status == TripStatus.started;
    final req = widget.trip.activeRequest;

    if (bounds.contains(driver)) {
      _mapController.move(driver, cam.zoom);
      return;
    }
    if (tripInProgress) {
      _mapController.move(driver, cam.zoom);
      return;
    }
    if (req != null) {
      final pickupLm = _latLngFromMap(req.pickup);
      if (pickupLm != null && _validLm(pickupLm)) {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: [driver, pickupLm],
            padding: const EdgeInsets.fromLTRB(80, 40, 80, 40),
            maxZoom: 16,
          ),
        );
      } else {
        _mapController.move(driver, cam.zoom);
      }
    } else {
      _mapController.move(driver, cam.zoom);
    }
  }

  void _runInitialFitIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_didInitialFit) return;
      final fit = _fitForTrip();
      if (fit != null) {
        _safeFitCamera(fit);
        _didInitialFit = true;
      } else {
        // Always keep camera in a valid state.
        _mapController.move(_fallbackCenterForTrip(), _mapController.camera.zoom.clamp(3.0, 19.0));
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshRoadRoute();
    _runInitialFitIfNeeded();
  }

  @override
  void dispose() {
    _routeCancel?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OsmTripMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newId = widget.trip.activeRequest?.id;
    final oldId = oldWidget.trip.activeRequest?.id;
    final req = widget.trip.activeRequest;
    final oldReq = oldWidget.trip.activeRequest;
    var coordsChanged = false;
    if (req != null && oldReq != null) {
      coordsChanged =
          req.pickup.latitude != oldReq.pickup.latitude ||
          req.pickup.longitude != oldReq.pickup.longitude ||
          req.destination.latitude != oldReq.destination.latitude ||
          req.destination.longitude != oldReq.destination.longitude;
    }
    final tripPairChanged = (req == null) != (oldReq == null);
    final statusChanged = widget.trip.status != oldWidget.trip.status;
    final meChanged = widget.me?.latitude != oldWidget.me?.latitude ||
        widget.me?.longitude != oldWidget.me?.longitude;

    if (newId != oldId || coordsChanged || tripPairChanged || statusChanged) {
      _resetPathForTrip();
      _didInitialFit = false;
    }

    if (newId != oldId || coordsChanged || tripPairChanged || statusChanged || meChanged) {
      _refreshRoadRoute();
    }

    if (widget.trip.status == TripStatus.started && widget.me != null && meChanged) {
      final meLm = _latLngFromMap(widget.me);
      if (meLm != null) {
        final added = _appendDrivenPath(meLm);
        if (added) {
          setState(() {});
        }
      }
    }

    if (newId != oldId || tripPairChanged || statusChanged) {
      _runInitialFitIfNeeded();
    } else if (meChanged && widget.me != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.me == null) return;
        final meLm = _latLngFromMap(widget.me);
        if (meLm == null) return;
        if (!_didInitialFit) {
          final fit = _fitForTrip();
          if (fit != null) {
            _safeFitCamera(fit);
            _didInitialFit = true;
          } else {
            _mapController.move(_fallbackCenterForTrip(), _mapController.camera.zoom.clamp(3.0, 19.0));
          }
        } else {
          _followDriver(meLm);
        }
      });
    }
  }

  Future<void> _recenterOnDriver() async {
    final meLm = _latLngFromMap(widget.me);
    if (meLm == null) return;
    _mapController.move(meLm, _mapController.camera.zoom);
  }

  LatLng _safeCameraCenter() {
    final c = _mapController.camera.center;
    return _validLm(c) ? c : _defaultCenter;
  }

  void _zoomIn() {
    final c = _mapController.camera;
    _mapController.move(_safeCameraCenter(), (c.zoom + 1).clamp(3.0, 19.0));
  }

  void _zoomOut() {
    final c = _mapController.camera;
    _mapController.move(_safeCameraCenter(), (c.zoom - 1).clamp(3.0, 19.0));
  }

  Future<void> _openNavigation() async {
    final me = widget.me;
    final req = widget.trip.activeRequest;
    if (me == null || req == null) return;

    final target = req.pickup;

    final uri = Uri.parse(
      'https://www.openstreetmap.org/directions?engine=fossgis_osrm_car'
      '&route=${me.latitude}%2C${me.longitude}%3B${target.latitude}%2C${target.longitude}',
    );

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = widget.me;
    final req = widget.trip.activeRequest;
    final remote = widget.trip.remoteLiveLocation;
    final tripInProgress = widget.trip.status == TripStatus.started;

    final initialCenter = _latLngFromMap(me) ??
        (req != null ? _latLngFromMap(req.pickup) : null) ??
        _defaultCenter;

    final straightFallback = _straightFallback();
    final rawRoute = (_roadRoute != null && _roadRoute!.length >= 2)
        ? _roadRoute!
        : (straightFallback ?? <LatLng>[]);
    final routePoints = _onlyFiniteCoords(rawRoute);

    final drivenSeg = _onlyFiniteCoords(_drivenPath);

    final polylines = <Polyline<Object>>[
      if (!tripInProgress && routePoints.length >= 2)
        Polyline(
          points: routePoints,
          color: const Color(0xFF1A73E8),
          strokeWidth: 5,
        ),
      if (tripInProgress && drivenSeg.length >= 2)
        Polyline(
          points: drivenSeg,
          color: const Color(0xFF16A34A),
          strokeWidth: 7,
        ),
    ];

    final br = widget.carBearingDegrees;
    final bearingRad = (br.isFinite ? br : 0.0) * math.pi / 180.0;

    // Pickup / remote first; driver taxi **last** so it paints on top near pickup (flutter_map has no z-index).
    final pickupLm = req != null ? _latLngFromMap(req.pickup) : null;
    final remoteLm = remote != null ? _latLngFromMap(remote) : null;
    final meLm = _latLngFromMap(me);

    final markers = <Marker>[
      // If location permission is not granted (web), show a placeholder taxi at the initial center (under pickup pin).
      if (meLm == null)
        Marker(
          width: 52,
          height: 52,
          point: initialCenter,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFFFC107).withValues(alpha: 0.72),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 3),
              boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
            ),
            child: Icon(Icons.local_taxi, color: Colors.black.withValues(alpha: 0.75), size: 30),
          ),
        ),
      if (remote != null && !tripInProgress && remoteLm != null)
        Marker(
          width: 40,
          height: 40,
          point: remoteLm,
          child: _MapPin(color: Colors.deepPurple, icon: Icons.near_me),
        ),
      if (req != null && !tripInProgress && pickupLm != null)
        Marker(
          width: 42,
          height: 42,
          point: pickupLm,
          child: _MapPin(color: Colors.lightBlue.shade400, icon: Icons.person_pin_circle),
        ),
      if (meLm != null)
        Marker(
          width: 52,
          height: 52,
          point: meLm,
          child: Transform.rotate(
            angle: bearingRad,
            alignment: Alignment.center,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFFC107),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
              ),
              child: const Icon(Icons.local_taxi, color: Colors.black87, size: 30),
            ),
          ),
        ),
    ];

    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: 14,
            backgroundColor: theme.colorScheme.surface,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'YettiQanotDriver/1.0',
              maxNativeZoom: 19,
            ),
            PolylineLayer(polylines: polylines),
            MarkerLayer(markers: markers),
            SimpleAttributionWidget(
              alignment: Alignment.bottomLeft,
              backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.85),
              source: Text(
                '© OSM · © CARTO · Route OSRM',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
              onTap: () => launchUrl(Uri.parse('https://carto.com/attribution')),
            ),
          ],
        ),
        Positioned(
          right: 12,
          bottom: 24 + widget.bottomOverlayInset,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RoundFab(
                  tooltip: 'Zoom in',
                  icon: Icons.add,
                  onPressed: _zoomIn,
                ),
                const SizedBox(height: 6),
                _RoundFab(
                  tooltip: 'Zoom out',
                  icon: Icons.remove,
                  onPressed: _zoomOut,
                ),
                const SizedBox(height: 12),
                _RoundFab(
                  tooltip: 'Center',
                  icon: Icons.my_location,
                  onPressed: _recenterOnDriver,
                ),
                const SizedBox(height: 12),
                _RoundFab(
                  tooltip: 'Navigate',
                  icon: Icons.explore,
                  onPressed: (me != null && req != null && !tripInProgress) ? _openNavigation : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundFab extends StatelessWidget {
  const _RoundFab({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? IosTokens.darkBackground : theme.colorScheme.surface;
    final iconColor = isDark ? IosTokens.systemBlue : theme.colorScheme.primary;
    return Material(
      elevation: isDark ? 6 : 4,
      shadowColor: Colors.black54,
      shape: const CircleBorder(),
      color: bg,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: iconColor),
      ),
    );
  }
}

class _MapPin extends StatelessWidget {
  const _MapPin({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
      ),
      child: Icon(icon, color: Colors.white, size: 18),
    );
  }
}
