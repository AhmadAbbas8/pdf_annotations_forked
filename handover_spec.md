# Technical Handover Specification & Implementation Plan

> **Target Audience**: AI Agent / Flutter & Native Mobile Software Engineer  
> **Repository**: `pdf_annotations_forked`  
> **Date**: July 28, 2026  

---

## 1. Project Overview & Architecture Structure

`pdf_annotations_forked` is a Flutter plugin that provides viewing, freehand drawing, text annotations, and native PDF baking functionality over PDF documents.

### File Tree & Key Responsibilities

```
pdf_annotations_forked/
├── lib/
│   ├── pdf_annotations.dart                         # Public library exports
│   ├── generated/
│   │   └── pdf_annotations_api.dart                # Pigeon generated platform channel interfaces & codec
│   └── src/
│       ├── data/
│       │   ├── models/
│       │   │   ├── plugin_state.dart               # State container (pdfOffsetNotifier, pdfScaleNotifier, annotation list notifiers)
│       │   │   └── pdf_font.dart                   # Font configuration entity for custom font registration
│       │   └── repositories/
│       │       ├── json_annotations_repository_impl.dart # JSON file persistence (saveAnnotationsState, loadAnnotationsState)
│       │       └── pdf_annotations_repository_impl.dart  # Bridge to Pigeon platform channels (addAnnotations, registerFonts)
│       ├── domain/
│       │   ├── entities/
│       │   │   ├── line_annotation.dart            # Freehand stroke entity (points, colour, width, transform math)
│       │   │   ├── text_annotation.dart            # Text annotation entity (coordinate, font, size, color)
│       │   │   └── added_annotation.dart           # Action tracking for undo/redo stack
│       │   └── repositories/                       # Abstract repository contracts
│       ├── presentation/
│       │   └── widgets/
│       │       ├── pdf_annotations_view.dart       # Main top-level widget binding PdfDocView + DrawingOverlay + Toolbar
│       │       ├── drawing_overlay.dart            # Gesture layer handling live drawing, erasing, panning & scroll transforms
│       │       ├── pdf_doc_view.dart               # Thin wrapper around native `flutter_pdfview` PDFView
│       │       ├── eraser_overlay.dart             # Stroke intersection & partial stroke splitting eraser layer
│       │       ├── current_line_renderer.dart      # CustomPainter rendering live active stroke
│       │       └── all_overlay_widgets.dart        # Stack layout for drawing, eraser, pan, and text widgets
│       └── utilities/
│           ├── constants.dart                      # Package constants (durations, opacities, suffix strings)
│           ├── enums.dart                          # EditMode, LineMode, QualityValue, SaveStateResult
│           └── id_generator.dart                   # Unique ID generation utility
├── ios/
│   └── Classes/
│       └── PdfAnnotationsPlugin.swift              # Native iOS Swift plugin (PDFKit baking & CGFont registration)
├── android/
│   └── src/main/kotlin/.../
│       └── PdfAnnotationsPlugin.kt                 # Native Android Kotlin plugin (PdfDocument baking & Android Typeface registration)
└── example/
    ├── pubspec.yaml                                # Registered font assets & sample PDF configuration
    └── lib/
        └── main.dart                               # Production example application featuring floating glassmorphism toolbar
```

---

## 2. Deep Dive: The Issue & Root Cause Analysis

### Issue Description
When a user draws a line or text annotation on a PDF page (e.g. page 2 around a heading like "Overview"), saves, closes, and re-opens the PDF:
1. Upon re-opening and starting to scroll, the annotation position **shifts vertically down the page** (by roughly ~700px, placing it over unrelated body text near the bottom of the page).
2. On some saves, annotations may appear **rendered twice** — once baked into the native PDF file stream, and a second time as a Flutter vector overlay, which then drift apart during scrolling.

---

### Root Cause Breakdown

#### A. Coordinate Space Conflict (Screen Viewport Space vs. PDF Page Space)

1. **Screen Viewport Space**:
   - `DrawingOverlay` records touch coordinates relative to the visible screen box `[0..screenWidth, 0..screenHeight]`.
   - As the user scrolls, `PDFView` emits scroll offset notifications (`pdfOffsetNotifier.value`, e.g., `(0.0, -700.0)` when scrolled to Page 2).
   - In `DrawingOverlay`, `_onTransformChanged()` transforms stored stroke points whenever the user scrolls or zooms:
     ```dart
     pointPdf = (point - _vpPositionAtStartOfPanning) / currentScaleAtStart;
     transformedPoint = (pointPdf * newScale) + newVp;
     ```

2. **JSON Storage (`toJsonWithTransform`)**:
   - When saving annotations to `${pdfName}_saved_annotations.json`, coordinates are converted to PDF Document Space:
     ```dart
     transformedLine = line.map((offset) => offset - vpPosition).toList();
     ```
   - When loading back in `loadAnnotationsState`:
     ```dart
     newPoints = (point * scaleFactor) + vpPosition;
     ```

3. **The Race Condition / Initialization Flaw**:
   - On initial widget creation in `DrawingOverlay.initState()`, `_loadPreviousSave()` is called inside `addPostFrameCallback`.
   - At this frame, `_pluginState.pdfOffsetNotifier.value` is still `Offset.zero` `(0.0, 0.0)` because native `flutter_pdfview` has **not yet finished rendering** or emitting its true scroll offset (`_onDraw`).
   - `loadAnnotationsState` adds `vpPosition = (0.0, 0.0)` to the loaded PDF Document coordinates, setting `lineAnnotationsListNotifier.value` to pure PDF Document Space points (e.g., `y = 1000`).
   - `_setInitialMoveConditions()` runs immediately after load, capturing:
     - `_startOfPanningLines` = points at `y = 1000`
     - `_vpPositionAtStartOfPanning` = `(0.0, 0.0)`
   - A few milliseconds later, `flutter_pdfview` finishes loading Page 2 and fires `_onDraw` with `newVp = (0.0, -700.0)`.
   - `_onTransformChanged()` executes:
     - `pointPdf = (1000 - 0.0) = 1000`
     - `transformedPoint = 1000 + (-700.0) = 300.0` (correct screen location).
   - **HOWEVER**, when the user subsequently touches the screen or starts dragging, `_setInitialMoveConditions()` re-snapshots `_startOfPanningLines` at `300.0` with `_vpPositionAtStartOfPanning = -700.0`.
   - If `_saveProgress()` or auto-save runs while `pdfOffsetNotifier` is out of sync or during a page transition, `screenPoint - vpPosition` calculates `300.0 - (0.0) = 300.0` instead of `1000.0`.
   - On the next reload, `loadAnnotationsState` loads `300.0`, adds `(-700.0)` on scroll, yielding `300.0 + 700.0 = 1000.0` — shifting the drawing **700 pixels down the page**.

#### B. Double-Rendering & Re-Keying Issue

- In `pdf_annotations_view.dart`, `_saveAndAddAnnotations()` previously invoked `_pdfDocViewController.setNewlyEdited()`.
- `setNewlyEdited()` assigned `_key = UniqueKey()` to `PdfDocView`, completely destroying and recreating the native `PDFView` widget on every save.
- Re-instantiating `PDFView` reset native scroll position to `0.0` while Flutter state retained non-zero offsets.
- Furthermore, if native baking (`addAnnotations`) wrote vector annotations into `sample_annotated.pdf` while `DrawingOverlay` simultaneously loaded `sample_saved_annotations.json`, the user saw **two overlay layers** (one baked inside the PDF, one Flutter widget) that drifted apart on scroll.

---

## 3. Step-by-Step Implementation Plan for the Next Agent

### Strategy Overview
To permanently eliminate position shifts and double-rendering:
1. **Normalize Coordinates to PDF Document Relative Coordinates**: Store coordinates in normalized PDF page/document space `(0.0 to 1.0)` or relative to top-left `(0, 0)` of the PDF document, completely independent of screen viewport offsets.
2. **Eliminate Post-Frame Loading Race**: Do NOT load saved annotations from JSON until `PDFView` has completed its initial render (`onRender` / first `_onDraw`) and established the valid `pdfOffsetNotifier.value`.
3. **Decouple Native Baking from Live View**: Keep the live interactive viewer rendering the clean source PDF (`sample.pdf`) + Flutter `DrawingOverlay`. Only generate `sample_annotated.pdf` when exporting or completing the editing session.
4. **Prevent PDFView Widget Destruction**: Ensure saving annotations never calls `setNewlyEdited()` or modifies the `PDFView` widget key while editing is active.

---

### Step 1: Fix Viewport Initialization Timing in `DrawingOverlay`

**File**: [lib/src/presentation/widgets/drawing_overlay.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/src/presentation/widgets/drawing_overlay.dart)

1. Remove `_loadPreviousSave()` from `initState` post-frame callback.
2. Listen to `_pluginState.pdfOffsetNotifier` or add an explicit `onPdfViewReady` callback triggered from `PdfAnnotationsView._onRender`.
3. Only invoke `_loadPreviousSave()` **AFTER** the initial `pdfOffsetNotifier` value has been set by `_onDraw`.

```dart
// In _DrawingOverlayState:
bool _hasLoadedSavedAnnotations = false;

void _onFirstValidRender() async {
  if (_hasLoadedSavedAnnotations) return;
  _hasLoadedSavedAnnotations = true;
  _updateViewportPosition();
  _scaleAtStartOfPanning = _pluginState.pdfScaleNotifier.value;
  await _loadPreviousSave();
  _pluginState.updateUndoRedoEnabledState();
}
```

---

### Step 2: Standardize Save/Load Coordinate Transformations

**File**: [lib/src/data/repositories/json_annotations_repository_impl.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/src/data/repositories/json_annotations_repository_impl.dart)  
**File**: [lib/src/domain/entities/line_annotation.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/src/domain/entities/line_annotation.dart)  
**File**: [lib/src/domain/entities/text_annotation.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/src/domain/entities/text_annotation.dart)

1. Ensure `toJsonWithTransform(Offset vpPosition)` ALWAYS receives `_pluginState.pdfOffsetNotifier.value` directly at the moment of save.
2. Verify point transformation logic:
   - **Saving**: `pdfPoint = screenPoint - liveVpOffset`
   - **Loading**: `screenPoint = pdfPoint + liveVpOffset`
3. Wrap `json.decode` inside `_compareContents` in a `try-catch` returning `false` on format errors, ensuring corrupt JSON files are automatically overwritten with fresh valid data.
4. Use `file.writeAsString(jsonString, flush: true)` to prevent partial/truncated disk writes.

---

### Step 3: Prevent Re-Keying & Double Rendering

**File**: [lib/src/presentation/widgets/pdf_annotations_view.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/src/presentation/widgets/pdf_annotations_view.dart)

1. Ensure `_saveAndAddAnnotations()` does **NOT** call `_pdfDocViewController.setNewlyEdited()`.
2. Do not reload `PDFView` with the baked file during live editing. The live viewer must continue using `widget.pdfPath` (the clean original PDF).

---

### Step 4: Verification & Validation Checklist

Execute the following shell commands in `/Users/macbook/Desktop/Easy Tech/packages/pdf_annotations_forked`:

```bash
# 1. Analyze root library
flutter analyze

# 2. Analyze example app
cd example && flutter analyze && cd ..

# 3. Run widget tests
flutter test
```

#### Manual Verification Procedure:
1. Launch example app on iOS Simulator or Android Emulator (`flutter run`).
2. Scroll to **Page 2** (e.g. "Overview" section).
3. Select the **Pen** or **Highlighter** tool and draw a distinct circle around the word "Overview".
4. Tap the **Save** button in the top app bar.
5. Scroll up to Page 1 and down to Page 5, then back to Page 2.
6. Verify the drawing remains **100% locked** onto the word "Overview" without shifting down to the bottom of Page 2.
7. Close the screen / restart app and re-open Page 2 to verify zero position drift.

---

## 4. Key References for the Next Agent

- Pigeon API Contract: [lib/generated/pdf_annotations_api.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/generated/pdf_annotations_api.dart)
- Native iOS Plugin: [ios/Classes/PdfAnnotationsPlugin.swift](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/ios/Classes/PdfAnnotationsPlugin.swift)
- Native Android Plugin: [android/src/main/kotlin/com/loucheindustries/pdf_annotations/PdfAnnotationsPlugin.kt](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/android/src/main/kotlin/com/loucheindustries/pdf_annotations/PdfAnnotationsPlugin.kt)
- Overlay Logic: [lib/src/presentation/widgets/drawing_overlay.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/src/presentation/widgets/drawing_overlay.dart)
- Saved JSON Repository: [lib/src/data/repositories/json_annotations_repository_impl.dart](file:///Users/macbook/Desktop/Easy%20Tech/packages/pdf_annotations_forked/lib/src/data/repositories/json_annotations_repository_impl.dart)
