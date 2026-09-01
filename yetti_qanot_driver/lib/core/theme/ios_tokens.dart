import 'package:flutter/material.dart';

/// Apple-style system colors and surfaces (modern iOS / “liquid” look).
/// Use with [AppTheme] for a consistent HIG-adjacent UI on all platforms.
abstract final class IosTokens {
  // System colors (light; pair with theme for dark variants where needed)
  static const systemBlue = Color(0xFF007AFF);
  static const systemBlueDark = Color(0xFF0A84FF);
  static const systemGreen = Color(0xFF34C759);
  static const systemGreenDark = Color(0xFF30D158);
  static const systemIndigo = Color(0xFF5856D6);
  static const systemOrange = Color(0xFFFF9500);
  static const systemTeal = Color(0xFF5AC8FA);
  static const systemRed = Color(0xFFFF3B30);
  static const systemGray = Color(0xFF8E8E93);
  static const systemGray2 = Color(0xFFAEAEB2);
  static const systemGray3 = Color(0xFFC7C7CC);
  static const systemGray4 = Color(0xFFD1D1D6);
  static const systemGray5 = Color(0xFFE5E5EA);
  static const systemGray6 = Color(0xFFF2F2F7);

  static const groupedBackground = Color(0xFFF2F2F7);
  static const separatorOpaque = Color(0xFFC6C6C8);
  static const labelPrimary = Color(0xFF000000);
  static const labelSecondary = Color(0xFF8E8E93);

  // Dark mode surfaces (iOS elevated)
  static const darkBackground = Color(0xFF000000);
  static const darkElevated = Color(0xFF1C1C1E);
  static const darkElevated2 = Color(0xFF2C2C2E);
  static const darkGrouped = Color(0xFF1C1C1E);
}
