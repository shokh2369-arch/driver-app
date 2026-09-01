import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/arb/app_localizations.dart';
import '../../../services/api_error_parser.dart';
import '../../../services/auth_api_client.dart';
import '../../../services/reachability.dart';
import '../../../services/service_providers.dart';
import '../../driver/domain/driver_status.dart';
import '../../driver/presentation/driver_id_controller.dart';
import '../../driver/presentation/driver_session_controller.dart';
import '../../driver/presentation/driver_status_controller.dart';
import '../../trip/presentation/trip_controller.dart';
import 'awaiting_approval_screen.dart';
import 'driver_not_registered_screen.dart';
import 'reachability_controller.dart';

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
  String? _codeError;

  DateTime? _codeSentAt;
  Timer? _tick;

  static const _codeTtl = Duration(minutes: 3);
  static const _resendAfter = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    // Probe reachability once on entering the login screen (single-flight — a no-op if the
    // app-start probe is still running). Not per tap.
    Future.microtask(() {
      if (mounted) ref.read(reachabilityProvider.notifier).probe();
    });
  }

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

  /// Uzbek mobile in E.164: `+998` + 9 digits. The backend now rejects anything else, so
  /// validating here avoids burning an SMS (and a lockout attempt) on a typo.
  static final _uzMobile = RegExp(r'^\+998\d{9}$');

  /// Advance to the code screen, marking a code as freshly sent (starts the 3-min TTL and the
  /// 30-s resend cooldown). [alreadySent] shows the "code already in Telegram" info line
  /// instead of a plain sent confirmation.
  void _goToCodeStep(String phone, {bool alreadySent = false}) {
    setState(() {
      _normalizedPhone = phone;
      _step = _LoginStep.code;
      _codeError = null;
      _codeController.clear();
    });
    _startCountdown();
    if (alreadySent) {
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.phone_login_code_already_sent)),
      );
    }
  }

  /// "Kodim bor" — the driver already has a code (e.g. from an earlier request that hung
  /// client-side but landed server-side; codes stay valid ~3 min). Jump straight to code
  /// entry with no fresh send and no cooldown, so they can type it immediately.
  void _iHaveCode() {
    final t = AppLocalizations.of(context);
    final phone = AuthApiClient.normalizePhone(_phoneController.text);
    if (phone.isEmpty) {
      setState(() => _phoneError = t.phone_login_phone_required);
      return;
    }
    if (!_uzMobile.hasMatch(phone)) {
      setState(() => _phoneError = t.phone_login_phone_invalid);
      return;
    }
    _tick?.cancel();
    setState(() {
      _phoneError = null;
      _normalizedPhone = phone;
      _step = _LoginStep.code;
      _codeError = null;
      _codeSentAt = null; // no send happened → no countdown, resend/send available now
      _codeController.clear();
    });
  }

  Future<void> _sendCode({bool isResend = false}) async {
    // Single-flight: overlapping sends waste codes and (with the atomic lockout) attempts.
    if (_sending) return;
    final t = AppLocalizations.of(context);
    final phone = isResend
        ? _normalizedPhone
        : AuthApiClient.normalizePhone(_phoneController.text);
    if (phone.isEmpty) {
      setState(() => _phoneError = t.phone_login_phone_required);
      return;
    }
    if (!isResend && !_uzMobile.hasMatch(phone)) {
      setState(() => _phoneError = t.phone_login_phone_invalid);
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
      // A successful call proves the backend is reachable — clear any stale banner.
      ref.read(reachabilityProvider.notifier).markReachable();
      setState(() => _sending = false);
      if (isResend) {
        _startCountdown();
      } else {
        _goToCodeStep(phone);
      }
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);

      // 429 / RATE_LIMITED: the previous attempt LANDED (a code is already in Telegram) and
      // the backend is in its cooldown. Not a failure — go to code entry with the "already
      // sent" hint and let the driver enter the code they received.
      if (isRateLimited(e)) {
        if (isResend) {
          _startCountdown();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.phone_login_code_already_sent)),
          );
        } else {
          _goToCodeStep(phone, alreadySent: true);
        }
        return;
      }

      if (isDriverNotRegistered(e)) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const DriverNotRegisteredScreen()),
        );
        return;
      }

      if (isInvalidPhone(e)) {
        final msg = parseDriverApiErrorMessage(e) ?? t.phone_login_phone_invalid;
        setState(() => _phoneError = msg);
        return;
      }

      await _showFailure(e, () => _sendCode(isResend: isResend));
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      await _showTransportFailure(() => _sendCode(isResend: isResend));
    }
  }

  Future<void> _verify() async {
    // Single-flight: the 5-attempt lockout is atomic, so a double-fire burns an attempt and
    // consumes the code. Button + onSubmitted both funnel here.
    if (_verifying) return;
    final t = AppLocalizations.of(context);
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _codeError = t.phone_login_code_length);
      return;
    }

    final repo = ref.read(authRepositoryProvider);
    if (repo == null) return;

    setState(() {
      _codeError = null;
      _verifying = true;
    });
    try {
      final auth = await repo.verifyCode(_normalizedPhone, code);
      if (mounted) ref.read(reachabilityProvider.notifier).markReachable();
      await ref.read(driverIdProvider.notifier).setDriverId(auth.driverId);
      final tok = auth.sessionToken?.trim();
      if (tok != null && tok.isNotEmpty) {
        await ref.read(driverSessionProvider.notifier).setSessionToken(tok);
      } else {
        await ref.read(driverSessionProvider.notifier).clear();
      }
      // Going online can fail independently (network, server). It must NOT roll the login
      // back — the code is already spent — so isolate it. The driver lands authenticated
      // but OFFLINE and can toggle online, which surfaces any error cleanly.
      try {
        await ref.read(driverStatusProvider.notifier).setStatus(DriverStatus.online);
      } catch (e) {
        debugPrint('[yetti_driver] go-online after login failed: $e');
      }
      ref.invalidate(tripProvider);
      if (!mounted) return;
      _tick?.cancel();
      setState(() => _verifying = false);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _verifying = false);

      if (isInvalidCode(e)) {
        setState(() => _codeError = t.phone_login_invalid_code);
        return;
      }
      if (isDriverNotRegistered(e)) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const DriverNotRegisteredScreen()),
        );
        return;
      }
      // Registered but pending approval → dedicated waiting screen, NOT a dead session and
      // NOT a generic failure. (May start appearing after the next backend deploy.)
      if (isDriverNotApproved(e)) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const AwaitingApprovalScreen()),
        );
        return;
      }
      await _showFailure(e, _verify);
    } catch (_) {
      if (!mounted) return;
      setState(() => _verifying = false);
      await _showTransportFailure(_verify);
    }
  }

  /// Route a [DioException] to the correct honest message: 5xx → "server error"; a
  /// transport failure → backend-unreachable vs offline (decided by an internet probe);
  /// anything else → the server's message or a generic network error.
  Future<void> _showFailure(DioException e, VoidCallback retry) async {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    if (isServerError(e)) {
      _snack(t.conn_server_error, retry);
      return;
    }
    if (isTransportFailure(e)) {
      await _showTransportFailure(retry);
      return;
    }
    final msg = parseDriverApiErrorMessage(e) ?? t.phone_login_network_error;
    _snack(msg, retry);
  }

  /// Backend didn't answer at transport level. Probe the internet to pick the honest message
  /// and refresh the persistent banner.
  Future<void> _showTransportFailure(VoidCallback retry) async {
    // Refresh the persistent banner (single-flight probe).
    ref.read(reachabilityProvider.notifier).noteBackendFailure();
    final internetOk = await ref.read(reachabilityServiceProvider).internetUp();
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    _snack(internetOk ? t.conn_backend_unreachable : t.conn_no_internet, retry);
  }

  void _snack(String message, VoidCallback retry) {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: t.retry, onPressed: retry),
      ),
    );
  }

  void _backToPhone() {
    _tick?.cancel();
    setState(() {
      _step = _LoginStep.phone;
      _codeSentAt = null;
      _codeError = null;
      _codeController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final reach = ref.watch(reachabilityProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ReachabilityBanner(state: reach),
                Expanded(
                  child: SingleChildScrollView(
                    child: _step == _LoginStep.phone
                        ? _buildPhoneStep(theme, t, reach)
                        : _buildCodeStep(theme, t, reach),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhoneStep(ThemeData theme, AppLocalizations t, ReachabilityState reach) {
    final blocked = reach.unreachable;
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
            if (!_sending && !blocked) _sendCode();
          },
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: (_sending || blocked) ? null : () => _sendCode(),
          child: _sending
              ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.phone_login_send_code),
        ),
        const SizedBox(height: 8),
        // Always offer a path to code entry for a code that arrived from an earlier attempt
        // (even one that appeared to fail). Kept enabled while unreachable — verifying is a
        // separate call the driver may still want to try.
        TextButton(
          onPressed: _sending ? null : _iHaveCode,
          child: Text(t.phone_login_have_code),
        ),
      ],
    );
  }

  Widget _buildCodeStep(ThemeData theme, AppLocalizations t, ReachabilityState reach) {
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
            errorText: _codeError,
            border: const OutlineInputBorder(),
          ),
          autocorrect: false,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) {
            if (_codeError != null) setState(() => _codeError = null);
          },
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
        const SizedBox(height: 16),
        if (sent == null)
          // Arrived via "Kodim bor" (no send happened) — offer to request a fresh code, gated
          // by reachability like the phone step.
          TextButton(
            onPressed: (_sending || reach.unreachable) ? null : () => _sendCode(isResend: true),
            child: _sending
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.phone_login_send_code),
          )
        else if (!_canResend)
          Text(
            t.phone_login_resend_in(_mmSs(resendWait)),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          )
        else
          TextButton(
            onPressed: (_sending || reach.unreachable) ? null : () => _sendCode(isResend: true),
            child: _sending
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.phone_login_resend),
          ),
      ],
    );
  }
}

/// Persistent banner while the backend is unreachable — honest copy (backend-down vs offline)
/// plus a visible "Qayta urinish" (or a spinner while re-probing). Auto re-probe with backoff
/// happens in [ReachabilityController]; this is the manual escape hatch.
class _ReachabilityBanner extends ConsumerWidget {
  const _ReachabilityBanner({required this.state});

  final ReachabilityState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!state.unreachable) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final message = state.status == Reachability.offline
        ? t.conn_no_internet
        : t.conn_backend_unreachable;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 20, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (state.probing)
            SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.onErrorContainer,
              ),
            )
          else
            TextButton(
              onPressed: () => ref.read(reachabilityProvider.notifier).retryNow(),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onErrorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
              child: Text(t.retry),
            ),
        ],
      ),
    );
  }
}
