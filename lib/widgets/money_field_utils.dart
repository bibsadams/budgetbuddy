import 'package:intl/intl.dart';

// Formatter for grouping thousands without a currency symbol.
final NumberFormat _group2 = NumberFormat.decimalPattern();

String formatTwoDecimalsGrouped(num? value) {
  if (value == null) return '0.00';
  final fixed = value.toDouble();
  final parts = fixed.toStringAsFixed(2).split('.');
  final grouped = _group2.format(int.parse(parts[0]));
  return '$grouped.${parts[1]}';
}

double parseLooseAmount(String raw) {
  if (raw.trim().isEmpty) return 0.0;
  final cleaned = raw.replaceAll(',', '');
  return double.tryParse(cleaned) ?? 0.0;
}
