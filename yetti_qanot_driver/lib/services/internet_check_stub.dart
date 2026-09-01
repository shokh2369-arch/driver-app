import 'package:web/web.dart' as web;

/// Web: `dart:io` (and DNS lookup) is unavailable, so use the browser's own connectivity
/// signal, `navigator.onLine`. It is not a reachability guarantee, but `false` reliably
/// means "no network" — enough to separate "internet down" from "backend unreachable"
/// (the DevTools proof for the regional block is exactly this: fonts load 200 while the
/// backend hangs, i.e. `onLine == true` but the backend call dies).
Future<bool> hasInternetConnection() async {
  try {
    return web.window.navigator.onLine;
  } catch (_) {
    // If we cannot read the flag, assume online rather than mislabel a working network.
    return true;
  }
}
