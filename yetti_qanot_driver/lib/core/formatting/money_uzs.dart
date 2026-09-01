/// Default soʻm suffix (Latin script). Pass [suffix] from `AppLocalizations.currency_som`
/// wherever localized strings are available so Cyrillic users do not see Latin text.
const String kDefaultSomSuffix = "so'm";

/// Uzbek soʻm display: space-separated groups (e.g. `99 670 so'm`).
///
/// Server-supplied values can be non-finite (`NaN`, `Infinity`); `double.round()` throws
/// `UnsupportedError` on those, so they render as [dash] instead of crashing the build.
String formatUzsSom(
  double amount, {
  String suffix = kDefaultSomSuffix,
  String dash = '—',
}) {
  if (!amount.isFinite) return dash;
  final neg = amount.isNegative;
  final n = amount.round().abs();
  final digits = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return "${neg ? '-' : ''}$buf $suffix";
}

String formatUzsSomOrDash(
  double? amount, {
  String dash = '—',
  String suffix = kDefaultSomSuffix,
}) =>
    amount == null ? dash : formatUzsSom(amount, suffix: suffix, dash: dash);

/// Display fare aligned with backend “nearest 100 soʻm” rounding (mini-app: `Math.round(fare/100)*100`).
String formatDisplayFareSom(
  double? amount, {
  String dash = '—',
  String suffix = kDefaultSomSuffix,
}) {
  if (amount == null || !amount.isFinite) return dash;
  final rounded = (amount / 100.0).round() * 100;
  return formatUzsSom(rounded.toDouble(), suffix: suffix, dash: dash);
}

/// Integer soʻm (e.g. dispatch `estimated_price`) with the same grouping.
String formatSomInt(int amount, {String suffix = kDefaultSomSuffix}) =>
    formatUzsSom(amount.toDouble(), suffix: suffix);
