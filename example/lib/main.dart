import 'dart:developer';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_annotations/pdf_annotations.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PdfAnnotationsExampleApp());
}

class PdfAnnotationsExampleApp extends StatelessWidget {
  const PdfAnnotationsExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Annotations Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E88E5),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF90CAF9),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const PdfAnnotationScreen(),
    );
  }
}

class PdfAnnotationScreen extends StatefulWidget {
  const PdfAnnotationScreen({super.key});

  @override
  State<PdfAnnotationScreen> createState() => _PdfAnnotationScreenState();
}

class _PdfAnnotationScreenState extends State<PdfAnnotationScreen> {
  final PdfAnnotationsViewController _controller =
      PdfAnnotationsViewController();

  // ── Annotation State ──────────────────────────────────────────────────────
  EditMode _editMode = EditMode.pan;
  LineMode _lineMode = LineMode.pen;
  Color _selectedColor = Colors.blue;
  String _fontFamily = 'IBM_Plex_Sans_Arabic';
  double _fontSize = 18.0;
  bool _canUndo = false;
  bool _canRedo = false;
  bool _fontsRegistered = false;

  static const String _pdfUrl =
      'https://easy.easy-stream.net/pdfs/07cd0ef8-d52f-49fe-81e1-f561e3581cb2.pdf';

  // ── Page & Document State ─────────────────────────────────────────────────
  String? _localPdfPath;
  bool _isLoading = true;
  double _downloadProgress = 0.0;
  String? _errorMessage;
  int _currentPage = 0;
  int _totalPages = 1;
  int _reloadKeyCounter = 0;
  final Set<int> _bookmarkedPages = <int>{};

  @override
  void initState() {
    super.initState();
    _setupNativeChannelInterceptor();
    _setupControllerListeners();
    _initPdfFile();
  }

  /// Intercepts native PDF baking to make saveAnnotations() instant (in-memory mode)
  /// as documented in pdf_example.md.
  void _setupNativeChannelInterceptor() {
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      'dev.flutter.pigeon.pdf_annotations.PdfAnnotationsApi.addAnnotations',
      (ByteData? message) async {
        return PdfAnnotationsApi.pigeonChannelCodec.encodeMessage([true]);
      },
    );
  }

  void _setupControllerListeners() {
    _controller.onUndoAvailabilityChanged = (bool isAvailable) {
      if (mounted) {
        setState(() => _canUndo = isAvailable);
        _autoSaveAnnotations();
      }
    };

    _controller.onRedoAvailabilityChanged = (bool isAvailable) {
      if (mounted) {
        setState(() => _canRedo = isAvailable);
        _autoSaveAnnotations();
      }
    };
  }

  Future<void> _initPdfFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/sample.pdf');

      if (!await file.exists()) {
        await _downloadPdfFromUrl(_pdfUrl, file.path);
      }

      if (mounted) {
        setState(() {
          _localPdfPath = file.path;
          _isLoading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _ensureFontsRegistered();
        });
      }
    } catch (e) {
      log('Error downloading PDF file from URL: $e');
      // Asset fallback if offline
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/sample.pdf');
        final data = await rootBundle.load('assets/sample.pdf');
        final bytes = data.buffer.asUint8List();
        await file.writeAsBytes(bytes, flush: true);

        if (mounted) {
          setState(() {
            _localPdfPath = file.path;
            _isLoading = false;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _ensureFontsRegistered();
          });
        }
      } catch (fallbackErr) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Failed to load PDF: $e';
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _downloadPdfFromUrl(String url, String savePath) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode == 200) {
        final totalBytes = response.contentLength;
        int receivedBytes = 0;
        final file = File(savePath);
        final sink = file.openWrite();

        await for (final chunk in response) {
          receivedBytes += chunk.length;
          sink.add(chunk);

          if (totalBytes > 0 && mounted) {
            setState(() {
              _downloadProgress = receivedBytes / totalBytes;
            });
          }
        }

        await sink.close();
      } else {
        throw Exception('HTTP error status code ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  Future<void> _ensureFontsRegistered() async {
    if (_fontsRegistered) return;
    try {
      final pdfFonts = [
        PdfFont(
          family: 'IBM_Plex_Sans_Arabic',
          fileName: 'IBMPlexSansArabic-Regular.ttf',
        ),
        PdfFont(family: 'Work Sans', fileName: 'WorkSans-Regular.ttf'),
        PdfFont(
          family: 'Courier Prime',
          fileName: 'CourierPrime-Regular.ttf',
        ),
      ];
      await _controller.registerFonts(pdfFonts);
      _fontsRegistered = true;
    } catch (e) {
      log('Error registering fonts: $e');
    }
  }

  void _autoSaveAnnotations() {
    _controller.saveAnnotations().catchError((error) {
      log('Auto-save error: $error');
      return false;
    });
  }

  void _setTool(EditMode mode, [LineMode? lineMode]) {
    setState(() {
      _editMode = mode;
      if (lineMode != null) _lineMode = lineMode;
    });

    _controller.setEditMode(mode);
    if (lineMode != null) {
      _controller.setLineMode(lineMode);
    }

    if (mode == EditMode.draw) {
      _controller.setAnnotationColour(_selectedColor);
    } else if (mode == EditMode.text) {
      _controller.setFontFamily(_fontFamily);
      _controller.setFontSize(_fontSize);
      _controller.setAnnotationColour(_selectedColor);
    }
  }

  void _toggleBookmarkForCurrentPage() {
    setState(() {
      if (_bookmarkedPages.contains(_currentPage)) {
        _bookmarkedPages.remove(_currentPage);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed page ${_currentPage + 1} from bookmarks'),
            duration: const Duration(seconds: 1),
          ),
        );
      } else {
        _bookmarkedPages.add(_currentPage);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Bookmarked page ${_currentPage + 1}'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    });
  }

  Future<void> _clearAndReloadPdf() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange),
              SizedBox(width: 8),
              Text('Reset PDF'),
            ],
          ),
          content: const Text(
            'This will delete the local PDF file and clear all annotations & bookmarks, then re-download the fresh PDF. Proceed?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Clear & Re-download'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    setState(() {
      _isLoading = true;
      _downloadProgress = 0.0;
      _errorMessage = null;
      _localPdfPath = null;
      _currentPage = 0;
      _bookmarkedPages.clear();
      _canUndo = false;
      _canRedo = false;
    });

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final tempDir = await getTemporaryDirectory();

      for (final targetDir in [docsDir, tempDir]) {
        if (await targetDir.exists()) {
          final entities = targetDir.listSync();
          for (final entity in entities) {
            if (entity is File && entity.path.contains('sample')) {
              try {
                await entity.delete();
              } catch (e) {
                log('Error deleting file ${entity.path}: $e');
              }
            }
          }
        }
      }

      setState(() {
        _reloadKeyCounter++;
      });

      await _initPdfFile();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PDF and annotations cleared, re-downloaded successfully!'),
          ),
        );
      }
    } catch (e) {
      log('Error clearing and re-downloading PDF: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to reset PDF: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCurrentPageSaved = _bookmarkedPages.contains(_currentPage);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _controller.saveAnnotations().catchError((e) {
          log('Error saving annotations on pop: $e');
          return false;
        });
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _totalPages > 1
                ? 'PDF Annotations (${_currentPage + 1}/$_totalPages)'
                : 'PDF Annotations Example',
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Clear & Re-download PDF',
              onPressed: _isLoading ? null : () => _clearAndReloadPdf(),
            ),
            IconButton(
              icon: const Icon(Icons.format_list_numbered_rounded),
              tooltip: 'Go to Page',
              onPressed: _isLoading ? null : () => _showGoToPageDialog(),
            ),
            IconButton(
              icon: Badge(
                isLabelVisible: _bookmarkedPages.isNotEmpty,
                label: Text('${_bookmarkedPages.length}'),
                child: const Icon(Icons.bookmarks_rounded),
              ),
              tooltip: 'Bookmarked Pages',
              onPressed: _isLoading ? null : () => _showBookmarkedPagesDialog(),
            ),
            IconButton(
              icon: const Icon(Icons.save_rounded),
              tooltip: 'Save Annotations',
              onPressed: _isLoading
                  ? null
                  : () async {
                      final success = await _controller.saveAnnotations();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              success
                                  ? 'Annotations saved successfully!'
                                  : 'Failed to save annotations.',
                            ),
                          ),
                        );
                      }
                    },
            ),
          ],
        ),
        body: _buildBody(isCurrentPageSaved),
      ),
    );
  }

  Widget _buildBody(bool isCurrentPageSaved) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _downloadProgress > 0
                  ? 'Downloading PDF... ${(_downloadProgress * 100).toStringAsFixed(0)}%'
                  : 'Loading PDF...',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            if (_downloadProgress > 0) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 220,
                child: LinearProgressIndicator(value: _downloadProgress),
              ),
            ],
          ],
        ),
      );
    }

    if (_errorMessage != null || _localPdfPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text(
                _errorMessage ?? 'PDF file path is invalid.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _errorMessage = null;
                  });
                  _initPdfFile();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return OrientationBuilder(
      builder: (context, orientation) {
        return Stack(
          children: [
            // Core PDF Annotation View
            Positioned.fill(
              child: PdfAnnotationsView(
                key: ValueKey('$_localPdfPath-${orientation.name}-$_reloadKeyCounter'),
                pdfPath: _localPdfPath!,
                startPage: 0,
                pdfZoom: 0.5,
                initialOffset: Offset.zero,
                initialAnnotationColour: _selectedColor,
                initialFontSize: _fontSize,
                initialFontFamily: _fontFamily,
                pdfAnnotationsViewController: _controller,
                onPageChanged: (pageIndex) async {
                  final total = await _controller.getPageCount() ?? 1;
                  if (mounted) {
                    setState(() {
                      _currentPage = pageIndex;
                      _totalPages = total;
                    });
                  }
                },
                onError: (error) => log('PdfAnnotationsView error: $error'),
              ),
            ),

            // Floating Frosted Glass Toolbar
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: PdfAnnotationToolbar(
                editMode: _editMode,
                lineMode: _lineMode,
                selectedColor: _selectedColor,
                fontFamily: _fontFamily,
                fontSize: _fontSize,
                canUndo: _canUndo,
                canRedo: _canRedo,
                isCurrentPageSaved: isCurrentPageSaved,
                savedPagesCount: _bookmarkedPages.length,
                onToolSelected: _setTool,
                onColorSelected: (color) {
                  setState(() => _selectedColor = color);
                  _controller.setAnnotationColour(color);
                },
                onFontFamilyChanged: (family) {
                  setState(() => _fontFamily = family);
                  _controller.setFontFamily(family);
                },
                onFontSizeChanged: (size) {
                  setState(() => _fontSize = size);
                  _controller.setFontSize(size);
                },
                onUndo: () => _controller.undo(),
                onRedo: () => _controller.redo(),
                onToggleBookmark: _toggleBookmarkForCurrentPage,
                onShowSavedPages: _showBookmarkedPagesDialog,
              ),
            ),
          ],
        );
      },
    );
  }

  void _showGoToPageDialog() async {
    final total = await _controller.getPageCount() ?? _totalPages;
    if (!mounted) return;

    final textController = TextEditingController(text: '${_currentPage + 1}');

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Go to Page'),
          content: TextField(
            controller: textController,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Enter page number (1 - $total)',
              labelText: 'Page (1 - $total)',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final pageNum = int.tryParse(textController.text.trim());
                if (pageNum != null && pageNum >= 1 && pageNum <= total) {
                  final targetIndex = pageNum - 1;
                  Navigator.pop(dialogContext);
                  await _controller.setPage(targetIndex);
                  if (mounted) {
                    setState(() {
                      _currentPage = targetIndex;
                    });
                  }
                }
              },
              child: const Text('Go'),
            ),
          ],
        );
      },
    );
  }

  void _showBookmarkedPagesDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final sortedBookmarks = _bookmarkedPages.toList()..sort();
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.bookmarks_rounded, color: Colors.amber),
              const SizedBox(width: 8),
              Text('Bookmarked Pages (${sortedBookmarks.length})'),
            ],
          ),
          content: sortedBookmarks.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    'No pages bookmarked yet.\nTap the bookmark icon in the toolbar to save pages.',
                    textAlign: TextAlign.center,
                  ),
                )
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: sortedBookmarks.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final pageIndex = sortedBookmarks[index];
                      final pageNum = pageIndex + 1;
                      final isCurrent = pageIndex == _currentPage;

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isCurrent
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Text('$pageNum'),
                        ),
                        title: Text('Page $pageNum'),
                        subtitle: isCurrent
                            ? const Text(
                                'Current page',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              )
                            : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: () {
                            setState(() {
                              _bookmarkedPages.remove(pageIndex);
                            });
                            Navigator.pop(dialogContext);
                            _showBookmarkedPagesDialog();
                          },
                        ),
                        onTap: () async {
                          Navigator.pop(dialogContext);
                          await _controller.setPage(pageIndex);
                          if (mounted) {
                            setState(() {
                              _currentPage = pageIndex;
                            });
                          }
                        },
                      );
                    },
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

/// Floating Frosted Glass Toolbar for PDF Annotations
class PdfAnnotationToolbar extends StatelessWidget {
  final EditMode editMode;
  final LineMode lineMode;
  final Color selectedColor;
  final String fontFamily;
  final double fontSize;
  final bool canUndo;
  final bool canRedo;
  final bool isCurrentPageSaved;
  final int savedPagesCount;

  final Function(EditMode, [LineMode?]) onToolSelected;
  final ValueChanged<Color> onColorSelected;
  final ValueChanged<String> onFontFamilyChanged;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onToggleBookmark;
  final VoidCallback onShowSavedPages;

  const PdfAnnotationToolbar({
    super.key,
    required this.editMode,
    required this.lineMode,
    required this.selectedColor,
    required this.fontFamily,
    required this.fontSize,
    required this.canUndo,
    required this.canRedo,
    required this.isCurrentPageSaved,
    required this.savedPagesCount,
    required this.onToolSelected,
    required this.onColorSelected,
    required this.onFontFamilyChanged,
    required this.onFontSizeChanged,
    required this.onUndo,
    required this.onRedo,
    required this.onToggleBookmark,
    required this.onShowSavedPages,
  });

  Widget _toolBtn({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    Color? activeColor,
  }) {
    final color = activeColor ?? Colors.blue;
    return Tooltip(
      message: label,
      child: AnimatedScale(
        scale: isSelected ? 1.15 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          decoration: BoxDecoration(
            color: isSelected
                ? color.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected
                  ? color.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: IconButton(
            icon: Icon(icon),
            color: isSelected ? color : Colors.grey[700],
            onPressed: () {
              HapticFeedback.lightImpact();
              onTap();
            },
            iconSize: 22,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
          ),
        ),
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required bool isEnabled,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Tooltip(
      message: label,
      child: IconButton(
        icon: Icon(icon),
        color: color ?? (isEnabled ? Colors.grey[800] : Colors.grey[400]),
        onPressed: isEnabled
            ? () {
                HapticFeedback.selectionClick();
                onTap();
              }
            : null,
        iconSize: 22,
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Container(
          width: 1,
          height: 24,
          color: Colors.grey.withValues(alpha: 0.3),
        ),
      );

  Widget _colorDot(Color color) {
    final isSelected = selectedColor == color;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onColorSelected(color);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: isSelected ? 24 : 18,
        height: isSelected ? 24 : 18,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.transparent,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isSelected ? 0.3 : 0.1),
              blurRadius: isSelected ? 6 : 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditingActive =
        editMode == EditMode.draw || editMode == EditMode.text;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.4),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
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
                      _toolBtn(
                        icon: Icons.pan_tool_alt_rounded,
                        label: 'Pan (Navigate)',
                        isSelected: editMode == EditMode.pan,
                        activeColor: Colors.amber[800],
                        onTap: () => onToolSelected(EditMode.pan),
                      ),
                      _toolBtn(
                        icon: Icons.edit_rounded,
                        label: 'Pen',
                        isSelected: editMode == EditMode.draw &&
                            lineMode == LineMode.pen,
                        activeColor: Colors.blue[700],
                        onTap: () => onToolSelected(EditMode.draw, LineMode.pen),
                      ),
                      _toolBtn(
                        icon: Icons.brush_rounded,
                        label: 'Highlighter',
                        isSelected: editMode == EditMode.draw &&
                            lineMode == LineMode.highlighter,
                        activeColor: Colors.cyan[700],
                        onTap: () =>
                            onToolSelected(EditMode.draw, LineMode.highlighter),
                      ),
                      _toolBtn(
                        icon: Icons.text_fields_rounded,
                        label: 'Text',
                        isSelected: editMode == EditMode.text,
                        activeColor: Colors.purple[700],
                        onTap: () => onToolSelected(EditMode.text),
                      ),
                      _toolBtn(
                        icon: Icons.cleaning_services_rounded,
                        label: 'Eraser',
                        isSelected: editMode == EditMode.erase,
                        activeColor: Colors.orange[800],
                        onTap: () => onToolSelected(EditMode.erase),
                      ),
                      _divider(),
                      _actionBtn(
                        icon: Icons.undo_rounded,
                        label: 'Undo',
                        isEnabled: canUndo,
                        onTap: onUndo,
                      ),
                      _actionBtn(
                        icon: Icons.redo_rounded,
                        label: 'Redo',
                        isEnabled: canRedo,
                        onTap: onRedo,
                      ),
                      _divider(),
                      _actionBtn(
                        icon: isCurrentPageSaved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        label: isCurrentPageSaved
                            ? 'Remove bookmark'
                            : 'Bookmark page',
                        isEnabled: true,
                        color: isCurrentPageSaved ? Colors.amber[800] : null,
                        onTap: onToggleBookmark,
                      ),
                      _actionBtn(
                        icon: Icons.bookmarks_rounded,
                        label: 'Bookmarked pages ($savedPagesCount)',
                        isEnabled: true,
                        color: savedPagesCount > 0 ? Colors.amber[800] : null,
                        onTap: onShowSavedPages,
                      ),
                      if (isEditingActive) ...[
                        _divider(),
                        _colorDot(Colors.red),
                        _colorDot(Colors.blue),
                        _colorDot(Colors.green),
                        _colorDot(Colors.yellow[700]!),
                        _colorDot(Colors.black),
                      ],
                    ],
                  ),
                ),
                if (editMode == EditMode.text) ...[
                  const Divider(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.font_download_rounded, size: 18),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: fontFamily,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(
                              value: 'IBM_Plex_Sans_Arabic',
                              child: Text('IBM Plex Sans Arabic', style: TextStyle(fontSize: 13)),
                            ),
                            DropdownMenuItem(
                              value: 'Work Sans',
                              child: Text('Work Sans', style: TextStyle(fontSize: 13)),
                            ),
                            DropdownMenuItem(
                              value: 'Courier Prime',
                              child: Text('Courier Prime', style: TextStyle(fontSize: 13)),
                            ),
                          ],
                          onChanged: (val) {
                            if (val != null) onFontFamilyChanged(val);
                          },
                        ),
                        const SizedBox(width: 16),
                        const Icon(Icons.text_fields_rounded, size: 18),
                        Expanded(
                          child: Slider(
                            min: 10,
                            max: 40,
                            divisions: 30,
                            value: fontSize,
                            onChanged: onFontSizeChanged,
                          ),
                        ),
                        Text(
                          '${fontSize.toInt()}pt',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
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
