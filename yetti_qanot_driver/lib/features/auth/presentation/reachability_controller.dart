import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/config.dart';
import '../../../services/reachability.dart';

/// Cached reachability of the backend, shared across the app.
///
/// We intentionally do **not** probe `/health` anymore. The login flow itself is the source
/// of truth: request/verify responses drive user feedback, while this controller only tracks
/// basic internet reachability for optional UI hints.
class ReachabilityState {
  const ReachabilityState({this.status = Reachability.unknown, this.probing = false});

  final Reachability status;

  /// A probe is in flight — the banner can show a spinner instead of the retry button.
  final bool probing;

  /// Backend is confirmed unreachable (either backend-down or fully offline). Drives the
  /// persistent banner + the disabled "Kod yuborish" button.
  bool get unreachable =>
      status == Reachability.backendDown || status == Reachability.offline;

  /// Before we know (or once reachable) the driver may attempt a call — never block on
  /// [Reachability.unknown], only on a *confirmed* failure.
  bool get canAttempt => !unreachable;

  ReachabilityState copyWith({Reachability? status, bool? probing}) => ReachabilityState(
        status: status ?? this.status,
        probing: probing ?? this.probing,
      );

  @override
  bool operator ==(Object other) =>
      other is ReachabilityState && other.status == status && other.probing == probing;

  @override
  int get hashCode => Object.hash(status, probing);
}

final reachabilityServiceProvider =
    Provider<ReachabilityService>((ref) {
  final svc = ReachabilityService();
  ref.onDispose(svc.dispose);
  return svc;
});

final reachabilityProvider =
    NotifierProvider<ReachabilityController, ReachabilityState>(ReachabilityController.new);

class ReachabilityController extends Notifier<ReachabilityState> {
  bool _inFlight = false;
  bool _disposed = false;

  @override
  ReachabilityState build() {
    ref.onDispose(() {
      _disposed = true;
    });
    // No startup backend probe: avoid `/health` checks in app.
    return const ReachabilityState();
  }

  /// Single-flight reachability probe. A second call while one is in flight is a no-op
  /// (so a rapid re-entry / tap cannot stack probes).
  Future<void> probe() async {
    if (_inFlight || _disposed) return;
    // No backend configured → treat as reachable so the UI never blocks.
    if (!AppConfig.hasHttpApi) {
      state = const ReachabilityState(status: Reachability.reachable);
      return;
    }
    _inFlight = true;
    state = state.copyWith(probing: true);
    Reachability result = Reachability.unknown;
    try {
      final internetOk = await ref.read(reachabilityServiceProvider).internetUp();
      result = internetOk ? Reachability.unknown : Reachability.offline;
    } catch (_) {
      result = Reachability.unknown;
    }
    _inFlight = false;
    if (_disposed) return;
    state = ReachabilityState(status: result);
  }

  /// Explicit "Qayta urinish" — refresh internet reachability hint.
  Future<void> retryNow() async {
    await probe();
  }

  /// A real backend call unexpectedly succeeded — clear the banner without waiting for a probe.
  void markReachable() {
    if (!_disposed && state.status != Reachability.reachable) {
      state = const ReachabilityState(status: Reachability.reachable);
    }
  }

  /// A real backend call failed with a network error — refresh the banner. Cheap because it
  /// reuses the single-flight probe (won't stack behind an in-flight one).
  void noteBackendFailure() {
    unawaited(probe());
  }
}
