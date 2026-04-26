import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/arb/app_localizations.dart';
import '../../../services/api_error_parser.dart';
import '../../../services/service_providers.dart';
import 'legal_acceptance_gate.dart';

/// Shown when the API returns 403 `LEGAL_ACCEPTANCE_REQUIRED` (e.g. after `POST /driver/location/app`).
class LegalAcceptanceScreen extends ConsumerStatefulWidget {
  const LegalAcceptanceScreen({super.key});

  @override
  ConsumerState<LegalAcceptanceScreen> createState() => _LegalAcceptanceScreenState();
}

class _LegalAcceptanceScreenState extends ConsumerState<LegalAcceptanceScreen> {
  Map<String, dynamic>? _active;
  Object? _loadError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_load);
  }

  Future<void> _load() async {
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return;
    setState(() {
      _loadError = null;
      _active = null;
    });
    try {
      final m = await repo.getLegalActive();
      if (!mounted) return;
      setState(() => _active = m);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    }
  }

  Future<void> _accept() async {
    final repo = ref.read(driverRepositoryProvider);
    if (repo == null) return;
    setState(() => _submitting = true);
    try {
      final body = _acceptBodyFromActive(_active);
      await repo.postLegalAccept(body);
      if (!mounted) return;
      ref.read(legalAcceptanceGateProvider.notifier).clear();
    } on DioException catch (e) {
      if (!mounted) return;
      final msg = parseDriverApiErrorMessage(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg ?? e.message ?? 'Xatolik')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Best-effort body for `POST /legal/accept` from `GET /legal/active` shape.
  Map<String, dynamic>? _acceptBodyFromActive(Map<String, dynamic>? active) {
    if (active == null) return null;
    final id = active['id']?.toString() ?? active['legal_id']?.toString();
    final version = active['version']?.toString();
    if (id != null && id.isNotEmpty) {
      return {
        'legal_id': id,
        ...? (version != null ? {'version': version} : null),
      };
    }
    final docs = active['documents'];
    if (docs is List && docs.isNotEmpty && docs.first is Map) {
      final first = Map<String, dynamic>.from((docs.first as Map).map((k, v) => MapEntry(k.toString(), v)));
      final did = first['id']?.toString();
      if (did != null && did.isNotEmpty) return {'legal_id': did};
    }
    return <String, dynamic>{};
  }

  String _summaryText(Map<String, dynamic> m) {
    final t = m['title'] ?? m['name'];
    final body = m['body'] ?? m['text'] ?? m['content'] ?? m['html'];
    if (t != null && body != null) return '${t.toString()}\n\n${body.toString()}';
    if (body != null) return body.toString();
    return m.toString();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(t.legal_acceptance_title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.legal_acceptance_subtitle, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _loadError != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('$_loadError', textAlign: TextAlign.center),
                                const SizedBox(height: 12),
                                FilledButton(onPressed: _load, child: Text(t.retry)),
                              ],
                            ),
                          ),
                        )
                      : _active == null
                          ? const Center(child: CircularProgressIndicator())
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: SelectableText(
                                _summaryText(_active!),
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _submitting || _active == null ? null : _accept,
                child: _submitting
                    ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(t.legal_acceptance_confirm),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
