import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'resilient_transport.dart';
import 'internet_check.dart';

/// Result of the login-screen reachability probe.
///
/// The whole point is to tell three states apart so the driver sees an honest message
/// instead of a blanket "Tarmoq xatosi":
/// - [reachable]  — backend answered `/health`.
/// - [backendDown] — backend did not answer but the internet works (the onrender regional
///   block: fonts/tiles load while the API host hangs 12–15 s and dies).
/// - [offline]    — no connectivity at all.
enum Reachability { unknown, reachable, backendDown, offline }

/// Probes backend health and, when it fails, whether the internet itself is up.
///
/// Deliberately unauthenticated (`GET /health`, no driver headers) with a **short** timeout
/// so the login screen fails early instead of making the driver wait ~15 s per tap.
///
/// Uses [http] (browser `fetch` on web) instead of Dio — Dio's browser adapter was
/// reporting `connectionTimeout` against a live host that curl/Node reach in ~1s.
class ReachabilityService {
  ReachabilityService({
    http.Client? httpClient,
    Future<bool> Function()? internetProbe,
  })  : _http = httpClient ?? createResilientHttpPackageClient(),
        _internetProbe = internetProbe ?? hasInternetConnection,
        _ownsClient = httpClient == null;

  final http.Client _http;
  final Future<bool> Function() _internetProbe;
  final bool _ownsClient;

  /// Long enough for a warm free-tier response and Flutter-web debug congestion.
  static const probeTimeout = Duration(seconds: 15);

  static String get healthUrl {
    final base = AppConfig.apiBaseUrl.trim();
    if (base.isEmpty) return '';
    final noSlash = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$noSlash/health';
  }

  /// `GET /health` → true when the backend answered with a non-5xx status within [probeTimeout].
  Future<bool> backendHealthy() async {
    final url = healthUrl;
    if (url.isEmpty) return false;
    try {
      final res = await _http
          .get(Uri.parse(url), headers: const {'Accept': '*/*'})
          .timeout(probeTimeout);
      final sc = res.statusCode;
      final ok = sc >= 200 && sc < 500;
      if (!ok) {
        debugPrint('[yetti_driver] health probe $url → HTTP $sc (host=${Uri.parse(url).host})');
      }
      return ok;
    } catch (e) {
      debugPrint(
        '[yetti_driver] health probe $url failed: $e (host=${Uri.parse(url).host})',
      );
      return false;
    }
  }

  /// True when the device has working internet (used only to separate "backend down" from
  /// "offline" — never called unless the backend probe already failed).
  Future<bool> internetUp() => _internetProbe();

  /// Full classification: one health probe, then (only on failure) an internet probe.
  Future<Reachability> classify() async {
    final backendOk = await backendHealthy();
    if (backendOk) return Reachability.reachable;
    final internetOk = await internetUp();
    return classifyReachability(backendOk: false, internetOk: internetOk);
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }
}

/// Pure mapping from the two signals to a [Reachability] — extracted so it is unit-testable
/// without any network.
Reachability classifyReachability({required bool backendOk, required bool internetOk}) {
  if (backendOk) return Reachability.reachable;
  if (internetOk) return Reachability.backendDown;
  return Reachability.offline;
}
