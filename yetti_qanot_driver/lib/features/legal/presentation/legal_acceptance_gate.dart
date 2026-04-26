import 'package:flutter_riverpod/flutter_riverpod.dart';

/// When true, [MaterialApp] should show legal acceptance (403 LEGAL_ACCEPTANCE_REQUIRED).
class LegalAcceptanceController extends Notifier<bool> {
  @override
  bool build() => false;

  void requireAcceptance() => state = true;

  void clear() => state = false;
}

final legalAcceptanceGateProvider = NotifierProvider<LegalAcceptanceController, bool>(
  LegalAcceptanceController.new,
);
