import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/core/geo/lat_lng.dart';
import 'package:yetti_qanot_driver/core/localization/arb/app_localizations.dart';
import 'package:yetti_qanot_driver/features/home/presentation/widgets/osm_trip_map.dart';
import 'package:yetti_qanot_driver/features/trip/domain/trip_request.dart';
import 'package:yetti_qanot_driver/features/trip/domain/trip_status.dart';
import 'package:yetti_qanot_driver/features/trip/presentation/trip_state.dart';

/// The driver must always be at the centre of the map: after the initial fit
/// and after every position update, even while still inside the visible area.
void main() {
  final trip = TripState(
    status: TripStatus.waiting,
    activeRequest: const TripRequest(
      id: 'r1',
      tripId: 't1',
      pickup: MapLatLng(41.3200, 69.2600),
    ),
  );

  Widget harness(MapLatLng me) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: OsmTripMap(me: me, trip: trip),
          ),
        ),
      );

  MapCamera cameraOf(WidgetTester t) =>
      MapCamera.of(t.element(find.byType(TileLayer)));

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
  }

  testWidgets('driver stays centred after the initial fit and on every fix',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(harness(const MapLatLng(41.3000, 69.2400)));
    await settle(tester);
    var c = cameraOf(tester).center;
    expect(c.latitude, closeTo(41.3000, 1e-4));
    expect(c.longitude, closeTo(69.2400, 1e-4));

    // A small move (~120 m) that stays well inside the visible area.
    await tester.pumpWidget(harness(const MapLatLng(41.3010, 69.2410)));
    await settle(tester);
    c = cameraOf(tester).center;
    expect(c.latitude, closeTo(41.3010, 1e-4));
    expect(c.longitude, closeTo(69.2410, 1e-4));

    // Zoom is preserved while following.
    final zoomBefore = cameraOf(tester).zoom;
    await tester.pumpWidget(harness(const MapLatLng(41.3030, 69.2430)));
    await settle(tester);
    expect(cameraOf(tester).zoom, closeTo(zoomBefore, 1e-6));
    c = cameraOf(tester).center;
    expect(c.latitude, closeTo(41.3030, 1e-4));
  });
}
