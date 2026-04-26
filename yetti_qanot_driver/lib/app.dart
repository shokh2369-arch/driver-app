import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/localization/arb/app_localizations.dart';
import 'core/localization/locale_controller.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/driver/domain/driver_status.dart';
import 'features/driver/presentation/driver_status_controller.dart';
import 'features/driver/presentation/driver_id_controller.dart';
import 'features/auth/presentation/phone_login_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/home/presentation/location_gate_controller.dart';
import 'features/home/presentation/location_required_screen.dart';
import 'features/legal/presentation/legal_acceptance_gate.dart';
import 'features/legal/presentation/legal_acceptance_screen.dart';
import 'features/trip/presentation/trip_controller.dart';
import 'services/app_lifecycle_provider.dart';
import 'services/config.dart';
import 'services/driver_session_revocation.dart';
import 'services/local_notifications.dart';

class YettiQanotApp extends ConsumerWidget {
  const YettiQanotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kDebugMode) {
      debugPrint(
        '[yetti_driver] API_BASE_URL=${AppConfig.apiBaseUrl} '
        'ENABLE_DRIVER_HTTP_LIVE_LOCATION=${AppConfig.driverHttpLiveLocationEnabled}',
      );
    }
    final themeMode = ref.watch(themeProvider).toFlutterThemeMode();
    final locale = ref.watch(localeProvider);

    return _AppLifecycleBinder(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'YettiQanot',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: themeMode,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _AppShell(),
      ),
    );
  }
}

/// Driver ID → legal gate → location gate → [HomeScreen] (HTTP: backend `DRIVER_HTTP_API_HANDOFF.md` / `DRIVER_CLIENT.md`).
class _AppShell extends ConsumerWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(sessionRevokedMessageSignalProvider, (int? previous, int next) {
      if (next <= 0) return;
      if (previous != null && next == previous) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger == null) return;
        messenger.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).session_revoked_elsewhere)),
        );
      });
    });

    if (ref.watch(legalAcceptanceGateProvider)) {
      return const LegalAcceptanceScreen();
    }

    final savedId = ref.watch(driverIdProvider).trim();
    final envId = AppConfig.driverId.trim();
    final effectiveId = envId.isNotEmpty ? envId : savedId;
    final hasTelegramAuth = AppConfig.telegramInitData.trim().isNotEmpty;

    // If FORCE_PHONE_LOGIN is enabled, ignore saved driver id and require SMS flow (unless Telegram init data is present).
    final shouldForcePhone = AppConfig.forcePhoneLogin && envId.isEmpty;
    if (AppConfig.hasHttpApi && !hasTelegramAuth && (effectiveId.isEmpty || shouldForcePhone)) {
      return const PhoneLoginScreen();
    }

    final loc = ref.watch(locationGateProvider);
    return switch (loc) {
      LocationGateChecking() => const Scaffold(body: Center(child: CircularProgressIndicator())),
      final LocationGateDenied denied => LocationRequiredScreen(state: denied),
      LocationGateReady() => const HomeScreen(),
    };
  }
}

class _AppLifecycleBinder extends ConsumerStatefulWidget {
  const _AppLifecycleBinder({required this.child});

  final Widget child;

  @override
  ConsumerState<_AppLifecycleBinder> createState() => _AppLifecycleBinderState();
}

class _AppLifecycleBinderState extends ConsumerState<_AppLifecycleBinder> with WidgetsBindingObserver {
  bool _autoOfflined = false;
  Timer? _bgAutoOfflineTimer;

  Future<void> _autoOfflineBestEffort() async {
    if (_autoOfflined) return;
    // Only meaningful if we were online.
    if (ref.read(driverStatusProvider) != DriverStatus.online) return;
    // Do not clear server "live" while the driver has an assigned / in-progress trip — brief
    // backgrounding (maps, calls) would stop HTTP pings and trip guards fail (~90s freshness).
    if (ref.read(tripProvider).requiresContinuousLiveLocation) return;
    _autoOfflined = true;
    try {
      // Best-effort: when the app is being terminated/removed from recents, attempt to clear
      // server online flags so dispatch stops sending offers.
      await ref.read(driverStatusProvider.notifier).setStatus(DriverStatus.offline);
    } catch (_) {
      // Swallow: process is shutting down; network may be unavailable.
    }
  }

  void _scheduleAutoOfflineFromBackground() {
    _bgAutoOfflineTimer?.cancel();
    // If the driver comes back quickly, don't flip them offline.
    _bgAutoOfflineTimer = Timer(const Duration(seconds: 8), () {
      unawaited(_autoOfflineBestEffort());
    });
  }

  void _cancelAutoOfflineFromBackground() {
    _bgAutoOfflineTimer?.cancel();
    _bgAutoOfflineTimer = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Best-effort local notifications init (orders).
    // Safe: no secrets, no network; on web this is a no-op in [LocalNotifications].
    LocalNotifications.ensureInitialized();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAutoOfflineFromBackground();
    // Also attempt on teardown; some Android variants won't deliver `detached` reliably.
    unawaited(_autoOfflineBestEffort());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded = state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden;
    ref.read(appLifecycleProvider.notifier).setBackgrounded(backgrounded);

    if (state == AppLifecycleState.resumed) {
      _cancelAutoOfflineFromBackground();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Android does not always deliver `detached` on swipe-away. Scheduling an OFFLINE after a short
      // grace period makes "fully exiting" reliably clear server online flags.
      _scheduleAutoOfflineFromBackground();
    }

    // When the OS is detaching the Flutter engine (common when swiping away from recents),
    // attempt to go OFFLINE. Do not do this on normal backgrounding.
    if (state == AppLifecycleState.detached) {
      unawaited(_autoOfflineBestEffort());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
