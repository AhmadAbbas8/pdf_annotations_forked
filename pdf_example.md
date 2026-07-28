# 📄 PDF Annotations — Full Agent Implementation Guide

> **Purpose**: This document is a complete, self-contained reference for an AI agent to implement a PDF viewer with annotation capabilities using the `pdf_annotations` (forked) package inside the **Booklet** Flutter project.
> It covers package setup, every public API, architecture decisions already made in the project, and a full working example that mirrors the UI shown in the screenshots (toolbar with pan / pen / highlighter / text / eraser, undo-redo, bookmark pages, and auto-save).

---

## Table of Contents

1. [Package Reference](#1-package-reference)
2. [Project Context](#2-project-context)
3. [Architecture Overview](#3-architecture-overview)
4. [Public API Reference](#4-public-api-reference)
5. [File Structure](#5-file-structure)
6. [Complete Working Example — Minimal Single-File](#6-complete-working-example--minimal-single-file)
7. [Full Production Example — All Project Files](#7-full-production-example--all-project-files)
8. [Key Patterns & Gotchas](#8-key-patterns--gotchas)
9. [Dependency & pubspec Setup](#9-dependency--pubspec-setup)
10. [Test PDF URLs](#10-test-pdf-urls)

---

## 1. Package Reference

| Property | Value |
|---|---|
| Package name | `pdf_annotations` |
| Source | Git fork — `https://github.com/AhmadAbbas8/pdf_annotations_forked.git` |
| Pinned commit | `d1b1f4a6ccfb7b6b478c353670144af48325458e` |
| Original repo | `https://github.com/JaseElder/pdf_annotations` |
| Platforms | Android ✅ · iOS ✅ |
| Main import | `package:pdf_annotations/pdf_annotations.dart` |

### What the package provides

- **`PdfAnnotationsView`** — the core widget that renders a PDF and accepts annotations.
- **`PdfAnnotationsViewController`** — controller to drive the view programmatically.
- **`EditMode`** enum — `pan`, `draw`, `text`, `erase`.
- **`LineMode`** enum — `pen`, `highlighter`.
- **`PdfFont`** — data class to register custom fonts for text annotations.

---

## 2. Project Context

The **Booklet** app (`name: booklet`) is a Flutter PDF reader for Android and iOS.

### Relevant existing packages (already in `pubspec.yaml`)

```yaml
flutter_bloc: ^9.1.1           # State management (Cubit pattern)
flutter_riverpod: ^2.6.1       # Used for simple loading states (e.g. download progress)
dio: ^5.9.0                    # HTTP client for downloading PDFs
path_provider: ^2.1.5          # Local file storage
screen_protector: ^1.4.8       # Prevent screenshots for DRM books
hive_ce: ^2.19.3               # Local cache (bookmarks, page references)
easy_localization: ^3.0.8      # i18n (Arabic RTL is primary language)
```

### Font family in use

The app uses **IBM Plex Sans Arabic** (`IBM_Plex_Sans_Arabic`) registered as a Flutter font in `pubspec.yaml`:

```
assets/fonts/IBM_Plex_Sans_Arabic/IBMPlexSansArabic-Regular.ttf  (weight 400)
assets/fonts/IBM_Plex_Sans_Arabic/IBMPlexSansArabic-Medium.ttf   (weight 600)
assets/fonts/IBM_Plex_Sans_Arabic/IBMPlexSansArabic-Bold.ttf     (weight 700)
```

This same font is registered with the PDF annotations package so Arabic text can be written on PDFs.

---

## 3. Architecture Overview

```
lib/feature/pdf/
├── data/
│   ├── data_sources/           # Remote/local PDF data sources
│   └── enums/
├── pdf_service/
│   └── pdf_manger_service_new.dart   # Download + local cache logic
└── ui/
    ├── logic/
    │   ├── annotation_cubit/
    │   │   ├── pdf_annotation_cubit.dart   # BLoC cubit: loading / error / success
    │   │   └── pdf_annotation_state.dart
    │   ├── cubit/
    │   └── riverpod/
    │       └── download_loading_provider.dart
    ├── screens/
    │   ├── pdf_screen.dart
    │   └── test_pdf_new_package_screen.dart  ← MAIN SCREEN (start here)
    └── widgets/
        ├── pdf_annotation_toolbar.dart       ← Floating toolbar widget
        ├── pdf_annotation_viewer_content.dart ← PdfAnnotationsView wrapper
        ├── download_progress_widget.dart
        ├── enter_page_number_dialog.dart
        └── saving_progress_dialog.dart
```

**Data flow**:
```
Screen (TestPdfNewPackageScreen)
  └── BlocProvider<PdfAnnotationCubit>
        └── PdfAnnotationCubit.loadBookPdf()
              └── PdfManagerServiceNew.downloadPdf()  (downloads to local file)
                    └── emits PdfAnnotationState.success(pdfPath)
                          └── PdfAnnotationViewerContent(pdfPath)
                                ├── PdfAnnotationsView           (renders PDF)
                                └── PdfAnnotationToolbar         (floating toolbar)
```

---

## 4. Public API Reference

### 4.1 `PdfAnnotationsViewController`

Create one instance per screen. Do **not** share across screens.

```dart
final controller = PdfAnnotationsViewController();
```

#### Methods

| Method | Signature | Description |
|---|---|---|
| `setEditMode` | `void setEditMode(EditMode mode)` | Switch between pan / draw / text / erase |
| `setLineMode` | `void setLineMode(LineMode mode)` | Switch between pen and highlighter (only relevant in `draw` mode) |
| `setAnnotationColour` | `void setAnnotationColour(Color color)` | Change annotation color |
| `setFontFamily` | `void setFontFamily(String family)` | Set text annotation font family |
| `setFontSize` | `void setFontSize(double size)` | Set text annotation font size |
| `registerFonts` | `Future<void> registerFonts(List<PdfFont> fonts)` | Register custom TTF fonts for PDF text embedding |
| `undo` | `Future<void> undo()` | Undo last annotation action |
| `redo` | `Future<void> redo()` | Redo last undone action |
| `saveAnnotations` | `Future<bool> saveAnnotations()` | Bake annotations into a new PDF file; returns success flag |
| `getPageCount` | `Future<int?> getPageCount()` | Returns total page count |
| `getCurrentPage` | `Future<int?> getCurrentPage()` | Returns current page index (0-based) |
| `setPage` | `Future<void> setPage(int pageIndex)` | Jump to a specific page (0-based) |

#### Callbacks

```dart
controller.onUndoAvailabilityChanged = (bool isAvailable) { ... };
controller.onRedoAvailabilityChanged = (bool isAvailable) { ... };
```

> **Important**: Set callbacks BEFORE the `PdfAnnotationsView` is built (e.g. in `initState` or `didUpdateWidget`). Re-setting them after an orientation change or PDF path change is necessary because the underlying native view may recreate itself.

### 4.2 `PdfAnnotationsView` widget

```dart
PdfAnnotationsView(
  key: ValueKey('$pdfPath-$orientation'),  // force rebuild on change
  pdfPath: '/local/path/to/file.pdf',      // REQUIRED: local file path
  startPage: 0,                            // initial page (0-based)
  pdfZoom: 0.5,                            // initial zoom level
  initialOffset: Offset.zero,             // initial scroll position
  initialAnnotationColour: Colors.blue,   // initial annotation color
  initialFontSize: 18.0,                  // initial text font size
  initialFontFamily: 'IBM_Plex_Sans_Arabic',
  pdfAnnotationsViewController: controller,
  onPageChanged: (int pageIndex) { ... },  // called on page scroll
  onError: (dynamic error) { ... },
)
```

> **Key rule**: `pdfPath` must be a **local file path** (e.g. from `path_provider`). You cannot pass a URL directly. Download the PDF first, save it locally, then pass the path.

> **Key rule**: Use `ValueKey('$pdfPath-$orientation')` so Flutter rebuilds the native view when the orientation changes. Failing to do this causes the PDF to become stale after rotation.

### 4.3 `EditMode` enum

```dart
enum EditMode { pan, draw, text, erase }
```

| Value | Behavior |
|---|---|
| `pan` | Normal scroll & zoom — no drawing |
| `draw` | Freehand drawing; controlled by `LineMode` |
| `text` | Tap to place text annotation; drag to move |
| `erase` | Erase previously drawn annotations |

### 4.4 `LineMode` enum

```dart
enum LineMode { pen, highlighter }
```

| Value | Behavior |
|---|---|
| `pen` | Thin opaque line (standard pen) |
| `highlighter` | Semi-transparent wide stroke (like a highlighter marker) |

### 4.5 `PdfFont` data class

```dart
PdfFont(
  family: 'IBM_Plex_Sans_Arabic',
  fileName: '../assets/fonts/IBM_Plex_Sans_Arabic/IBMPlexSansArabic-Regular.ttf',
)
```

> The `fileName` path is **relative to the package's native layer**, not relative to your Dart code. The path format `'../assets/fonts/...'` navigates up from the package's folder into your app's assets. Test on both Android and iOS.

### 4.6 Intercepting native `addAnnotations` channel

By default, saving annotations bakes them into the PDF on the native side, which can be very slow for large PDFs. The project intercepts this to make it a no-op:

```dart
// In initState:
ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
  'dev.flutter.pigeon.pdf_annotations.PdfAnnotationsApi.addAnnotations',
  (message) async {
    return const StandardMessageCodec().encodeMessage([true]);
  },
);
```

This causes `saveAnnotations()` to always return `true` instantly (in-memory only). Remove this if you need actual PDF saving to disk.

---

## 5. File Structure

When implementing, create/modify these files:

```
lib/feature/pdf/
├── ui/
│   ├── logic/
│   │   └── annotation_cubit/
│   │       ├── pdf_annotation_cubit.dart
│   │       └── pdf_annotation_state.dart
│   ├── screens/
│   │   └── test_pdf_new_package_screen.dart
│   └── widgets/
│       ├── pdf_annotation_viewer_content.dart
│       ├── pdf_annotation_toolbar.dart
│       ├── download_progress_widget.dart
│       └── enter_page_number_dialog.dart
└── pdf_service/
    └── pdf_manger_service_new.dart
```

---

## 6. Complete Working Example — Minimal Single-File

Use this as a **quick start** or to verify the package works in isolation.
It uses a public PDF URL and downloads it to the device's temp directory.

```dart
// minimal_pdf_viewer.dart
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_annotations/pdf_annotations.dart';

// Public PDF used for demo:
// https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf

class MinimalPdfAnnotationViewer extends StatefulWidget {
  const MinimalPdfAnnotationViewer({super.key});

  @override
  State<MinimalPdfAnnotationViewer> createState() =>
      _MinimalPdfAnnotationViewerState();
}

class _MinimalPdfAnnotationViewerState
    extends State<MinimalPdfAnnotationViewer> {
  // ── Package controller ────────────────────────────────────────────────────
  final PdfAnnotationsViewController _controller =
      PdfAnnotationsViewController();

  // ── UI state ──────────────────────────────────────────────────────────────
  EditMode _editMode = EditMode.pan;
  LineMode _lineMode = LineMode.pen;
  Color _color = Colors.blue;
  double _fontSize = 18.0;
  bool _canUndo = false;
  bool _canRedo = false;

  // ── Loading state ─────────────────────────────────────────────────────────
  String? _localPdfPath;
  double _downloadProgress = 0;
  String? _errorMessage;

  static const String _pdfUrl =
      'https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf';

  @override
  void initState() {
    super.initState();
    _setupControllerListeners();
    _downloadPdf();
  }

  void _setupControllerListeners() {
    _controller.onUndoAvailabilityChanged = (v) =>
        mounted ? setState(() => _canUndo = v) : null;
    _controller.onRedoAvailabilityChanged = (v) =>
        mounted ? setState(() => _canRedo = v) : null;
  }

  Future<void> _downloadPdf() async {
    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/sample_pdf.pdf';

      if (File(filePath).existsSync()) {
        setState(() => _localPdfPath = filePath);
        return;
      }

      await Dio().download(
        _pdfUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() => _downloadProgress = received / total);
          }
        },
      );

      setState(() => _localPdfPath = filePath);
    } catch (e) {
      setState(() => _errorMessage = 'Download failed: $e');
    }
  }

  void _setTool(EditMode mode, [LineMode? lineMode]) {
    setState(() {
      _editMode = mode;
      if (lineMode != null) _lineMode = lineMode;
    });
    _controller.setEditMode(mode);
    if (lineMode != null) _controller.setLineMode(lineMode);
    if (mode == EditMode.draw || mode == EditMode.text) {
      _controller.setAnnotationColour(_color);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDF Annotation Demo')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) {
      return Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)));
    }
    if (_localPdfPath == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Downloading… ${(_downloadProgress * 100).toStringAsFixed(0)}%'),
            const SizedBox(height: 8),
            SizedBox(width: 240, child: LinearProgressIndicator(value: _downloadProgress)),
          ],
        ),
      );
    }

    return Stack(
      children: [
        // PDF Viewer
        PdfAnnotationsView(
          key: ValueKey(_localPdfPath),
          pdfPath: _localPdfPath!,
          startPage: 0,
          pdfZoom: 0.5,
          initialOffset: Offset.zero,
          initialAnnotationColour: _color,
          initialFontSize: _fontSize,
          initialFontFamily: '',
          pdfAnnotationsViewController: _controller,
          onPageChanged: (page) => debugPrint('Page: $page'),
          onError: (err) => debugPrint('Error: $err'),
        ),

        // Floating Toolbar
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: _buildToolbar(),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white.withOpacity(0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _toolBtn(Icons.pan_tool_alt_rounded, 'Pan',
                  _editMode == EditMode.pan, Colors.amber, () => _setTool(EditMode.pan)),
              _toolBtn(Icons.edit_rounded, 'Pen',
                  _editMode == EditMode.draw && _lineMode == LineMode.pen, Colors.blue,
                  () => _setTool(EditMode.draw, LineMode.pen)),
              _toolBtn(Icons.brush_rounded, 'Highlight',
                  _editMode == EditMode.draw && _lineMode == LineMode.highlighter, Colors.cyan,
                  () => _setTool(EditMode.draw, LineMode.highlighter)),
              _toolBtn(Icons.text_fields_rounded, 'Text',
                  _editMode == EditMode.text, Colors.purple, () => _setTool(EditMode.text)),
              _toolBtn(Icons.cleaning_services_rounded, 'Erase',
                  _editMode == EditMode.erase, Colors.orange, () => _setTool(EditMode.erase)),
              const VerticalDivider(width: 16, thickness: 1),
              IconButton(
                icon: const Icon(Icons.undo_rounded),
                color: _canUndo ? Colors.black87 : Colors.grey[300],
                onPressed: _canUndo ? () => _controller.undo() : null,
              ),
              IconButton(
                icon: const Icon(Icons.redo_rounded),
                color: _canRedo ? Colors.black87 : Colors.grey[300],
                onPressed: _canRedo ? () => _controller.redo() : null,
              ),
              if (_editMode == EditMode.draw || _editMode == EditMode.text) ...[
                const VerticalDivider(width: 16, thickness: 1),
                for (final c in [Colors.red, Colors.blue, Colors.green, Colors.yellow[700]!, Colors.black])
                  _colorDot(c),
              ],
              if (_editMode == EditMode.text) ...[
                const SizedBox(width: 8),
                const Icon(Icons.text_fields, size: 16),
                SizedBox(
                  width: 100,
                  child: Slider(
                    min: 10, max: 40, value: _fontSize,
                    onChanged: (v) {
                      setState(() => _fontSize = v);
                      _controller.setFontSize(v);
                    },
                  ),
                ),
                Text('${_fontSize.toInt()}', style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolBtn(IconData icon, String label, bool isSelected,
      Color activeColor, VoidCallback onTap) {
    return Tooltip(
      message: label,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? activeColor.withOpacity(0.4) : Colors.transparent),
        ),
        child: IconButton(
          icon: Icon(icon, size: 22),
          color: isSelected ? activeColor : Colors.grey[700],
          onPressed: onTap,
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(),
        ),
      ),
    );
  }

  Widget _colorDot(Color color) {
    final isSelected = _color == color;
    return GestureDetector(
      onTap: () {
        setState(() => _color = color);
        _controller.setAnnotationColour(color);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: isSelected ? 24 : 18,
        height: isSelected ? 24 : 18,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: isSelected ? Colors.white : Colors.transparent, width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(isSelected ? 0.3 : 0.1), blurRadius: isSelected ? 6 : 2)],
        ),
      ),
    );
  }
}
```

**How to use**:

```dart
// In main.dart:
MaterialApp(
  home: const MinimalPdfAnnotationViewer(),
)
```

---

## 7. Full Production Example — All Project Files

### 7.1 State (`pdf_annotation_state.dart`)

```dart
enum PdfAnnotationStatus { initial, loading, success, failure }

class PdfAnnotationState {
  final PdfAnnotationStatus status;
  final String? pdfPath;
  final double downloadProgress;
  final String? errorMessage;

  const PdfAnnotationState({
    this.status = PdfAnnotationStatus.initial,
    this.pdfPath,
    this.downloadProgress = 0.0,
    this.errorMessage,
  });

  PdfAnnotationState copyWith({
    PdfAnnotationStatus? status,
    String? pdfPath,
    double? downloadProgress,
    String? errorMessage,
  }) {
    return PdfAnnotationState(
      status: status ?? this.status,
      pdfPath: pdfPath ?? this.pdfPath,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

extension PdfAnnotationStateX on PdfAnnotationState {
  bool get isInitial => status == PdfAnnotationStatus.initial;
  bool get isLoading => status == PdfAnnotationStatus.loading;
  bool get isSuccess => status == PdfAnnotationStatus.success;
  bool get isError   => status == PdfAnnotationStatus.failure;
}
```

### 7.2 Cubit (`pdf_annotation_cubit.dart`)

```dart
import 'dart:developer';
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'pdf_annotation_state.dart';

class PdfAnnotationCubit extends Cubit<PdfAnnotationState> {
  final PdfManagerServiceNew _service;
  CancelToken? _cancelToken;

  PdfAnnotationCubit(this._service) : super(const PdfAnnotationState());

  Future<void> loadBookPdf({required BookModel book}) async {
    emit(state.copyWith(status: PdfAnnotationStatus.loading, downloadProgress: 0.0));

    final pdfUrl = book.pdfFile;
    if (pdfUrl == null || pdfUrl.isEmpty) {
      emit(state.copyWith(status: PdfAnnotationStatus.failure, errorMessage: 'Invalid PDF URL'));
      return;
    }

    try {
      _cancelToken = CancelToken();
      final path = await _service.downloadPdf(
        pdfUrl: pdfUrl,
        bookToken: book.bookToken ?? '',
        bookId: book.id ?? 0,
        cancelToken: _cancelToken,
        onProgress: (p) => emit(state.copyWith(downloadProgress: p)),
      );
      emit(state.copyWith(status: PdfAnnotationStatus.success, pdfPath: path));
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) return;
      log('loadBookPdf error: $e');
      emit(state.copyWith(status: PdfAnnotationStatus.failure, errorMessage: 'Error: $e'));
    }
  }

  void cancelDownload() => _cancelToken?.cancel();

  Future<void> clearAndReloadPdf({required BookModel book}) async {
    _cancelToken?.cancel();
    emit(state.copyWith(status: PdfAnnotationStatus.loading, downloadProgress: 0.0, pdfPath: null));
    await _service.clearPdfAndAnnotations(bookToken: book.bookToken ?? '', bookId: book.id ?? 0);
    await loadBookPdf(book: book);
  }

  @override
  Future<void> close() {
    _cancelToken?.cancel();
    return super.close();
  }
}
```

### 7.3 PdfAnnotationViewerContent widget

```dart
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:pdf_annotations/pdf_annotations.dart';
import 'pdf_annotation_toolbar.dart';

class PdfAnnotationViewerContent extends StatefulWidget {
  final String pdfPath;
  final Orientation orientation;
  final PdfAnnotationsViewController annotationsController;
  final bool showToolbar;
  final ValueChanged<int>? onPageChanged;
  final bool isCurrentPageSaved;
  final int savedPagesCount;
  final VoidCallback? onToggleBookmark;
  final VoidCallback? onShowSavedPages;

  const PdfAnnotationViewerContent({
    super.key,
    required this.pdfPath,
    required this.orientation,
    required this.annotationsController,
    this.showToolbar = true,
    this.onPageChanged,
    this.isCurrentPageSaved = false,
    this.savedPagesCount = 0,
    this.onToggleBookmark,
    this.onShowSavedPages,
  });

  @override
  State<PdfAnnotationViewerContent> createState() =>
      _PdfAnnotationViewerContentState();
}

class _PdfAnnotationViewerContentState extends State<PdfAnnotationViewerContent> {
  EditMode _editMode = EditMode.pan;
  LineMode _lineMode = LineMode.pen;
  Color _selectedColor = Colors.blue;
  double _fontSize = 18.0;
  final String _fontFamily = 'IBM_Plex_Sans_Arabic';
  bool _canUndo = false;
  bool _canRedo = false;
  bool _fontsRegistered = false;

  @override
  void initState() {
    super.initState();
    _setupControllerListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFontsRegistered());
  }

  @override
  void didUpdateWidget(covariant PdfAnnotationViewerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showToolbar != widget.showToolbar && !widget.showToolbar) {
      _setTool(EditMode.pan);
    }
    if (oldWidget.orientation != widget.orientation || oldWidget.pdfPath != widget.pdfPath) {
      _fontsRegistered = false;
      _setupControllerListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFontsRegistered());
    }
  }

  void _setupControllerListeners() {
    widget.annotationsController.onUndoAvailabilityChanged = (v) {
      if (mounted) {
        setState(() => _canUndo = v);
        _triggerAutoSave();
      }
    };
    widget.annotationsController.onRedoAvailabilityChanged = (v) {
      if (mounted) {
        setState(() => _canRedo = v);
        _triggerAutoSave();
      }
    };
  }

  void _triggerAutoSave() {
    widget.annotationsController.saveAnnotations().catchError((e) {
      log('Auto-save error: $e');
      return false;
    });
  }

  Future<void> _ensureFontsRegistered() async {
    if (_fontsRegistered) return;
    try {
      await widget.annotationsController.registerFonts([
        PdfFont(
          family: 'IBM_Plex_Sans_Arabic',
          fileName: '../assets/fonts/IBM_Plex_Sans_Arabic/IBMPlexSansArabic-Regular.ttf',
        ),
      ]);
      _fontsRegistered = true;
    } catch (e) {
      log('Font registration error: $e');
    }
  }

  void _setTool(EditMode mode, [LineMode? lineMode]) {
    setState(() {
      _editMode = mode;
      if (lineMode != null) _lineMode = lineMode;
    });
    widget.annotationsController.setEditMode(mode);
    if (lineMode != null) widget.annotationsController.setLineMode(lineMode);
    if (mode == EditMode.draw) {
      widget.annotationsController.setAnnotationColour(_selectedColor);
    } else if (mode == EditMode.text) {
      widget.annotationsController.setFontFamily(_fontFamily);
      widget.annotationsController.setFontSize(_fontSize);
      widget.annotationsController.setAnnotationColour(_selectedColor);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: PdfAnnotationsView(
            // ValueKey forces native rebuild on orientation or path changes
            key: ValueKey('${widget.pdfPath}-${widget.orientation}'),
            pdfPath: widget.pdfPath,
            startPage: 0,
            pdfZoom: 0.5,
            initialOffset: Offset.zero,
            initialAnnotationColour: _selectedColor,
            initialFontSize: _fontSize,
            initialFontFamily: _fontFamily,
            pdfAnnotationsViewController: widget.annotationsController,
            onPageChanged: widget.onPageChanged,
            onError: (error) => log('PdfAnnotationsView error: $error'),
          ),
        ),
        if (widget.showToolbar)
          Positioned(
            top: 10, left: 16, right: 16,
            child: PdfAnnotationToolbar(
              editMode: _editMode,
              lineMode: _lineMode,
              selectedColor: _selectedColor,
              fontSize: _fontSize,
              canUndo: _canUndo,
              canRedo: _canRedo,
              onToolSelected: _setTool,
              onColorSelected: (color) {
                setState(() => _selectedColor = color);
                widget.annotationsController.setAnnotationColour(color);
              },
              onFontSizeChanged: (val) {
                setState(() => _fontSize = val);
                widget.annotationsController.setFontSize(val);
              },
              onUndo: () => widget.annotationsController.undo(),
              onRedo: () => widget.annotationsController.redo(),
              isCurrentPageSaved: widget.isCurrentPageSaved,
              savedPagesCount: widget.savedPagesCount,
              onToggleBookmark: widget.onToggleBookmark,
              onShowSavedPages: widget.onShowSavedPages,
            ),
          ),
      ],
    );
  }
}
```

### 7.4 PdfAnnotationToolbar widget

```dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf_annotations/pdf_annotations.dart';

class PdfAnnotationToolbar extends StatelessWidget {
  final EditMode editMode;
  final LineMode lineMode;
  final Color selectedColor;
  final double fontSize;
  final bool canUndo;
  final bool canRedo;
  final Function(EditMode, [LineMode?]) onToolSelected;
  final ValueChanged<Color> onColorSelected;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final bool isCurrentPageSaved;
  final int savedPagesCount;
  final VoidCallback? onToggleBookmark;
  final VoidCallback? onShowSavedPages;

  const PdfAnnotationToolbar({
    super.key,
    required this.editMode,
    required this.lineMode,
    required this.selectedColor,
    required this.fontSize,
    required this.canUndo,
    required this.canRedo,
    required this.onToolSelected,
    required this.onColorSelected,
    required this.onFontSizeChanged,
    required this.onUndo,
    required this.onRedo,
    this.isCurrentPageSaved = false,
    this.savedPagesCount = 0,
    this.onToggleBookmark,
    this.onShowSavedPages,
  });

  Widget _toolBtn({required IconData icon, required String label,
      required bool isSelected, required VoidCallback onTap, Color? activeColor}) {
    final color = activeColor ?? Colors.blue;
    return Tooltip(
      message: label,
      child: AnimatedScale(
        scale: isSelected ? 1.15 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: isSelected ? color.withValues(alpha: 0.3) : Colors.transparent, width: 1.2),
          ),
          child: IconButton(
            icon: Icon(icon),
            color: isSelected ? color : Colors.grey[700],
            onPressed: () { HapticFeedback.lightImpact(); onTap(); },
            iconSize: 22,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
          ),
        ),
      ),
    );
  }

  Widget _actionBtn({required IconData icon, required String label,
      required bool isEnabled, required VoidCallback onTap, Color? color}) {
    return Tooltip(
      message: label,
      child: IconButton(
        icon: Icon(icon),
        color: color ?? (isEnabled ? Colors.grey[800] : Colors.grey[400]),
        onPressed: isEnabled ? () { HapticFeedback.selectionClick(); onTap(); } : null,
        iconSize: 22, padding: const EdgeInsets.all(8), constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _divider() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
    child: Container(width: 1, height: 24, color: Colors.grey.withValues(alpha: 0.3)),
  );

  Widget _colorDot(Color color) {
    final isSelected = selectedColor == color;
    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); onColorSelected(color); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: isSelected ? 24 : 18,
        height: isSelected ? 24 : 18,
        decoration: BoxDecoration(
          color: color, shape: BoxShape.circle,
          border: Border.all(color: isSelected ? Colors.white : Colors.transparent, width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isSelected ? 0.3 : 0.1), blurRadius: isSelected ? 6 : 2, offset: const Offset(0, 1))],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditingActive = editMode == EditMode.draw || editMode == EditMode.text;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1.5),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 20, offset: const Offset(0, 8))],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      _toolBtn(icon: Icons.pan_tool_alt_rounded, label: 'Pan',
                          isSelected: editMode == EditMode.pan, activeColor: Colors.amber,
                          onTap: () => onToolSelected(EditMode.pan)),
                      _toolBtn(icon: Icons.edit_rounded, label: 'Pen',
                          isSelected: editMode == EditMode.draw && lineMode == LineMode.pen,
                          activeColor: Colors.blue, onTap: () => onToolSelected(EditMode.draw, LineMode.pen)),
                      _toolBtn(icon: Icons.brush_rounded, label: 'Highlighter',
                          isSelected: editMode == EditMode.draw && lineMode == LineMode.highlighter,
                          activeColor: Colors.cyan, onTap: () => onToolSelected(EditMode.draw, LineMode.highlighter)),
                      _toolBtn(icon: Icons.text_fields_rounded, label: 'Text',
                          isSelected: editMode == EditMode.text, activeColor: Colors.blue,
                          onTap: () => onToolSelected(EditMode.text)),
                      _toolBtn(icon: Icons.cleaning_services_rounded, label: 'Eraser',
                          isSelected: editMode == EditMode.erase, activeColor: Colors.orange,
                          onTap: () => onToolSelected(EditMode.erase)),
                      _divider(),
                      _actionBtn(icon: Icons.undo_rounded, label: 'Undo', isEnabled: canUndo, onTap: onUndo),
                      _actionBtn(icon: Icons.redo_rounded, label: 'Redo', isEnabled: canRedo, onTap: onRedo),
                      if (onToggleBookmark != null) ...[
                        _divider(),
                        _actionBtn(
                          icon: isCurrentPageSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                          label: isCurrentPageSaved ? 'Remove bookmark' : 'Bookmark page',
                          isEnabled: true,
                          color: isCurrentPageSaved ? Colors.amber[700] : null,
                          onTap: onToggleBookmark!,
                        ),
                      ],
                      if (onShowSavedPages != null)
                        Tooltip(
                          message: 'Bookmarked pages',
                          child: IconButton(
                            icon: Badge(isLabelVisible: savedPagesCount > 0, label: Text('$savedPagesCount'), child: const Icon(Icons.bookmarks_rounded)),
                            color: Colors.grey[800], iconSize: 22, padding: const EdgeInsets.all(8),
                            constraints: const BoxConstraints(),
                            onPressed: () { HapticFeedback.selectionClick(); onShowSavedPages!(); },
                          ),
                        ),
                      if (isEditingActive) ...[
                        _divider(),
                        _colorDot(Colors.red), _colorDot(Colors.blue), _colorDot(Colors.green),
                        _colorDot(Colors.yellow[700]!), _colorDot(Colors.black),
                      ],
                    ],
                  ),
                ),
                if (editMode == EditMode.text) ...[
                  const Divider(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.text_fields, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Slider(min: 10, max: 40, value: fontSize, onChanged: onFontSizeChanged)),
                        Text('${fontSize.toInt()}', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

### 7.5 Main Screen (`test_pdf_new_package_screen.dart`)

Key initialization pattern:

```dart
@override
void initState() {
  super.initState();

  _loadSavedPages();

  if (!widget.book.isDownloadabl) _enableScreenProtections();

  _pdfAnnotationCubit = PdfAnnotationCubit(getIt())..loadBookPdf(book: widget.book);

  // Allow landscape + portrait during reading
  Future.delayed(Duration.zero, () {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp, DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight,
    ]);
  });

  // Intercept native PDF baking — makes saveAnnotations() instant (no-op)
  ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
    'dev.flutter.pigeon.pdf_annotations.PdfAnnotationsApi.addAnnotations',
    (message) async => const StandardMessageCodec().encodeMessage([true]),
  );
}

@override
void dispose() {
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  _disableScreenProtections();
  _pdfAnnotationCubit.close();
  super.dispose();
}
```

Back-press save pattern:

```dart
PopScope(
  canPop: false,
  onPopInvokedWithResult: (didPop, result) {
    if (didPop) return;
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _annotationsController.saveAnnotations().catchError((e) {
      log('Error saving annotations: $e');
      return false;
    });
    Navigator.of(context).pop();
  },
  child: Scaffold(...),
)
```

---

## 8. Key Patterns & Gotchas

### DO

- Always use `ValueKey('$pdfPath-$orientation')` on `PdfAnnotationsView`.
- Call `_setupControllerListeners()` in both `initState` and `didUpdateWidget`.
- Call `registerFonts()` inside `WidgetsBinding.instance.addPostFrameCallback`.
- Auto-save on every undo/redo via the `onUndoAvailabilityChanged` callback.
- Call `saveAnnotations()` on back-press inside `PopScope.onPopInvokedWithResult`.

### DON'T

- Don't pass a URL to `pdfPath`. Must be a local file path.
- Don't share one `PdfAnnotationsViewController` across multiple screens.
- Don't forget to re-set controller callbacks after orientation changes.
- Don't call `registerFonts()` synchronously in `initState`.

### Performance notes

- `saveAnnotations()` with the channel interception is instant (in-memory only).
- Without interception, native PDF baking is slow for large files.
- `PdfAnnotationsView` is a native platform view — cannot be wrapped with `RepaintBoundary`.
- Use `OrientationBuilder` at the screen level and pass orientation as a prop.

---

## 9. Dependency & pubspec Setup

```yaml
dependencies:
  pdf_annotations:
    git:
      url: https://github.com/AhmadAbbas8/pdf_annotations_forked.git
      ref: d1b1f4a6ccfb7b6b478c353670144af48325458e
```

```bash
flutter pub get
```

Single import exposes everything:

```dart
import 'package:pdf_annotations/pdf_annotations.dart';
// Provides: PdfAnnotationsView, PdfAnnotationsViewController,
//           EditMode, LineMode, PdfFont
```

---

## 10. Test PDF URLs

| Description | URL |
|---|---|
| Mozilla PDF.js sample (multi-page) | `https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf` |
| W3C PDF sample (small) | `https://www.w3.org/WAI/WCAG21/Techniques/pdf/pdf-sample.pdf` |
| US Census (multi-page) | `https://www.census.gov/content/dam/Census/library/publications/2015/demo/p60-252.pdf` |

### Download snippet

```dart
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

Future<String> downloadTestPdf(String url) async {
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/test.pdf';
  if (!File(path).existsSync()) {
    await Dio().download(url, path);
  }
  return path;
}
```

---

## Summary Table

| Concept | Implementation |
|---|---|
| PDF rendering | `PdfAnnotationsView` widget |
| Control | `PdfAnnotationsViewController` |
| State management | `flutter_bloc` Cubit |
| Tools | `EditMode` + `LineMode` enums |
| Custom fonts | `PdfFont` + `registerFonts()` |
| Orientation support | `ValueKey` + `didUpdateWidget` |
| Auto-save | `onUndoAvailabilityChanged` callback |
| Back-press save | `PopScope.onPopInvokedWithResult` |
| Bookmarks | Hive cache + page index tracking |
| DRM | `screen_protector` package |
| Page navigation | `getPageCount()` + `setPage()` |

---

*Last updated: 2026-07-28 | Booklet v14.0.0 | pdf_annotations commit `d1b1f4a`*
