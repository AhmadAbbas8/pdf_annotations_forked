import 'package:flutter/material.dart';

import '../../domain/entities/line_annotation.dart';
import '../../domain/entities/text_annotation.dart';

/// Radius in logical pixels around the drag point within which stroke points
/// are considered inside the eraser.
const double kEraserRadius = 20.0;

/// Called when a stroke is (partially or fully) erased.
///
/// [originalAnnotationId] is the id of the stroke that was hit.
/// [fragmentPoints] contains the surviving contiguous point-groups. An empty
/// list means the stroke was fully erased with nothing left.
typedef StrokeSplitCallback = void Function(
  String originalAnnotationId,
  List<List<Offset>> fragmentPoints,
);

/// Overlay widget for [EditMode.erase].
///
/// Tracks pointer drag gestures. On each drag update it checks all active
/// [LineAnnotation]s and [TextAnnotation]s for intersection with the eraser
/// circle:
///
/// - **Lines**: the surviving point-groups (fragments) are returned via
///   [onStrokeSplit]; the caller creates the new fragment annotations.
/// - **Texts**: erased whole-unit via [onTextAnnotationErased]; partial text
///   erasing is not applicable.
///
/// Also renders a circular eraser cursor that follows the pointer.
class EraserOverlay extends StatefulWidget {
  final List<LineAnnotation> lineAnnotations;
  final List<TextAnnotation> textAnnotations;
  final StrokeSplitCallback onStrokeSplit;
  final void Function(String textAnnotationId) onTextAnnotationErased;
  final VoidCallback onEraserSessionStart;
  final VoidCallback onEraserSessionEnd;

  const EraserOverlay({
    super.key,
    required this.lineAnnotations,
    required this.textAnnotations,
    required this.onStrokeSplit,
    required this.onTextAnnotationErased,
    required this.onEraserSessionStart,
    required this.onEraserSessionEnd,
  });

  @override
  State<EraserOverlay> createState() => _EraserOverlayState();
}

class _EraserOverlayState extends State<EraserOverlay> {
  Offset? _cursorPosition;

  // Ids of annotations already processed in the current drag session so we
  // don't re-process the same annotation twice in one gesture.
  final Set<String> _processedInSession = {};

  void _onScaleStart(ScaleStartDetails details) {
    if (details.pointerCount > 1) return;
    _processedInSession.clear();
    widget.onEraserSessionStart();
    setState(() => _cursorPosition = details.localFocalPoint);
    _hitTest(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > 1) return;
    setState(() => _cursorPosition = details.localFocalPoint);
    _hitTest(details.localFocalPoint);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    setState(() => _cursorPosition = null);
    widget.onEraserSessionEnd();
  }

  /// Checks every active [LineAnnotation] and [TextAnnotation] against the
  /// eraser circle centred at [pointer] and fires the appropriate callback for
  /// each hit.
  void _hitTest(Offset pointer) {
    final double radiusSq = kEraserRadius * kEraserRadius;

    // ── Line annotations ────────────────────────────────────────────────────
    for (final annotation in widget.lineAnnotations) {
      if (!annotation.isActive) continue;
      if (_processedInSession.contains(annotation.id)) continue;

      final bool hit = annotation.line.any((point) {
        final dx = point.dx - pointer.dx;
        final dy = point.dy - pointer.dy;
        return (dx * dx + dy * dy) <= radiusSq;
      });

      if (hit) {
        _processedInSession.add(annotation.id);
        final fragments = _computeFragments(annotation.line, pointer, radiusSq);
        widget.onStrokeSplit(annotation.id, fragments);
      }
    }

    // ── Text annotations (whole-unit erase) ─────────────────────────────────
    for (final annotation in widget.textAnnotations) {
      if (!annotation.isActive) continue;
      if (_processedInSession.contains(annotation.id)) continue;

      final Rect bounds = _textBoundingRect(annotation);
      if (_circleIntersectsRect(pointer, radiusSq, bounds)) {
        _processedInSession.add(annotation.id);
        widget.onTextAnnotationErased(annotation.id);
      }
    }
  }

  // ── Geometry helpers ───────────────────────────────────────────────────────

  /// Splits [points] into contiguous groups that lie **outside** the eraser
  /// circle. Groups with fewer than 2 points are discarded.
  List<List<Offset>> _computeFragments(
    List<Offset> points,
    Offset eraserCenter,
    double radiusSq,
  ) {
    if (points.isEmpty) return [];

    final List<List<Offset>> result = [];
    List<Offset> current = [];

    for (final point in points) {
      final dx = point.dx - eraserCenter.dx;
      final dy = point.dy - eraserCenter.dy;
      final insideEraser = (dx * dx + dy * dy) <= radiusSq;

      if (!insideEraser) {
        current.add(point);
      } else {
        if (current.length >= 2) {
          result.add(List.of(current));
        }
        current = [];
      }
    }

    if (current.length >= 2) {
      result.add(List.of(current));
    }

    return result;
  }

  /// Estimates the bounding rectangle of a [TextAnnotation] using its
  /// [TextAnnotation.coordinate] as the top-left origin and
  /// [TextAnnotation.renderedFontSize] / text length for dimensions.
  ///
  /// Font rendering is device-dependent, so this is an approximation. In
  /// practice it is accurate enough for eraser hit-testing.
  static Rect _textBoundingRect(TextAnnotation annotation) {
    // Average character width ≈ 55 % of the em-size.
    final estimatedWidth = (annotation.text.length * annotation.renderedFontSize * 0.55)
        .clamp(annotation.renderedFontSize, double.infinity);
    final estimatedHeight = annotation.renderedFontSize * 1.6;
    return Rect.fromLTWH(
      annotation.coordinate.dx,
      annotation.coordinate.dy,
      estimatedWidth,
      estimatedHeight,
    );
  }

  /// Returns `true` when the circle (centre [center], squared radius
  /// [radiusSq]) intersects [rect].
  static bool _circleIntersectsRect(Offset center, double radiusSq, Rect rect) {
    final closestX = center.dx.clamp(rect.left, rect.right);
    final closestY = center.dy.clamp(rect.top, rect.bottom);
    final dx = center.dx - closestX;
    final dy = center.dy - closestY;
    return (dx * dx + dy * dy) <= radiusSq;
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        behavior: HitTestBehavior.opaque,
        child: _cursorPosition == null
            ? const SizedBox.expand()
            : CustomPaint(
                isComplex: false,
                painter: _EraserCursorPainter(position: _cursorPosition!),
              ),
      ),
    );
  }
}

/// Paints a semi-transparent circular eraser cursor at [position].
class _EraserCursorPainter extends CustomPainter {
  final Offset position;

  const _EraserCursorPainter({required this.position});

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.grey.shade600
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawCircle(position, kEraserRadius, fillPaint);
    canvas.drawCircle(position, kEraserRadius, borderPaint);
  }

  @override
  bool shouldRepaint(_EraserCursorPainter oldDelegate) =>
      oldDelegate.position != position;
}
