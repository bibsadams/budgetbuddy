import 'package:flutter/services.dart';

/// Simple numeric input formatter allowing digits with optional single decimal point
/// and up to 2 decimal places. Does not add grouping commas during typing to
/// avoid cursor jump issues. Example accepted inputs: "", "0", "12", "12.", "12.3", "12.34".
class TwoDecimalInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String text = newValue.text;
    if (text.isEmpty) return newValue.copyWith(text: '');

    // Accept comma as decimal separator and normalize to '.'
    text = text.replaceAll(',', '.');

    final buf = StringBuffer();
    bool seenDot = false;
    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '.') {
        if (!seenDot) {
          buf.write('.');
          seenDot = true;
        }
      } else if (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) { // 0-9
        buf.write(ch);
      }
    }
    var sanitized = buf.toString();

    // Handle only '.' decimals
    if (sanitized.contains('.')) {
      final parts = sanitized.split('.');
      final intPartRaw = parts[0];
      final decRaw = parts.length > 1 ? parts[1] : '';
      final limitedDec = decRaw.length > 2 ? decRaw.substring(0, 2) : decRaw;
      // Normalize leading zeros in int part
      String intPart = intPartRaw.isEmpty ? '0' : int.tryParse(intPartRaw) == null ? '0' : int.parse(intPartRaw).toString();
      sanitized = limitedDec.isEmpty && text.endsWith('.')
          ? '$intPart.'
          : limitedDec.isEmpty
              ? intPart
              : '$intPart.$limitedDec';
    } else {
      // No decimal point: compress leading zeros
      sanitized = int.tryParse(sanitized) == null ? '0' : int.parse(sanitized).toString();
    }

    return TextEditingValue(
      text: sanitized,
      selection: TextSelection.collapsed(offset: sanitized.length),
    );
  }
}
