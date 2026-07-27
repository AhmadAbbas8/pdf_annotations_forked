import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/plugin_state.dart';
import '../../domain/entities/added_annotation.dart';
import '../../domain/entities/line_annotation.dart';
import '../../domain/entities/text_annotation.dart';
import '../../utilities/constants.dart';
import '../../utilities/enums.dart';
import '../../utilities/errors.dart';
import '../../utilities/id_generator.dart';
import 'all_overlay_widgets.dart';
import 'current_line_renderer.dart';
import 'current_text.dart';
import 'eraser_overlay.dart';
import 'pan_layer.dart';
import 'pdf_doc_view.dart';

typedef InsertionPointSelectedCallback = Future<void> Function(double keyboardHeight);

class DrawingOverlayController extends ChangeNotifier {
  _DrawingOverlayState? _state;

  Future<void> undo() async {
    await _state?._undoLast();
  }

  Future<void> redo() async {
    await _state?._redoLast();
  }

  Future<TaskResult<SaveStateResult>> saveAnnotationsToJsonFile() async {
    if (_state == null) {
      return const Failure('DrawingOverlay is not attached.');
    }
    return await _state!._saveProgress();
  }

  double getOverlayWidthScaled() {
    return _state?._overlayWidthScaled ?? 1.0;
  }

  void _attach(_DrawingOverlayState state) {
    _state = state;
  }

  void _detach() {
    _state = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}

class DrawingOverlay extends StatefulWidget {
  final DrawingOverlayController drawingOverlayController;
  final String pdfPath;

  /// Callback to inform owner about a change in text insertion point location when the insertion point
  /// would have been under the appearing keyboard
  final InsertionPointSelectedCallback onInsertionPointModified;
  final ErrorCallback? onError;

  const DrawingOverlay({
    super.key,
    required this.drawingOverlayController,
    required this.pdfPath,
    required this.onInsertionPointModified,
    this.onError,
  });

  @override
  State<DrawingOverlay> createState() => _DrawingOverlayState();
}

class _DrawingOverlayState extends State<DrawingOverlay> with SingleTickerProviderStateMixin {
  late PluginState _pluginState;
  final _textFieldController = TextEditingController();
  final _rawGDKey = UniqueKey();
  double _selectedLineWidth = 5.0;
  final double _currentScale = 1.0;
  List<LineAnnotation> _startOfPanningLines = [];
  List<TextAnnotation> _startOfPanningTexts = [];
  Offset _startOfTextEntryInsertionPoint = .zero;
  Offset _vpPositionAtStartOfPanning = .zero;
  Offset _vpPosition = .zero;
  double _scaleAtStartOfPanning = 1.0;
  late double _devPixRatio;
  List<AddedAnnotation> _addedAnnotations = [];

  /// Maps an [AddedAnnotation.id] of type [kEraseOperation] to the original
  /// annotation id and the fragment ids that replaced it. Used by undo/redo.
  final Map<String, _SplitRecord> _splitRecords = {};
  late final AnimationController _animationController;
  late final CurvedAnimation _curvedAnimation;
  late Animation<double> _lineAnnotationsAnimation;
  late Function() _lineAnimationListener;
  late Animation<double> _textAnnotationsAnimation;
  late Function() _textAnimationListener;
  late Animation<double> _currentTextAnimation;
  late Function() _currentTextAnimationListener;
  late double _overlayWidthScaled;
  late double _overlayHeightScaled;
  bool _keyboardActive = false;
  TextAnnotation? _currentTextAnnotation;
  bool _didChangeDependenciesRun = false;
  late Color _annotationColour;

  late final CurrentText _currentText = CurrentText(
    textFieldController: _textFieldController,
    scale: _currentScale,
    onTapUp: _onTextTapUp,
    onTapOutside: _onTapOutside,
    onFirstCharacterEntry: _clearUndoList,
  );

  late final Widget _currentLine = Positioned.fill(
    child: GestureDetector(
      onDoubleTap: () {},
      onScaleStart: _onLineScaleStart,
      onScaleUpdate: _onLineScaleUpdate,
      onScaleEnd: _onLineScaleEnd,
      behavior: .opaque,
      child: const RepaintBoundary(child: CurrentLineRenderer()),
    ),
  );

  late final PanLayer _panLayer = PanLayer(gDKey: _rawGDKey, onDragStart: _onPanDragStart);

  /// Built lazily; rebuilds whenever either line or text annotations change
  /// so the eraser always sees the current state of both annotation lists.
  Widget get _eraserLayer => ListenableBuilder(
    listenable: Listenable.merge([
      _pluginState.lineAnnotationsListNotifier,
      _pluginState.textAnnotationsListNotifier,
    ]),
    builder: (context, _) {
      return EraserOverlay(
        lineAnnotations: _pluginState.lineAnnotationsListNotifier.value,
        textAnnotations: _pluginState.textAnnotationsListNotifier.value,
        onStrokeSplit: _onStrokeSplit,
        onTextAnnotationErased: _onTextAnnotationErased,
        onEraserSessionStart: _onEraserSessionStart,
        onEraserSessionEnd: _onEraserSessionEnd,
      );
    },
  );

  @override
  void initState() {
    super.initState();
    widget.drawingOverlayController._attach(this);

    _animationController = AnimationController(
      duration: const Duration(milliseconds: kAnnotationsAnimationDuration),
      vsync: this,
    );
    _curvedAnimation = CurvedAnimation(parent: _animationController, curve: Curves.decelerate);
    _currentTextAnimationListener = () {
      final deltaY = _currentTextAnimation.value;
      _pluginState.textInsertionPointNotifier.setAbsolute(
        _startOfTextEntryInsertionPoint + Offset(0.0, deltaY),
      );
    };
    _lineAnimationListener = () {
      final deltaY = _lineAnnotationsAnimation.value;
      _pluginState.lineAnnotationsListNotifier.setAnnotations(
        _startOfPanningLines
            .map(
              (annotation) => annotation.copyWith(
                line: annotation.line.map((offset) => offset.translate(0, deltaY)).toList(),
              ),
            )
            .toList(),
      );
    };
    _textAnimationListener = () {
      final deltaY = _textAnnotationsAnimation.value;
      _pluginState.textAnnotationsListNotifier.setAnnotations(
        _startOfPanningTexts
            .map(
              (annotation) => annotation.copyWith(coordinate: annotation.coordinate + Offset(0, deltaY)),
            )
            .toList(),
      );
    };
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _updateViewportPosition();
      _scaleAtStartOfPanning = _pluginState.pdfScaleNotifier.value;
      await _loadPreviousSave();
      _pluginState.updateUndoRedoEnabledState();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pluginState = PluginStateProvider.of(context);
    _setAnnotationColour();
    _setLineWidth();
    _scaleAtStartOfPanning = _pluginState.pdfScaleNotifier.value;

    if (_didChangeDependenciesRun) {
      return;
    }
    _didChangeDependenciesRun = true;
    _pluginState.pdfOffsetNotifier.addListener(_onTransformChanged);
    _pluginState.pdfScaleNotifier.addListener(_onTransformChanged);
    _pluginState.keyboardHeightNotifier.addListener(_keyboardHeightUpdate);
    _pluginState.annotationColourNotifier.addListener(_setAnnotationColour);
    _pluginState.lineModeNotifier.addListener(_setLineWidth);
    _pluginState.textInsertionPointNotifier.addListener(_updateTextInsertionPoint);
    _pluginState.editModeNotifier.addListener(_handleEditModeChange);
    _pluginState.currentLineAnnotationNotifier.addListener(_updateCurrentLineStream);
    _pluginState.textAnnotationsListNotifier.addListener(_updateTextsStream);
    _pluginState.lineAnnotationsListNotifier.addListener(_updateLinesStream);
  }

  @override
  void didUpdateWidget(covariant DrawingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.drawingOverlayController != oldWidget.drawingOverlayController) {
      oldWidget.drawingOverlayController._detach();
      widget.drawingOverlayController._attach(this);
    }
  }

  @override
  void dispose() {
    _pluginState.pdfOffsetNotifier.removeListener(_onTransformChanged);
    _pluginState.pdfScaleNotifier.removeListener(_onTransformChanged);
    _pluginState.keyboardHeightNotifier.removeListener(_keyboardHeightUpdate);
    _pluginState.annotationColourNotifier.removeListener(_setAnnotationColour);
    _pluginState.lineModeNotifier.removeListener(_setLineWidth);
    _pluginState.textInsertionPointNotifier.removeListener(_updateTextInsertionPoint);
    _pluginState.editModeNotifier.removeListener(_handleEditModeChange);
    _pluginState.currentLineAnnotationNotifier.removeListener(_updateCurrentLineStream);
    _pluginState.textAnnotationsListNotifier.removeListener(_updateTextsStream);
    _pluginState.lineAnnotationsListNotifier.removeListener(_updateLinesStream);

    widget.drawingOverlayController._detach();
    _animationController.dispose();
    _textFieldController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _initializePixRatios();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _overlayHeightScaled = constraints.maxHeight * _devPixRatio;
        _overlayWidthScaled = constraints.maxWidth * _devPixRatio;
        return ValueListenableBuilder<EditMode>(
          valueListenable: _pluginState.editModeNotifier,
          builder: (context, currentEditMode, child) {
            return AllOverlayWidgets(
              currentText: _currentText,
              currentLine: _currentLine,
              eraserLayer: _eraserLayer,
              panLayer: _panLayer,
              selectedEditMode: currentEditMode,
            );
          },
        );
      },
    );
  }

  void _initializePixRatios() {
    _devPixRatio = MediaQuery.devicePixelRatioOf(context);
  }

  void _updateViewportPosition() {
    _vpPosition = _vpPositionAtStartOfPanning = _pluginState.pdfOffsetNotifier.value;
  }

  void _onTransformChanged() {
    if (!_keyboardActive) {
      final newVp = _pluginState.pdfOffsetNotifier.value;
      final newScale = _pluginState.pdfScaleNotifier.value;
      final currentScaleAtStart = _scaleAtStartOfPanning == 0.0 ? 1.0 : _scaleAtStartOfPanning;

      if ((_startOfPanningLines.isEmpty && _pluginState.lineAnnotationsListNotifier.value.isNotEmpty) ||
          _startOfPanningLines.length != _pluginState.lineAnnotationsListNotifier.value.length) {
        _setInitialMoveConditions();
      }
      if ((_startOfPanningTexts.isEmpty && _pluginState.textAnnotationsListNotifier.value.isNotEmpty) ||
          _startOfPanningTexts.length != _pluginState.textAnnotationsListNotifier.value.length) {
        _setInitialMoveConditions();
      }

      if (_startOfPanningLines.isNotEmpty) {
        final transformedLines = _startOfPanningLines.map((annotation) {
          final transformedPoints = annotation.line.map((point) {
            final pointPdf = (point - _vpPositionAtStartOfPanning) / currentScaleAtStart;
            return (pointPdf * newScale) + newVp;
          }).toList();
          final newWidth = (annotation.width / currentScaleAtStart) * newScale;
          return annotation.copyWith(line: transformedPoints, width: newWidth);
        }).toList();
        _pluginState.lineAnnotationsListNotifier.setAnnotations(transformedLines);
      }

      if (_startOfPanningTexts.isNotEmpty) {
        final transformedTexts = _startOfPanningTexts.map((annotation) {
          final coordPdf = (annotation.coordinate - _vpPositionAtStartOfPanning) / currentScaleAtStart;
          final newCoord = (coordPdf * newScale) + newVp;
          final sizePdf = annotation.renderedFontSize / currentScaleAtStart;
          final newFontSize = sizePdf * newScale;
          final pdfFontSizePdf = annotation.pdfFontSize / currentScaleAtStart;
          final newPdfFontSize = pdfFontSizePdf * newScale;

          return annotation.copyWith(
            coordinate: newCoord,
            renderedFontSize: newFontSize,
            pdfFontSize: newPdfFontSize,
          );
        }).toList();
        _pluginState.textAnnotationsListNotifier.setAnnotations(transformedTexts);
      }

      _vpPosition = newVp;
    }
  }

  Future<void> _keyboardHeightUpdate() async {
    if (!_pluginState.isPopInvoked) {
      await _handleKeyboardHeight(_pluginState.keyboardHeightNotifier.value);
    }
  }

  void _setAnnotationColour() {
    _annotationColour = _pluginState.annotationColour;
    if (_pluginState.editMode == EditMode.text && _currentTextAnnotation != null) {
      _currentTextAnnotation = _currentTextAnnotation?.copyWith(colour: _annotationColour);
    }
  }

  void _setLineWidth() {
    _selectedLineWidth = _pluginState.lineModeNotifier.value == LineMode.pen ? 5.0 : 15.0;
  }

  void _updateTextInsertionPoint() {
    if (_pluginState.editMode == EditMode.text && _currentTextAnnotation != null) {
      _currentTextAnnotation = _currentTextAnnotation?.copyWith(
        coordinate: _pluginState.textInsertionPoint,
      );
    }
  }

  void _setInitialMoveConditions() {
    _startOfPanningLines = List.from(_pluginState.lineAnnotationsListNotifier.value);
    _startOfPanningTexts = List.from(_pluginState.textAnnotationsListNotifier.value);
    _vpPositionAtStartOfPanning = _vpPosition;
    _scaleAtStartOfPanning = _pluginState.pdfScaleNotifier.value;
  }

  void _handleEditModeChange() {
    _setInitialMoveConditions();
    if (_pluginState.editModeNotifier.value != EditMode.text && _textFieldController.text.trim().isNotEmpty) {
      _finaliseTexting();
    }
  }

  void _updateCurrentLineStream() {
    _pluginState.updateCurrentLineStream(_pluginState.currentLineAnnotationNotifier.value);
  }

  void _updateLinesStream() {
    _pluginState.updateLinesStream(_pluginState.lineAnnotationsListNotifier.value);
    _pluginState.updateUndoRedoEnabledState();
  }

  void _updateTextsStream() {
    _pluginState.updateTextsStream(_pluginState.textAnnotationsListNotifier.value);
    _pluginState.updateUndoRedoEnabledState();
  }

  void _onLineScaleStart(ScaleStartDetails details) {
    if (details.pointerCount > 1) {
      return;
    }
    _clearUndoList();
    final annotationColor = (_pluginState.lineModeNotifier.value == .highlighter)
        ? _annotationColour.withValues(alpha: kHighlighterOpacity)
        : _annotationColour;

    _pluginState.currentLineAnnotationNotifier.setCurrent(
      LineAnnotation(
        [details.localFocalPoint],
        annotationColor,
        _selectedLineWidth * _currentScale,
      ),
    );
  }

  void _clearUndoList() {
    _pluginState.lineAnnotationsListNotifier.removeInactiveAnnotations();
    _pluginState.textAnnotationsListNotifier.removeInactiveAnnotations();
    // Collect ids of inactive erase records before removing them, so we can
    // clean up the corresponding _splitRecords entries.
    final removedIds = _addedAnnotations
        .where((a) => !a.isActive && a.annotationType == kEraseOperation)
        .map((a) => a.id)
        .toSet();
    _addedAnnotations.removeWhere((annotation) => !annotation.isActive);
    for (final id in removedIds) {
      _splitRecords.remove(id);
    }
  }

  void _onLineScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > 1) {
      return;
    }
    _pluginState.currentLineAnnotationNotifier.addPoint(details.localFocalPoint);
  }

  void _onLineScaleEnd(ScaleEndDetails details) {
    var currentAnnotation = _pluginState.currentLineAnnotationNotifier.value;
    _pluginState.resetCurrentLineAnnotationNotifier();
    if (currentAnnotation.line.isNotEmpty) {
      _pluginState.lineAnnotationsListNotifier.addAnnotation(currentAnnotation);
      _addedAnnotations.add(AddedAnnotation(kLineAnnotation, currentAnnotation.id));
      _setInitialMoveConditions();
    }
  }

  void _onTextTapUp(TapUpDetails details) {
    _finaliseTexting(fromTextEdit: true);
    _pluginState.textInsertionPointNotifier.setAbsolute(details.localPosition);
    _startOfTextEntryInsertionPoint = details.localPosition.translate(
      0.0,
      _pluginState.cursorAdjustmentForKeyboardHeightNotifier.value,
    );
    _pluginState.textFocusNode.requestFocus();
    _pluginState.textFieldShowingNotifier.value = true;
  }

  void _onTapOutside(String text) {
    if (text.trim().isNotEmpty) {
      _currentTextAnnotation = TextAnnotation(
        text.trim(),
        _pluginState.fontFamilyNotifier.value,
        MediaQuery.textScalerOf(context).scale(_pluginState.fontSizeNotifier.value),
        MediaQuery.textScalerOf(context).scale(_pluginState.fontSizeNotifier.value) * _currentScale,
        _pluginState.textInsertionPoint,
        _annotationColour,
      );
    }
  }

  Future<void> _handleKeyboardHeight(double newKbHeight) async {
    if (newKbHeight != 0.0) {
      // keyboard showing
      _keyboardActive = true;
      await _doAnnotationKBShift(newKbHeight);
    } else {
      _finaliseTexting(forKeyboardHide: true);
      await _undoAnnotationKBShift();
      _setInitialMoveConditions();
      _keyboardActive = false;
    }
  }

  Future<void> _doAnnotationKBShift(double newKbHeight) async {
    RenderBox rb = context.findRenderObject() as RenderBox;
    final visibleHeightAfterKbShow = rb.size.height - (newKbHeight + kKeyboardToolbarHeight);
    final currentInsertionPointYPos = _pluginState.textInsertionPoint.dy;
    if (currentInsertionPointYPos > visibleHeightAfterKbShow) {
      final deltaY = currentInsertionPointYPos - visibleHeightAfterKbShow;
      _pluginState.cursorAdjustmentForKeyboardHeightNotifier.value = deltaY;
      await Future.wait([
        // move text field up to account for keyboard show
        _animateCurrentTextForKbShift(0.0, -deltaY),
        // move all drawn lines and texts up to account for keyboard show
        _animateTextAnnotationsForKbShift(0.0, -deltaY),
        _animateLineAnnotationsForKbShift(0.0, -deltaY),
        // tell pdfview it needs to move up
        widget.onInsertionPointModified(deltaY),
      ]);
    }
  }

  Future<void> _undoAnnotationKBShift() async {
    final cursorAdjustment = _pluginState.cursorAdjustmentForKeyboardHeightNotifier.value;
    if (cursorAdjustment != 0.0) {
      if (!_pluginState.popInvokedNotifier.value) {
        _pluginState.cursorAdjustmentForKeyboardHeightNotifier.value = 0.0;
        await Future.wait([
          // reset text and line annotation positions
          _animateTextAnnotationsForKbShift(-cursorAdjustment, 0.0),
          _animateLineAnnotationsForKbShift(-cursorAdjustment, 0.0),
          // tell pdfview it needs to move down
          widget.onInsertionPointModified(-cursorAdjustment),
        ]);
      } else {
        _pluginState.textAnnotationsListNotifier.setAnnotations(_startOfPanningTexts);
        _pluginState.lineAnnotationsListNotifier.setAnnotations(_startOfPanningLines);
        widget.onInsertionPointModified(-cursorAdjustment);
      }
    }
  }

  void _onPanDragStart(DragStartDetails details) {
    _setInitialMoveConditions();
  }

  // ---------------------------------------------------------------------------
  // Eraser callbacks
  // ---------------------------------------------------------------------------

  void _onEraserSessionStart() {
    // Clear the redo stack when a new erase session begins, exactly like
    // the draw tool does when a new stroke begins.
    _clearUndoList();
  }

  /// Called by [EraserOverlay] each time a stroke is (partially or fully)
  /// erased during a drag.
  ///
  /// [originalId] identifies the stroke that was hit.
  /// [fragmentPoints] contains the surviving point-groups; empty means the
  /// stroke was fully erased.
  ///
  /// This creates new [LineAnnotation] objects for each surviving fragment,
  /// inactivates the original, and records the operation so that undo/redo
  /// work correctly — one undo step per erased stroke.
  void _onStrokeSplit(String originalId, List<List<Offset>> fragmentPoints) {
    final annotations = _pluginState.lineAnnotationsListNotifier.value;
    final originalIndex = annotations.indexWhere((a) => a.id == originalId);
    if (originalIndex == -1) return;
    final original = annotations[originalIndex];

    // Create fragment annotations preserving the original style.
    final fragments = fragmentPoints
        .map((points) => LineAnnotation(points, original.colour, original.width))
        .toList();

    // Inactivate the original stroke.
    _pluginState.lineAnnotationsListNotifier.inactivateId(originalId);

    // Add surviving fragments as new active annotations.
    for (final fragment in fragments) {
      _pluginState.lineAnnotationsListNotifier.addAnnotation(fragment);
    }

    // Record the split so undo/redo can reverse it atomically.
    final entryId = generateId();
    _splitRecords[entryId] = _SplitRecord(
      originalId: originalId,
      fragmentIds: fragments.map((f) => f.id).toList(),
    );
    _addedAnnotations.add(AddedAnnotation(kEraseOperation, entryId));

    _setInitialMoveConditions();
  }

  /// Called when the eraser passes over a [TextAnnotation].
  ///
  /// Text annotations are erased whole-unit (no partial text splitting).
  /// The annotation is inactivated and recorded in [_addedAnnotations] so
  /// that undo/redo work exactly like undoing a typed text annotation.
  void _onTextAnnotationErased(String textId) {
    _pluginState.textAnnotationsListNotifier.inactivateId(textId);
    // If this text was added in the current session it already has an entry;
    // just flip its flag. Otherwise (loaded from file) create a new entry.
    final existingIndex = _addedAnnotations.indexWhere((a) => a.id == textId);
    if (existingIndex == -1) {
      _addedAnnotations.add(AddedAnnotation(kTextAnnotation, textId, false));
    } else {
      _addedAnnotations[existingIndex].isActive = false;
    }
    _pluginState.updateUndoRedoEnabledState();
    _setInitialMoveConditions();
  }

  void _onEraserSessionEnd() {
    _pluginState.updateUndoRedoEnabledState();
  }

  Future<void> _animateTextAnnotationsForKbShift(double begin, double end) {
    final Completer<void> completer = Completer<void>();
    if (_pluginState.textAnnotationsListNotifier.value.isNotEmpty) {
      if (begin == 0.0) {
        _startOfPanningTexts = _pluginState.textAnnotationsListNotifier.value;
      }
      _textAnnotationsAnimation = Tween<double>(begin: begin, end: end).animate(_curvedAnimation)
        ..addListener(_textAnimationListener);

      void statusListener(AnimationStatus status) {
        if (status == .completed) {
          _textAnnotationsAnimation.removeListener(_textAnimationListener);
          if (end == 0.0) {
            _startOfPanningTexts = [];
          }
          _textAnnotationsAnimation.removeStatusListener(statusListener);
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      }

      _textAnnotationsAnimation.addStatusListener(statusListener);

      _animationController.reset();
      _animationController.forward();
    } else {
      completer.complete();
    }
    return completer.future;
  }



  Future<void> _animateLineAnnotationsForKbShift(double begin, double end) {
    final Completer<void> completer = Completer<void>();
    if (_pluginState.lineAnnotationsListNotifier.value.isNotEmpty) {
      if (begin == 0.0) {
        _startOfPanningLines = _pluginState.lineAnnotationsListNotifier.value;
      }
      _lineAnnotationsAnimation = Tween<double>(begin: begin, end: end).animate(_curvedAnimation)
        ..addListener(_lineAnimationListener);

      void statusListener(AnimationStatus status) {
        if (status == .completed) {
          _lineAnnotationsAnimation.removeListener(_lineAnimationListener);
          if (end == 0.0) {
            _startOfPanningLines = [];
          }
          _lineAnnotationsAnimation.removeStatusListener(statusListener);
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      }

      _lineAnnotationsAnimation.addStatusListener(statusListener);

      _animationController.reset();
      _animationController.forward();
    } else {
      completer.complete();
    }
    return completer.future;
  }



  Future<void> _animateCurrentTextForKbShift(double begin, double end) {
    final Completer<void> completer = Completer<void>();
    _currentTextAnimation = Tween<double>(begin: begin, end: end).animate(_curvedAnimation)
      ..addListener(_currentTextAnimationListener);

    void statusListener(AnimationStatus status) {
      if (status == .completed) {
        _currentTextAnimation.removeListener(_currentTextAnimationListener);
        _currentTextAnimation.removeStatusListener(statusListener);
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }

    _currentTextAnimation.addStatusListener(statusListener);

    _animationController.reset();
    _animationController.forward();

    return completer.future;
  }

  void _finaliseTexting({bool fromTextEdit = false, bool forKeyboardHide = false}) {
    if (!fromTextEdit) {
      // TODO would this help for nexus
      _pluginState.textFocusNode.unfocus();
    }
    if (_textFieldController.text.trim().isNotEmpty) {
      final currentTextAnnotation =
          _currentTextAnnotation?.copyWith(coordinate: _pluginState.textInsertionPoint) ??
          TextAnnotation(
            _textFieldController.text.trim(),
            _pluginState.fontFamilyNotifier.value,
            MediaQuery.textScalerOf(context).scale(_pluginState.fontSizeNotifier.value),
            MediaQuery.textScalerOf(context).scale(_pluginState.fontSizeNotifier.value) * _currentScale,
            _pluginState.textInsertionPoint,
            _annotationColour,
          );

      if (!_pluginState.textAnnotationsListNotifier.value.contains(currentTextAnnotation)) {
        _pluginState.textAnnotationsListNotifier.addAnnotation(currentTextAnnotation);
        _addedAnnotations.add(AddedAnnotation(kTextAnnotation, currentTextAnnotation.id));
        if (forKeyboardHide) {
          _startOfPanningTexts.add(
            currentTextAnnotation.copyWith(
              coordinate:
                  _pluginState.textInsertionPoint +
                  Offset(0.0, _pluginState.cursorAdjustmentForKeyboardHeightNotifier.value),
            ),
          );
        } else {
          _setInitialMoveConditions();
        }
      }
    }
    _currentTextAnnotation = null;
    _textFieldController.clear();
  }

  Future<void> _undoLast() async {
    _finaliseTexting(fromTextEdit: true);
    final lastActiveIndex = _addedAnnotations.lastIndexWhere((annotation) => annotation.isActive);
    if (lastActiveIndex != -1) {
      final lastActiveAnnotation = _addedAnnotations[lastActiveIndex];
      Offset? position;
      if (lastActiveAnnotation.annotationType == kTextAnnotation) {
        position = _pluginState.textAnnotationsListNotifier.inactivateId(lastActiveAnnotation.id);
      } else if (lastActiveAnnotation.annotationType == kLineAnnotation) {
        position = _pluginState.lineAnnotationsListNotifier.inactivateId(lastActiveAnnotation.id);
      } else if (lastActiveAnnotation.annotationType == kEraseOperation) {
        // Undo a partial erase: restore the original stroke and remove fragments.
        final record = _splitRecords[lastActiveAnnotation.id];
        if (record != null) {
          position = _pluginState.lineAnnotationsListNotifier.activateId(record.originalId);
          for (final fragId in record.fragmentIds) {
            _pluginState.lineAnnotationsListNotifier.inactivateId(fragId);
          }
        }
      }
      _pluginState.updateUndoRedoEnabledState();
      _pluginState.lastUndoNotifier.value = (
        id: lastActiveAnnotation.id,
        type: lastActiveAnnotation.annotationType,
      );
      lastActiveAnnotation.isActive = false;
      _setInitialMoveConditions();
      if (position != null && !_pluginState.textFocusNode.hasFocus) {
        await _setPdfOffset(position);
      }
    }
  }

  Future<void> _redoLast() async {
    _finaliseTexting(fromTextEdit: true);
    final firstInactiveIndex = _addedAnnotations.indexWhere((annotation) => !annotation.isActive);
    if (firstInactiveIndex != -1) {
      final firstInactiveAnnotation = _addedAnnotations[firstInactiveIndex];
      Offset? position;
      if (firstInactiveAnnotation.annotationType == kTextAnnotation) {
        position = _pluginState.textAnnotationsListNotifier.activateId(firstInactiveAnnotation.id);
      } else if (firstInactiveAnnotation.annotationType == kLineAnnotation) {
        position = _pluginState.lineAnnotationsListNotifier.activateId(firstInactiveAnnotation.id);
      } else if (firstInactiveAnnotation.annotationType == kEraseOperation) {
        // Redo a partial erase: re-apply the split (hide original, show fragments).
        final record = _splitRecords[firstInactiveAnnotation.id];
        if (record != null) {
          position = _pluginState.lineAnnotationsListNotifier.inactivateId(record.originalId);
          for (final fragId in record.fragmentIds) {
            _pluginState.lineAnnotationsListNotifier.activateId(fragId);
          }
        }
      }
      _pluginState.updateUndoRedoEnabledState();
      _pluginState.lastRedoNotifier.value = (
        id: firstInactiveAnnotation.id,
        type: firstInactiveAnnotation.annotationType,
      );
      firstInactiveAnnotation.isActive = true;
      _setInitialMoveConditions();
      if (position != null && !_pluginState.textFocusNode.hasFocus) {
        await _setPdfOffset(position);
      }
    }
  }

  Future<void> _setPdfOffset(Offset position) async {
    final pdfPageSize = await _pluginState.pdfViewControllerNotifier.value?.getCurrentPageSize() ?? .zero;
    final pageCount = await _pluginState.pdfViewControllerNotifier.value?.getPageCount() ?? 1;
    final pdfHeightLimit = pageCount * pdfPageSize.height - _overlayHeightScaled;
    final yTranslation = -(position.dy - 100.0);
    final newPdfOffset = _pluginState.pdfOffsetNotifier.value.translate(0.0, yTranslation);
    if (!newPdfOffset.dy.isNegative) {
      // new offset is above pdf top
      _pluginState.pdfOffsetNotifier.value = .zero;
      return;
    }

    if (newPdfOffset.dy < -pdfHeightLimit) {
      // new offset is below pdf bottom
      _pluginState.pdfOffsetNotifier.value = Offset(0.0, -pdfHeightLimit);
      return;
    }

    _pluginState.pdfOffsetNotifier.value = newPdfOffset;
  }

  Future<TaskResult<List<AddedAnnotation>>> _loadPreviousSave() async {
    final result = await _pluginState.loadPreviousSavedJson(
      pdfPath: widget.pdfPath,
      viewportPosition: _vpPosition,
      scaledOverlayWidth: _overlayWidthScaled,
      shortestSideEstimate: MediaQuery.sizeOf(context).shortestSide,
    );

    if (result case Success(:final data)) {
      _addedAnnotations = data;
      _setInitialMoveConditions();
    }

    return result;
  }

  Future<TaskResult<SaveStateResult>> _saveProgress() async {
    final kbHeight = _pluginState.keyboardHeightNotifier.value;
    if (kbHeight != 0.0) {
      await _handleKeyboardHeight(0.0);
    } else {
      _finaliseTexting();
    }

    return await _pluginState.saveAnnotationsToJson(
      pdfPath: widget.pdfPath,
      viewportPosition: _vpPosition,
      scaledOverlayWidth: _overlayWidthScaled,
      addedAnnotations: _addedAnnotations,
    );
  }
}

/// Stores the data for one partial-erase event so that undo/redo can reverse
/// or re-apply the split.
///
/// [originalId] is the id of the stroke that was erased (partially or fully).
/// [fragmentIds] are the ids of the new shorter strokes that replaced it.
/// An empty [fragmentIds] means the stroke was fully erased with no survivors.
class _SplitRecord {
  final String originalId;
  final List<String> fragmentIds;

  const _SplitRecord({required this.originalId, required this.fragmentIds});
}
