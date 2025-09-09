import 'package:flutter/material.dart';

/// A lightweight, reusable neumorphic (soft pillow) container with press effects.
///
/// - Shows subtle light and dark drop shadows to fake depth.
/// - Animates scale and elevation on press.
/// - Keeps API simple and dependency-free.
class PressableNeumorphic extends StatefulWidget {
  const PressableNeumorphic({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.backgroundColor,
    this.useSurfaceBase = false,
    this.borderRadius = 18,
    this.depth = 7,
    this.spread = 0,
    this.padding,
    this.margin,
    this.shadowColor,
    this.highlightColor,
    this.animateDuration = const Duration(milliseconds: 120),
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double borderRadius;

  /// Pixel offset of the shadows ("depth").
  final double depth;

  /// Extra blur radius on shadows.
  final double spread;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? backgroundColor;
  // If true, use colorScheme.surface instead of surfaceContainerLow.
  final bool useSurfaceBase;
  final Color? shadowColor;
  final Color? highlightColor;
  final Duration animateDuration;

  @override
  State<PressableNeumorphic> createState() => _PressableNeumorphicState();
}

class _PressableNeumorphicState extends State<PressableNeumorphic> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bg =
        widget.backgroundColor ??
        (widget.useSurfaceBase ? cs.surface : cs.surfaceContainerLow);

    // Infer soft shadow colors from bg, unless overridden
    Color darkShadow =
        widget.shadowColor ??
        (isDark
            ? Colors.black.withValues(alpha: 0.5)
            : Colors.black.withValues(alpha: 0.12));
    Color lightShadow =
        widget.highlightColor ??
        (isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.65));

    final r = Radius.circular(widget.borderRadius);

    // When pressed, reduce offset/blur to feel "closer"
    final double depth = _pressed ? widget.depth * 0.35 : widget.depth;
    final double blur = _pressed ? 9 : 20;

    Widget content = AnimatedContainer(
      duration: widget.animateDuration,
      margin: widget.margin,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.all(r),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.03)
              : Colors.black.withValues(alpha: 0.03),
        ),
        boxShadow: [
          // Dark bottom-right
          BoxShadow(
            color: darkShadow,
            offset: Offset(depth, depth),
            blurRadius: blur + widget.spread,
            spreadRadius: 0,
          ),
          // Light top-left
          BoxShadow(
            color: lightShadow,
            offset: Offset(-depth, -depth),
            blurRadius: blur,
            spreadRadius: 0,
          ),
        ],
      ),
      child: widget.child,
    );

    content = AnimatedScale(
      duration: widget.animateDuration,
      scale: _pressed ? 0.985 : 1.0,
      child: content,
    );

    // Gesture handling with subtle press state
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          borderRadius: BorderRadius.all(r),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: content,
        ),
      ),
    );
  }
}
