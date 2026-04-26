import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Foreground vs background — used for dispatch poll and HTTP location backoff.
enum AppLifecyclePhase {
  resumed,
  backgrounded,
}

class AppLifecycleNotifier extends Notifier<AppLifecyclePhase> {
  @override
  AppLifecyclePhase build() => AppLifecyclePhase.resumed;

  void setBackgrounded(bool backgrounded) {
    state = backgrounded ? AppLifecyclePhase.backgrounded : AppLifecyclePhase.resumed;
  }
}

final appLifecycleProvider = NotifierProvider<AppLifecycleNotifier, AppLifecyclePhase>(
  AppLifecycleNotifier.new,
);
