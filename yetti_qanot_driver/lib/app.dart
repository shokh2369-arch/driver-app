import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/localization/arb/app_localizations.dart';
import 'core/localization/locale_controller.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/driver/domain/driver_status.dart';
import 'features/driver/presentation/driver_id_controller.dart';
import 'features/driver/presentation/driver_location_sync_controller.dart';
import 'features/driver/presentation/driver_status_controller.dart';
import 'features/trip/presentation/trip_controller.dart';
import 'features/auth/presentation/phone_login_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/home/presentation/location_gate_controller.dart';
import 'features/home/presentation/location_required_screen.dart';
import 'features/legal/presentation/legal_acceptance_gate.dart';
import 'features/legal/presentation/legal_acceptance_screen.dart';
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
      if (AppConfig.usesPublicDemoRouting) {
        debugPrint(
          '[yetti_driver] WARNING: routing still points at the Project OSRM demo server, '
          'which is fair-use / non-commercial and will rate-limit production traffic. '
          'Set --dart-define=OSRM_ROUTING_BASE_URL=<your instance> before release '
          '(see RELEASE_BUILD.txt).',
        );
      }
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
        // In a wide browser window the phone UI is boxed to phone width and centred, so
        // the web build looks and behaves like the device it is designed for instead of
        // stretching cards across a desktop. No-op on mobile.
        builder: (context, child) {
          if (!kIsWeb || child == null) return child ?? const SizedBox.shrink();
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Driver ID → legal gate → location gate → [HomeScreen] (HTTP: backend `DRIVER_HTTP_API_HANDOFF.md` / `DRIVER_CLIENT.md`).
class _AppShell extends ConsumerWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void showSignalSnackBar(int? previous, int next, String Function() message) {
      if (next <= 0) return;
      if (previous != null && next == previous) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(message())));
      });
    }

    ref.listen(sessionRevokedMessageSignalProvider, (int? previous, int next) {
      showSignalSnackBar(
        previous,
        next,
        () => AppLocalizations.of(context).session_revoked_elsewhere,
      );
    });
    ref.listen(offlineSyncFailedSignalProvider, (int? previous, int next) {
      showSignalSnackBar(
        previous,
        next,
        () => AppLocalizations.of(context).offline_saved_locally,
      );
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
    // Driver stays ONLINE across app exit / swipe-away. Only the explicit OFFLINE toggle (or
    // sign-out) calls `POST /driver/offline`. Stored online flag persists in SharedPreferences,
    // so the next launch resumes ONLINE automatically.
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded = state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden;
    ref.read(appLifecycleProvider.notifier).setBackgrounded(backgrounded);
  }

  @override
  Widget build(BuildContext context) {
    // Keep dispatch poll + location sync alive for the whole app session while ONLINE
    // (not only when [HomeScreen] rebuilds — e.g. drawer routes, overlays).
    if (AppConfig.hasHttpApi &&
        ref.watch(driverStatusProvider) == DriverStatus.online) {
      ref.watch(tripProvider);
      ref.watch(driverLocationSyncProvider);
    }
    return widget.child;
  }
}
