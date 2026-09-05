import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/geo/lat_lng.dart'
    show MapLatLng, isValidGeoDegrees, isValidMapLatLng;
import '../../../../core/localization/arb/app_localizations.dart';
import '../../../../core/theme/ios_tokens.dart';
import '../../../trip/domain/trip_status.dart';
import '../../../trip/presentation/trip_state.dart';
import '../../../trip/presentation/widgets/distance_utils.dart';
import '../../../../services/config.dart';
import '../../../../services/osrm_route_client.dart';
import 'map_night_mode.dart';

/// Shared tile HTTP client **without** a retry wrapper: `RetryClient` copies
/// flutter_map's abortable requests and the copies never reach the network, so
/// no tile loads at all. Resilience against the public OSM service's 503 bursts
/// comes from the per-tile [TileLayer.fallbackUrl] instead (a non-200 answer
/// makes flutter_map fetch the same tile from the fallback template).
final http.Client _mapTileHttpClient = http.Client();

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

  /// Logical px — smaller than tile pixels so markers read at “road” scale on the map.
  static const double _carMarkerW = 32;
  static const double _carMarkerH = 53;
  static const double _riderPinW = 32;
  static const double _riderPinH = 42;
  static const double _remoteMarkerSize = 28;

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
  LatLng? _lastFollowed;

  /// Night tiles by Tashkent clock (see `map_night_mode.dart`); re-evaluated at
  /// the next boundary while the map stays open.
  bool _mapNight = isMapNight(
    DateTime.now(),
    nightStartHour: AppConfig.mapNightStartHour,
    nightEndHour: AppConfig.mapNightEndHour,
  );
  Timer? _nightTimer;

  /// One provider per map instance (flutter_map disposes it with the layer).
  late final NetworkTileProvider _tileProvider = NetworkTileProvider(
    httpClient: _mapTileHttpClient,
    silenceExceptions: true,
  );

  /// False until the first tile image has decoded — drives the "map loading"
  /// chip so a slow tile server never reads as a broken black map.
  bool _tilesLoaded = false;

  /// After "fit driver + client" the camera stays put for a few seconds even
  /// though fixes keep arriving; "center on me" or the timeout resumes following.
  DateTime? _followSuspendedUntil;

  /// True while the driver's finger is on the map (drag / pinch). Following
  /// resumes on the next fix after the gesture ends, so the camera never fights
  /// an in-progress gesture.
  bool _userGestureActive = false;

  LatLng? _latLngFromMap(MapLatLng? p) {
    if (p == null || !isValidMapLatLng(p)) return null;
    return LatLng(p.latitude, p.longitude);
  }

  bool _validLm(LatLng p) => isValidGeoDegrees(p.latitude, p.longitude);

  static bool _samePoint(MapLatLng? a, MapLatLng? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.latitude == b.latitude && a.longitude == b.longitude;
  }

  List<LatLng> _onlyFiniteCoords(Iterable<LatLng> pts) =>
      pts.where(_validLm).toList(growable: false);

  double _km(LatLng a, LatLng b) {
    if (!_validLm(a) || !_validLm(b)) return double.infinity;
    return haversineKm(
      MapLatLng(a.latitude, a.longitude),
      MapLatLng(b.latitude, b.longitude),
    );
  }

  String? _routeSignature() {
    final req = widget.trip.activeRequest;
    if (req == null) return null;
    return '${req.id}_${widget.trip.status.name}';
  }

  List<LatLng>? _straightFallback() {
    if (widget.trip.status == TripStatus.started) return null;
    final me = _latLngFromMap(widget.me);
    final pu = _latLngFromMap(widget.trip.activeRequest?.pickup);
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
        DateTime.now().difference(_lastRouteFetchTime!) <
            const Duration(seconds: 10)) {
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

    OsrmRouteClient.fetchDrivingRoute(meLm, targetLm, cancelToken: token).then((
      pts,
    ) {
      if (!mounted || gen != _routeGen) return;
      final cleaned = pts == null ? null : _onlyFiniteCoords(pts);
      setState(
        () => _roadRoute = (cleaned != null && cleaned.length >= 2)
            ? cleaned
            : null,
      );
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
        padding: EdgeInsets.fromLTRB(
          48,
          120,
          48,
          180 + widget.bottomOverlayInset,
        ),
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
      padding: EdgeInsets.fromLTRB(
        48,
        120,
        48,
        180 + widget.bottomOverlayInset,
      ),
      maxZoom: 17,
    );
  }

  LatLng _fallbackCenterForTrip() {
    final meLm = _latLngFromMap(widget.me);
    if (meLm != null) return meLm;
    final pickupLm = _latLngFromMap(widget.trip.activeRequest?.pickup);
    if (pickupLm != null) return pickupLm;
    return _defaultCenter;
  }

  void _safeFitCamera(CameraFit fit) {
    // `flutter_map` can crash if camera center becomes NaN; guard with a post-check fallback.
    try {
      _mapController.fitCamera(fit);
    } catch (_) {
      _mapController.move(
        _fallbackCenterForTrip(),
        _mapController.camera.zoom.clamp(3.0, 19.0),
      );
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = _mapController.camera.center;
      if (!_validLm(c)) {
        _mapController.move(
          _fallbackCenterForTrip(),
          _mapController.camera.zoom.clamp(3.0, 19.0),
        );
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

  /// Keep the driver at the centre of the map on every GPS fix. Zoom is left
  /// as the driver set it; only sub-2 m jitter is ignored.
  void _followDriver(LatLng driver) {
    if (!_validLm(driver)) return;
    if (!mounted || _userGestureActive) return;
    final until = _followSuspendedUntil;
    if (until != null) {
      if (DateTime.now().isBefore(until)) return;
      _followSuspendedUntil = null;
    }
    if (_lastFollowed != null && _km(_lastFollowed!, driver) < 0.002) {
      return;
    }
    _lastFollowed = driver;
    final cam = _mapController.camera;
    _mapController.move(driver, cam.zoom.clamp(3.0, 19.0));
  }

  /// After the initial fit (which only picks a sensible zoom for driver +
  /// pickup), put the driver back in the centre.
  void _centerOnDriverKeepingZoom() {
    final meLm = _latLngFromMap(widget.me);
    if (meLm == null || !_validLm(meLm)) return;
    _lastFollowed = meLm;
    _mapController.move(meLm, _mapController.camera.zoom.clamp(3.0, 19.0));
  }

  void _onMapEvent(MapEvent event) {
    switch (event.source) {
      case MapEventSource.dragStart:
      case MapEventSource.multiFingerGestureStart:
        _userGestureActive = true;
      case MapEventSource.dragEnd:
      case MapEventSource.multiFingerEnd:
        _userGestureActive = false;
      default:
        break;
    }
  }

  void _scheduleNightCheck() {
    _nightTimer?.cancel();
    final now = DateTime.now();
    final next = nextMapNightChange(
      now,
      nightStartHour: AppConfig.mapNightStartHour,
      nightEndHour: AppConfig.mapNightEndHour,
    );
    // +1 s so the check lands on the far side of the boundary.
    final wait = next.difference(now.toUtc()) + const Duration(seconds: 1);
    _nightTimer = Timer(
      wait.isNegative ? const Duration(seconds: 1) : wait,
      () {
        if (!mounted) return;
        final night = isMapNight(
          DateTime.now(),
          nightStartHour: AppConfig.mapNightStartHour,
          nightEndHour: AppConfig.mapNightEndHour,
        );
        if (night != _mapNight) setState(() => _mapNight = night);
        _scheduleNightCheck();
      },
    );
  }

  void _runInitialFitIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_didInitialFit) return;
      final fit = _fitForTrip();
      if (fit != null) {
        _safeFitCamera(fit);
        _didInitialFit = true;
        _centerOnDriverKeepingZoom();
      } else {
        // Always keep camera in a valid state.
        _mapController.move(
          _fallbackCenterForTrip(),
          _mapController.camera.zoom.clamp(3.0, 19.0),
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _scheduleNightCheck();
    _refreshRoadRoute();
    _runInitialFitIfNeeded();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Avoid repeated AssetManifest / asset decode on every marker rebuild.
      precacheImage(const AssetImage('assets/icons/rider_pin.png'), context);
      precacheImage(const AssetImage('assets/icons/driver_car.png'), context);
    });
  }

  @override
  void dispose() {
    _nightTimer?.cancel();
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
          !_samePoint(req.pickup, oldReq.pickup) ||
          !_samePoint(req.destination, oldReq.destination);
    }
    final tripPairChanged = (req == null) != (oldReq == null);
    final statusChanged = widget.trip.status != oldWidget.trip.status;
    final meChanged =
        widget.me?.latitude != oldWidget.me?.latitude ||
        widget.me?.longitude != oldWidget.me?.longitude;

    if (newId != oldId || coordsChanged || tripPairChanged || statusChanged) {
      _resetPathForTrip();
      _didInitialFit = false;
    }

    if (newId != oldId ||
        coordsChanged ||
        tripPairChanged ||
        statusChanged ||
        meChanged) {
      _refreshRoadRoute();
    }

    if (widget.trip.status == TripStatus.started &&
        widget.me != null &&
        meChanged) {
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
            _centerOnDriverKeepingZoom();
          } else {
            _mapController.move(
              _fallbackCenterForTrip(),
              _mapController.camera.zoom.clamp(3.0, 19.0),
            );
          }
        } else {
          _followDriver(meLm);
        }
      });
    }
  }

  Future<void> _recenterOnDriver() async {
    _followSuspendedUntil = null;
    final meLm = _latLngFromMap(widget.me);
    if (meLm == null) return;
    _lastFollowed = meLm;
    _mapController.move(meLm, _mapController.camera.zoom);
  }

  /// Show driver and client (or the whole route) at once; following pauses for a
  /// few seconds so the next GPS fix does not immediately undo the view.
  void _fitDriverAndTarget() {
    final meLm = _latLngFromMap(widget.me);
    final req = widget.trip.activeRequest;
    final tripInProgress = widget.trip.status == TripStatus.started;
    final target = _latLngFromMap(
      tripInProgress
          ? (req?.destination ?? req?.pickup)
          : (req?.pickup ?? req?.destination),
    );
    final route = _roadRoute;
    final pts = <LatLng>[
      if (!tripInProgress && route != null && route.length >= 2)
        ..._onlyFiniteCoords(route),
      ?meLm,
      ?target,
    ];
    final valid = _onlyFiniteCoords(pts);
    if (valid.length < 2) {
      if (valid.length == 1) _mapController.move(valid.first, 15);
      return;
    }
    _followSuspendedUntil = DateTime.now().add(const Duration(seconds: 10));
    _safeFitCamera(
      CameraFit.coordinates(
        coordinates: valid,
        padding: EdgeInsets.fromLTRB(
          56,
          240,
          56,
          120 + widget.bottomOverlayInset,
        ),
        maxZoom: 17,
      ),
    );
  }

  /// Called for every tile widget build; flips [_tilesLoaded] once any tile
  /// image has decoded.
  Widget _tileBuilder(BuildContext context, Widget tileWidget, TileImage tile) {
    if (!_tilesLoaded && tile.loadFinishedAt != null && !tile.loadError) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_tilesLoaded) setState(() => _tilesLoaded = true);
      });
    }
    return tileWidget;
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
    final target = widget.trip.activeRequest?.pickup;
    if (me == null || target == null) return;

    final uri = Uri.parse(
      'https://www.openstreetmap.org/directions?engine=fossgis_osrm_car'
      '&route=${me.latitude}%2C${me.longitude}%3B${target.latitude}%2C${target.longitude}',
    );

    await _launchOrNotify(uri, AppLocalizations.of(context).launch_maps_failed);
  }

  /// `canLaunchUrl` returning false is indistinguishable from a missing package-visibility
  /// entry, so launch directly and surface the failure instead of no-op'ing.
  Future<void> _launchOrNotify(Uri uri, String failureMessage) async {
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[yetti_driver] launchUrl failed for ${uri.host}: $e');
    }
    if (ok || !mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(failureMessage)));
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me;
    final req = widget.trip.activeRequest;
    final remote = widget.trip.remoteLiveLocation;
    final tripInProgress = widget.trip.status == TripStatus.started;

    final initialCenter =
        _latLngFromMap(me) ?? _latLngFromMap(req?.pickup) ?? _defaultCenter;

    final straightFallback = _straightFallback();
    final rawRoute = (_roadRoute != null && _roadRoute!.length >= 2)
        ? _roadRoute!
        : (straightFallback ?? <LatLng>[]);
    final routePoints = _onlyFiniteCoords(rawRoute);

    final drivenSeg = _onlyFiniteCoords(_drivenPath);

    final polylines = <Polyline<Object>>[
      // Dark casing keeps the line readable over light streets and dark tiles alike.
      if (!tripInProgress && routePoints.length >= 2)
        Polyline(
          points: routePoints,
          color: const Color(0xFF2F80ED),
          strokeWidth: 6,
          borderStrokeWidth: 2.5,
          borderColor: const Color(0xCC0B2F6B),
        ),
      if (tripInProgress && drivenSeg.length >= 2)
        Polyline(
          points: drivenSeg,
          color: const Color(0xFF22C55E),
          strokeWidth: 7,
          borderStrokeWidth: 2.5,
          borderColor: const Color(0xCC0F4D2A),
        ),
    ];

    final br = widget.carBearingDegrees;
    final bearingRad = (br.isFinite ? br : 0.0) * math.pi / 180.0;
    final night = _mapNight;

    // Pickup / remote first; driver taxi **last** so it paints on top near pickup (flutter_map has no z-index).
    final pickupLm = _latLngFromMap(req?.pickup);
    final remoteLm = _latLngFromMap(remote);
    final meLm = _latLngFromMap(me);

    final markers = <Marker>[
      // Placeholder driver car at initial center when location permission is not granted (web).
      if (meLm == null)
        Marker(
          width: _carMarkerW,
          height: _carMarkerH,
          point: initialCenter,
          alignment: Alignment.center,
          child: Opacity(
            opacity: 0.72,
            child: Image.asset(
              'assets/icons/driver_car.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      if (remote != null && !tripInProgress && remoteLm != null)
        Marker(
          width: _remoteMarkerSize,
          height: _remoteMarkerSize,
          point: remoteLm,
          child: _MapPin(
            color: Colors.deepPurple,
            icon: Icons.near_me,
            iconSize: 14,
          ),
        ),
      // Rider pickup pin: PNG teardrop with person; anchor the pin tip
      // (bottom-center of the marker) at the geographic point so the pin
      // sticks "up" out of the pickup location.
      if (req != null && !tripInProgress && pickupLm != null) ...[
        Marker(
          width: _riderPinW,
          height: _riderPinH,
          point: pickupLm,
          alignment: Alignment.bottomCenter,
          child: Image.asset(
            'assets/icons/rider_pin.png',
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ],
      // Driver car: top-down PNG rotated by GPS bearing.
      if (meLm != null)
        Marker(
          width: _carMarkerW,
          height: _carMarkerH,
          point: meLm,
          alignment: Alignment.center,
          child: Transform.rotate(
            angle: bearingRad,
            alignment: Alignment.center,
            child: Image.asset(
              'assets/icons/driver_car.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
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
            // Matches the (filtered) tile land colour, so loading never flashes
            // a black hole where the map will be.
            backgroundColor: night ? _darkMapBackground : _lightMapBackground,
            onMapEvent: _onMapEvent,
          ),
          children: [
            _TileTheme(
              dark: night,
              child: TileLayer(
                // OpenStreetMap tile API by default (see AppConfig.mapTileUrlTemplate).
                // flutter_map substitutes its default a/b/c only when `{s}` is present.
                urlTemplate: AppConfig.mapTileUrlTemplate,
                // Per-tile fallback when the primary still fails after the retries.
                fallbackUrl: AppConfig.mapTileFallbackUrlTemplate.isEmpty
                    ? null
                    : AppConfig.mapTileFallbackUrlTemplate,
                // OSM's tile policy requires an identifying User-Agent; flutter_map sends
                // `flutter_map (<this>)`.
                userAgentPackageName: 'com.yettiqanot.driverapp',
                maxNativeZoom: 19,
                keepBuffer: 4,
                panBuffer: 1,
                // Default provider wraps RetryClient — on web, failed tiles (rate-limit /
                // blips) re-request the same `{y}.png` in a tight loop and clog DevTools.
                tileProvider: _tileProvider,
                // Instant display: the fade-in animation could leave freshly loaded
                // tiles undisplayed until the next camera change ("black map on
                // first open" on web).
                tileDisplay: const TileDisplay.instantaneous(),
                tileBuilder: _tileBuilder,
              ),
            ),
            PolylineLayer(polylines: polylines),
            MarkerLayer(markers: markers),
          ],
        ),
        if (!_tilesLoaded)
          Positioned(
            left: 0,
            right: 0,
            bottom: 72 + widget.bottomOverlayInset,
            child: const IgnorePointer(child: Center(child: _MapLoadingChip())),
          ),
        // No on-map attribution badge (product decision). NOTE: the public
        // OpenStreetMap tile servers require visible attribution — keep this
        // removed only with your own / a licensed tile provider
        // (`MAP_TILE_URL_TEMPLATE`, see RELEASE_BUILD.txt).
        Positioned(
          right: 12,
          bottom: 24 + widget.bottomOverlayInset,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Before the trip starts the top cards + expanded panel leave little
                // map; pinch / scroll still zoom, the pill returns when there is room.
                if (widget.bottomOverlayInset < 300) ...[
                  _ZoomPill(onZoomIn: _zoomIn, onZoomOut: _zoomOut),
                  const SizedBox(height: 12),
                ],
                _RoundFab(
                  tooltip: 'Fit',
                  icon: Icons.zoom_out_map_rounded,
                  onPressed: _fitDriverAndTarget,
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
                  onPressed: (me != null && pickupLm != null && !tripInProgress)
                      ? _openNavigation
                      : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// OSM standard-tile land colour (light) and the filtered equivalent (dark).
const Color _lightMapBackground = Color(0xFFF2EFE9);
const Color _darkMapBackground = Color(0xFF12161C);

/// Light OSM tiles → night map: invert, hue-rotate 180° (so water stays blue and
/// roads read light-on-dark), then dim, soften contrast and cool the blacks.
const List<double> _darkTileMatrix = <double>[
  0.407,
  -1.0141,
  -0.1021,
  0.0,
  190.4177,
  -0.3214,
  -0.3244,
  -0.1086,
  0.0,
  202.572,
  -0.3471,
  -1.1651,
  0.6974,
  0.0,
  218.7778,
  0.0,
  0.0,
  0.0,
  1.0,
  0.0,
];

class _TileTheme extends StatelessWidget {
  const _TileTheme({required this.dark, required this.child});

  final bool dark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!dark) return child;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_darkTileMatrix),
      child: child,
    );
  }
}

class _MapLoadingChip extends StatelessWidget {
  const _MapLoadingChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(999),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Xarita yuklanmoqda…',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact +/− control; the main actions get the big round buttons.
class _ZoomPill extends StatelessWidget {
  const _ZoomPill({required this.onZoomIn, required this.onZoomOut});

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? IosTokens.darkBackground : theme.colorScheme.surface;
    final fg = isDark ? IosTokens.systemBlue : theme.colorScheme.primary;
    Widget half(IconData icon, VoidCallback onTap, String tooltip) => Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 40,
          child: Icon(icon, size: 22, color: fg),
        ),
      ),
    );
    return Material(
      elevation: isDark ? 6 : 4,
      shadowColor: Colors.black54,
      color: bg,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          half(Icons.add, onZoomIn, 'Zoom in'),
          Divider(height: 1, thickness: 1, color: fg.withValues(alpha: 0.15)),
          half(Icons.remove, onZoomOut, 'Zoom out'),
        ],
      ),
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
    // 52 px round target: comfortably tappable with one thumb while driving.
    final enabled = onPressed != null;
    return Material(
      elevation: isDark ? 6 : 4,
      shadowColor: Colors.black54,
      shape: const CircleBorder(),
      color: bg,
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(
              icon,
              size: 26,
              color: enabled ? iconColor : iconColor.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapPin extends StatelessWidget {
  const _MapPin({required this.color, required this.icon, this.iconSize = 16});

  final Color color;
  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white,
          width: iconSize >= 16 ? 2 : 1.5,
        ),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
      ),
      padding: EdgeInsets.all(iconSize >= 16 ? 4 : 3),
      child: Icon(icon, color: Colors.white, size: iconSize),
    );
  }
}
