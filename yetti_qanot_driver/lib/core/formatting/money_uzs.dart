/// Uzbek soʻm display: space-separated groups (e.g. `99 670 so'm`).
String formatUzsSom(double amount) {
  final neg = amount.isNegative;
  final n = amount.round().abs();
  final digits = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return "${neg ? '-' : ''}$buf so'm";
}

String formatUzsSomOrDash(double? amount, {String dash = '—'}) =>
    amount == null ? dash : formatUzsSom(amount);

/// Display fare aligned with backend “nearest 100 soʻm” rounding (mini-app: `Math.round(fare/100)*100`).
String formatDisplayFareSom(double? amount, {String dash = '—'}) {
  if (amount == null) return dash;
  final rounded = (amount / 100.0).round() * 100;
  return formatUzsSom(rounded.toDouble());
}
