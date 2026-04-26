import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/storage_providers.dart';

enum AppThemeMode { system, light, dark }

extension AppThemeModeX on AppThemeMode {
  ThemeMode toFlutterThemeMode() => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  static AppThemeMode fromStored(String? value) => switch (value) {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };

  String toStored() => switch (this) {
    AppThemeMode.system => 'system',
    AppThemeMode.light => 'light',
    AppThemeMode.dark => 'dark',
  };
}

class ThemeController extends Notifier<AppThemeMode> {
  @override
  AppThemeMode build() {
    final prefs = ref.watch(appPrefsProvider);
    return AppThemeModeX.fromStored(prefs.themeMode);
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    state = mode;
    await ref.read(appPrefsProvider).setThemeMode(mode.toStored());
  }
}

final themeProvider = NotifierProvider<ThemeController, AppThemeMode>(
  ThemeController.new,
);

