import 'package:flutter/material.dart';

/// Reusable app background with the floating glass-like gradient.
class AppGradientBackground extends StatelessWidget {
  const AppGradientBackground({super.key, required this.child, this.colors});

  final Widget child;
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final gradientColors =
        colors ??
        const [
          Color(0xFF5A93F5), // slightly deeper top
          Color(0xFF7EB3FF),
          Color(0xFF9FD2FF),
          Color(0xFFD6EBFF), // avoid near-white to keep color visible
        ];
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradientColors,
              ),
            ),
          ),
        ),
        // Subtle overlay to keep tint even on bright displays
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x00000000),
                  Color(0x14000000), // ~8% black for gentle tint
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
