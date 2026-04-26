import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/arb/app_localizations.dart';
import '../../../services/api_error_parser.dart';
import '../../../services/auth_api_client.dart';
import '../../../services/service_providers.dart';
import '../../driver/domain/driver_status.dart';
import '../../driver/presentation/driver_id_controller.dart';
import '../../driver/presentation/driver_session_controller.dart';
import '../../driver/presentation/driver_status_controller.dart';
import '../../trip/presentation/trip_controller.dart';
import 'driver_not_registered_screen.dart';

enum _LoginStep { phone, code }

/// Phone + SMS code login when **`DRIVER_ID`** dart-define is unset and no saved id.
/// Persists **`driver_id`** via [driverIdProvider] on success — same as manual ID for [X-Driver-Id].
class PhoneLoginScreen extends ConsumerStatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  ConsumerState<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends ConsumerState<PhoneLoginScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  _LoginStep _step = _LoginStep.phone;
  String _normalizedPhone = '';

  bool _sending = false;
  bool _verifying = false;
  String? _phoneError;

  DateTime? _codeSentAt;
  Timer? _tick;

  static const _codeTtl = Duration(minutes: 3);
  static const _resendAfter = Duration(seconds: 30);

  @override
  void dispose() {
    _tick?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _tick?.cancel();
    _codeSentAt = DateTime.now();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      final expires = _codeSentAt!.add(_codeTtl);
      if (DateTime.now().isAfter(expires)) {
        _tick?.cancel();
      }
    });
  }

  bool get _canResend {
    final sent = _codeSentAt;
    if (sent == null) return false;
    return DateTime.now().isAfter(sent.add(_resendAfter));
  }

  String _mmSs(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _sendCode({bool isResend = false}) async {
    final t = AppLocalizations.of(context);
    final phone = isResend
        ? _normalizedPhone
        : AuthApiClient.normalizePhone(_phoneController.text);
    if (phone.isEmpty) {
      setState(() => _phoneError = t.phone_login_phone_required);
      return;
    }
    setState(() {
      _phoneError = null;
      _sending = true;
    });

    final repo = ref.read(authRepositoryProvider);
    if (repo == null) {
      setState(() => _sending = false);
      return;
    }

    try {
      await repo.requestCode(phone);
      if (!mounted) return;
      setState(() {
        _sending = false;
        if (!isResend) {
          _normalizedPhone = phone;
          _step = _LoginStep.code;
        }
        _codeController.clear();
      });
      _startCountdown();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      final sc = e.response?.statusCode;
      final code = (parseDriverApiErrorCode(e) ?? '').toUpperCase();
      final msg = parseDriverApiErrorMessage(e) ?? t.phone_login_network_error;

      if (sc == 403 && code == 'DRIVER_NOT_REGISTERED') {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const DriverNotRegisteredScreen()),
        );
        return;
      }

      if (sc == 400 && (code == 'INVALID_PHONE' || code == 'INVALID_BODY')) {
        setState(() => _phoneError = msg);
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          action: SnackBarAction(label: t.retry, onPressed: () => _sendCode(isResend: isResend)),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      _showNetworkRetry(() => _sendCode(isResend: isResend));
    }
  }

  Future<void> _verify() async {
    final t = AppLocalizations.of(context);
    final code = _codeController.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.phone_login_code_length)));
      return;
    }

    final repo = ref.read(authRepositoryProvider);
    if (repo == null) return;

    setState(() => _verifying = true);
    try {
      final auth = await repo.verifyCode(_normalizedPhone, code);
      await ref.read(driverIdProvider.notifier).setDriverId(auth.driverId);
      final tok = auth.sessionToken?.trim();
      if (tok != null && tok.isNotEmpty) {
        await ref.read(driverSessionProvider.notifier).setSessionToken(tok);
      } else {
        await ref.read(driverSessionProvider.notifier).clear();
      }
      await ref.read(driverStatusProvider.notifier).setStatus(DriverStatus.online);
      ref.invalidate(tripProvider);
      if (!mounted) return;
      _tick?.cancel();
      setState(() => _verifying = false);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _verifying = false);
      final codeErr = parseDriverApiErrorCode(e);
      if (codeErr == 'INVALID_CODE') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.phone_login_invalid_code)));
        return;
      }
      if ((codeErr ?? '').toUpperCase() == 'DRIVER_NOT_REGISTERED') {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const DriverNotRegisteredScreen()),
        );
        return;
      }
      _showNetworkRetry(_verify);
    } catch (_) {
      if (!mounted) return;
      setState(() => _verifying = false);
      _showNetworkRetry(_verify);
    }
  }

  void _showNetworkRetry(VoidCallback retry) {
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t.phone_login_network_error),
        action: SnackBarAction(label: t.retry, onPressed: retry),
      ),
    );
  }

  void _backToPhone() {
    _tick?.cancel();
    setState(() {
      _step = _LoginStep.phone;
      _codeSentAt = null;
      _codeController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _step == _LoginStep.phone ? _buildPhoneStep(theme, t) : _buildCodeStep(theme, t),
          ),
        ),
      ),
    );
  }

  Widget _buildPhoneStep(ThemeData theme, AppLocalizations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(child: Icon(Icons.local_taxi, size: 56, color: theme.colorScheme.primary)),
        const SizedBox(height: 20),
        Text(t.phone_login_title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        Text(t.phone_login_subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 24),
        TextField(
          controller: _phoneController,
          decoration: InputDecoration(
            labelText: t.phone_login_phone_hint,
            errorText: _phoneError,
            border: const OutlineInputBorder(),
          ),
          autocorrect: false,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!_sending) _sendCode();
          },
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _sending ? null : () => _sendCode(),
          child: _sending
              ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.phone_login_send_code),
        ),
        const SizedBox(height: 12),
        // Removed "Saqlash" (manual driver id setup) from SMS login.
      ],
    );
  }

  Widget _buildCodeStep(ThemeData theme, AppLocalizations t) {
    final sent = _codeSentAt;
    Duration? left;
    var expired = false;
    if (sent != null) {
      final end = sent.add(_codeTtl);
      final diff = end.difference(DateTime.now());
      expired = diff.isNegative;
      left = expired ? Duration.zero : diff;
    }

    Duration resendWait = Duration.zero;
    if (sent != null && !_canResend) {
      final d = sent.add(_resendAfter).difference(DateTime.now());
      resendWait = d.isNegative ? Duration.zero : d;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _verifying ? null : _backToPhone,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          ),
        ),
        Center(child: Icon(Icons.local_taxi, size: 48, color: theme.colorScheme.primary)),
        const SizedBox(height: 12),
        Text(t.phone_login_code_title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text(
          t.phone_login_code_sent_to(_normalizedPhone),
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (sent != null && !expired && left != null)
          Text(
            t.phone_login_code_expires(_mmSs(left)),
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
          ),
        if (expired)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(t.phone_login_code_expired, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 20),
        TextField(
          controller: _codeController,
          decoration: InputDecoration(
            labelText: t.phone_login_code_hint,
            border: const OutlineInputBorder(),
          ),
          autocorrect: false,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) {
            if (!_verifying && !expired) _verify();
          },
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: (_verifying || expired) ? null : _verify,
          child: _verifying
              ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.phone_login_verify),
        ),
        const SizedBox(height: 8),
        // Removed "Saqlash" (manual driver id setup) from SMS login.
        const SizedBox(height: 16),
        if (sent != null) ...[
          if (!_canResend)
            Text(
              t.phone_login_resend_in(_mmSs(resendWait)),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            )
          else
            TextButton(
              onPressed: _sending ? null : () => _sendCode(isResend: true),
              child: _sending
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.phone_login_resend),
            ),
        ],
      ],
    );
  }
}
