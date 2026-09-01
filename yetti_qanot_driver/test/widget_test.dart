// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:yetti_qanot_driver/app.dart';
import 'package:yetti_qanot_driver/core/storage/storage_providers.dart';
import 'package:yetti_qanot_driver/features/auth/presentation/reachability_controller.dart';
import 'package:yetti_qanot_driver/services/reachability.dart';

/// Boot lands on the login screen, which probes reachability. Stub it to "reachable" so the
/// test does no real network I/O and schedules no auto-reprobe timer.
class _ReachableService extends ReachabilityService {
  _ReachableService() : super();
  @override
  Future<Reachability> classify() async => Reachability.reachable;
  @override
  Future<bool> internetUp() async => true;
}

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          reachabilityServiceProvider.overrideWithValue(_ReachableService()),
        ],
        child: const YettiQanotApp(),
      ),
    );

    await tester.pump();
  });
}
