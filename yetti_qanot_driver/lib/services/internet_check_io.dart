import 'dart:io' show InternetAddress, SocketException;

/// IO (Android/iOS/desktop): a DNS lookup of a highly-available host is the standard,
/// CORS-free way to tell "the internet works" from "just this backend is unreachable".
///
/// This is the signal that separates the two honest error states: when a backend call
/// dies but this returns true, the internet is fine and only the backend is unreachable
/// (the known onrender regional block) — never "Tarmoq xatosi".
Future<bool> hasInternetConnection() async {
  // Cloudflare's `one.one.one.one` (1.1.1.1) — anycast, resolves fast worldwide.
  const host = 'one.one.one.one';
  try {
    final result = await InternetAddress.lookup(host).timeout(const Duration(seconds: 4));
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } on SocketException {
    return false;
  } catch (_) {
    return false;
  }
}
