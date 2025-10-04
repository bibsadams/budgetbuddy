import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

/// Replaces assets/budgetbuddy_icon.png with a generated "circle arrow reset" icon
/// while keeping the same pixel dimensions as the existing file. A backup of the
/// previous file is written to assets/budgetbuddy_icon_old.png.
Future<void> main() async {
  final assetPath = 'assets/budgetbuddy_icon.png';
  final backupPath = 'assets/budgetbuddy_icon_old.png';

  int width = 1024;
  int height = 1024;

  // Try to read the existing icon to get its dimensions
  try {
    final bytes = await File(assetPath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded != null) {
      width = decoded.width;
      height = decoded.height;
    }
    // Backup the old file
    await File(assetPath).copy(backupPath);
  } catch (_) {
    // If it doesn't exist, proceed with default size
  }

  final canvas = img.Image(width: width, height: height);

  // Background: white
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

  // Colors
  final arrowColor = img.ColorRgb8(33, 150, 243); // Material Blue 500

  // Draw a circular arrow similar to a "reset" icon
  final cx = width / 2.0;
  final cy = height / 2.0;
  final radius = math.min(width, height) * 0.32; // leave padding
  final stroke = (math.min(width, height) * 0.08).round();

  // Arc from ~220° to ~520° (i.e., ~300° sweep) to suggest a wrapped arrow
  final startDeg = 220.0;
  final endDeg = 520.0; // > 360 to wrap around

  void drawThickLine(
    num x1,
    num y1,
    num x2,
    num y2,
    int thickness,
    img.Color color,
  ) {
    // Draw a line with thickness by drawing multiple lines offset perpendicular
    final dx = x2 - x1;
    final dy = y2 - y1;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final nx = -dy / len; // unit normal x
    final ny = dx / len; // unit normal y
    // Sample across thickness and draw simple lines
    final steps = thickness.clamp(1, 1000);
    for (int i = 0; i < steps; i++) {
      final t = (i - steps / 2) / (steps == 1 ? 1 : steps);
      final ox = nx * t * thickness;
      final oy = ny * t * thickness;
      img.drawLine(
        canvas,
        x1: (x1 + ox).round(),
        y1: (y1 + oy).round(),
        x2: (x2 + ox).round(),
        y2: (y2 + oy).round(),
        color: color,
      );
    }
  }

  void drawArc({
    required double cx,
    required double cy,
    required double r,
    required double startDeg,
    required double endDeg,
    required int thickness,
    required img.Color color,
  }) {
    final startRad = startDeg * math.pi / 180.0;
    final endRad = endDeg * math.pi / 180.0;
    final steps = 720; // high resolution
    double prevX = cx + r * math.cos(startRad);
    double prevY = cy + r * math.sin(startRad);
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final a = startRad + (endRad - startRad) * t;
      final x = cx + r * math.cos(a);
      final y = cy + r * math.sin(a);
      drawThickLine(prevX, prevY, x, y, thickness, color);
      prevX = x;
      prevY = y;
    }
  }

  // Draw the arc body
  drawArc(
    cx: cx,
    cy: cy,
    r: radius,
    startDeg: startDeg,
    endDeg: endDeg - 20, // leave gap for arrow head
    thickness: stroke,
    color: arrowColor,
  );

  // Arrow head at endDeg-20 pointing tangentially
  final headAngle = (endDeg - 20) * math.pi / 180.0;
  final tipX = cx + radius * math.cos(headAngle);
  final tipY = cy + radius * math.sin(headAngle);

  // Make a simple triangular arrowhead
  final headLen = radius * 0.22;
  final headWidth = stroke * 2.0;
  final tangentAngle = headAngle + math.pi / 2; // rotate 90° to get tangent dir

  final baseX = tipX - headLen * math.cos(tangentAngle);
  final baseY = tipY - headLen * math.sin(tangentAngle);
  final leftX = baseX + (headWidth / 2) * math.cos(headAngle);
  final leftY = baseY + (headWidth / 2) * math.sin(headAngle);
  final rightX = baseX - (headWidth / 2) * math.cos(headAngle);
  final rightY = baseY - (headWidth / 2) * math.sin(headAngle);

  img.fillPolygon(
    canvas,
    vertices: [
      img.Point((tipX).round(), (tipY).round()),
      img.Point((leftX).round(), (leftY).round()),
      img.Point((rightX).round(), (rightY).round()),
    ],
    color: arrowColor,
  );

  // Optional inner circle to hint motion
  final innerR = radius * 0.55;
  final innerStroke = (stroke * 0.45).round();
  drawArc(
    cx: cx,
    cy: cy,
    r: innerR,
    startDeg: startDeg + 40,
    endDeg: endDeg - 80,
    thickness: innerStroke,
    color: arrowColor,
  );

  // Write file
  final png = img.encodePng(canvas);
  await File(assetPath).writeAsBytes(png);
  stdout.writeln(
    'Replaced $assetPath (backup at $backupPath). Size: ${width}x$height',
  );
}
