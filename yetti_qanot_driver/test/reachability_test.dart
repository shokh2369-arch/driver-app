import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yetti_qanot_driver/features/auth/presentation/reachability_controller.dart';
import 'package:yetti_qanot_driver/services/reachability.dart';

/// Service double: overrides the network calls so the controller's state machine is testable
/// without touching Dio or DNS.
class _FakeService extends ReachabilityService {
  _FakeService(this._result, {bool internet = true})
      : _internet = internet,
        super();

  Reachability _result;
  final bool _internet;
  int classifyCalls = 0;

  void set(Reachability r) => _result = r;

  @override
  Future<Reachability> classify() async {
    classifyCalls++;
    return _result;
  }

  @override
  Future<bool> internetUp() async => _internet;
}

ProviderContainer _container(_FakeService fake) {
  final c = ProviderContainer(
    overrides: [reachabilityServiceProvider.overrideWithValue(fake)],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  group('classifyReachability (pure)', () {
    test('backend ok → reachable (internet irrelevant)', () {
      expect(classifyReachability(backendOk: true, internetOk: false), Reachability.reachable);
      expect(classifyReachability(backendOk: true, internetOk: true), Reachability.reachable);
    });
    test('backend down + internet up → backendDown (the regional block)', () {
      expect(classifyReachability(backendOk: false, internetOk: true), Reachability.backendDown);
    });
    test('backend down + no internet → offline', () {
      expect(classifyReachability(backendOk: false, internetOk: false), Reachability.offline);
    });
  });

  group('ReachabilityController', () {
    test('does not auto-probe on start', () async {
      final fake = _FakeService(Reachability.backendDown);
      final c = _container(fake);
      c.read(reachabilityProvider);
      await _settle();
      expect(c.read(reachabilityProvider).status, Reachability.unknown);
      expect(fake.classifyCalls, 0);
    });

    test('probe marks offline when internet is down', () async {
      final fake = _FakeService(Reachability.offline, internet: false);
      final c = _container(fake);
      await c.read(reachabilityProvider.notifier).probe();
      expect(c.read(reachabilityProvider).status, Reachability.offline);
      expect(c.read(reachabilityProvider).unreachable, isTrue);
    });

    test('retryNow re-probes and returns to unknown when internet is up', () async {
      final fake = _FakeService(Reachability.offline, internet: true);
      final c = _container(fake);
      await c.read(reachabilityProvider.notifier).retryNow();
      final s = c.read(reachabilityProvider);
      expect(s.status, Reachability.unknown);
      expect(s.unreachable, isFalse);
      expect(s.canAttempt, isTrue);
    });

    test('single-flight: overlapping probes run once', () async {
      final fake = _FakeService(Reachability.backendDown);
      final c = _container(fake);
      final n = c.read(reachabilityProvider.notifier);
      final before = fake.classifyCalls;
      await Future.wait([n.probe(), n.probe(), n.probe()]);
      expect(fake.classifyCalls, before);
    });

    test('markReachable clears the banner without a network probe', () async {
      final fake = _FakeService(Reachability.backendDown, internet: false);
      final c = _container(fake);
      await c.read(reachabilityProvider.notifier).probe();
      expect(c.read(reachabilityProvider).unreachable, isTrue);
      final before = fake.classifyCalls;

      c.read(reachabilityProvider.notifier).markReachable();
      expect(c.read(reachabilityProvider).status, Reachability.reachable);
      expect(fake.classifyCalls, before);
    });
  });

  group('ReachabilityService plumbing', () {
    test('healthUrl appends /health without a double slash', () {
      expect(ReachabilityService.healthUrl.endsWith('/health'), isTrue);
      expect(ReachabilityService.healthUrl.contains('//health'), isFalse);
    });
    test('internetUp uses the injected probe', () async {
      expect(await ReachabilityService(internetProbe: () async => false).internetUp(), isFalse);
      expect(await ReachabilityService(internetProbe: () async => true).internetUp(), isTrue);
    });
  });
}
