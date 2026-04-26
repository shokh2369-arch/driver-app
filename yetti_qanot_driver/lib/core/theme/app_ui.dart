import 'package:flutter/material.dart';

class AppUi {
  static const double r10 = 10;
  static const double r12 = 12;
  static const double r14 = 14;
  static const double r16 = 16;
  static const double r20 = 20;
  static const double r22 = 22;
  static const double r28 = 28;

  static const EdgeInsets p16 = EdgeInsets.all(16);
  static const EdgeInsets ph16 = EdgeInsets.symmetric(horizontal: 16);
  static const EdgeInsets pv16 = EdgeInsets.symmetric(vertical: 16);

  static RoundedRectangleBorder rounded([double radius = r16]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  /// iOS-style continuous corner feel (large cards).
  static BorderRadius iosCardRadius([double r = r22]) => BorderRadius.circular(r);
}
