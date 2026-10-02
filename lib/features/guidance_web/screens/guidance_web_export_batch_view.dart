import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/local_batch.dart';
import '../export/guidance_web_export_service.dart';
import '../services/guidance_web_analytics_service.dart';
import '../services/guidance_web_results_service.dart';

/// What the person chose in the export confirmation popup.
enum ExportChoice { exportNow, viewOutput }

/// The popup's answer: the button pressed and the "Include Certificates?"
/// switch as it was left.
class ExportDecision {
  const ExportDecision(this.choice, this.includeCertificates);
  final ExportChoice choice;
  final bool includeCertificates;
}

/// Brand cyan used for the "Include Certificates?" control (same as the
/// Category D colour on the certificates).
const Color _certificatesCyan = Color(0xFF00B0F0);

/// "Include Certificates?" label + switch, shared by the popup and the
/// checklist header.
class IncludeCertificatesSwitch extends StatelessWidget {
  const IncludeCertificatesSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Include Certificates?',
          style: AppTextStyles.body(
            size: 13,
            weight: FontWeight.w800,
            color: _certificatesCyan,
          ).copyWith(fontStyle: FontStyle.italic),
        ),
        const SizedBox(width: 8),
        Switch(
          key: const Key('includeCertificatesSwitch'),
          value: value,
          onChanged: onChanged,
          activeThumbColor: Colors.white,
          activeTrackColor: _certificatesCyan,
        ),
      ],
    );
  }
}

/// The "Export?" safety popup: says what will be exported and offers
/// `view output` first, so nobody exports blind. Null when cancelled.
Future<ExportDecision?> showExportConfirmDialog(
  BuildContext context, {
  required String summary,
  bool includeCertificates = true,
}) {
  var certificates = includeCertificates;
  return showDialog<ExportDecision>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        key: const Key('exportConfirmDialog'),
        title: Row(
          children: [
            const Expanded(child: Text('Export?')),
            IncludeCertificatesSwitch(
              value: certificates,
              onChanged: (v) => setDialogState(() => certificates = v),
            ),
          ],
        ),
        content: Text(
          '$summary\n\nYou can view the output first to check what it will '
          'look like.',
        ),
        actions: [
          TextButton(
            key: const Key('exportConfirmCancel'),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            key: const Key('exportConfirmViewOutput'),
            onPressed: () => Navigator.pop(
              ctx,
              ExportDecision(ExportChoice.viewOutput, certificates),
            ),
            child: const Text('View output'),
          ),
          FilledButton(
            key: const Key('exportConfirmExport'),
            onPressed: () => Navigator.pop(
              ctx,
              ExportDecision(ExportChoice.exportNow, certificates),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primaryGreen,
            ),
            child: const Text('Export'),
          ),
        ],
      ),
    ),
  );
}

/// Export → view: one batch's export checklist.
///
/// The batch summary row and every scan row has a checkbox (checked =
/// included in the export, unchecked = left out). `view output` previews what the
/// checked items will look like printed; `export` will produce the PDF from
/// the same selection. A row's own `view` previews just that one item.
///
/// READ-ONLY, like the rest of the web console: scans are read from Supabase
/// into this widget's state only.
class GuidanceWebExportBatchView extends StatefulWidget {
  const GuidanceWebExportBatchView({
    super.key,
    required this.batch,
    required this.onBack,
    GuidanceWebResultsService? service,
    GuidanceWebAnalyticsService? analyticsService,
    GuidanceWebExportService? exportService,
    this.startInPreview = false,
    this.initialIncludeCertificates = true,
  }) : _service = service,
       _analyticsService = analyticsService,
       _exportService = exportService;

  final LocalBatch batch;
  final VoidCallback onBack;

  /// Open straight into the output preview of the default selection once the
  /// scans are loaded (used by the list page's "View output").
  final bool startInPreview;

  /// Starting state of the "Include Certificates?" switch.
  final bool initialIncludeCertificates;
  final GuidanceWebResultsService? _service;
  final GuidanceWebAnalyticsService? _analyticsService;

  /// Injectable for tests; builds the PDF.
  final GuidanceWebExportService? _exportService;

  @override
  State<GuidanceWebExportBatchView> createState() =>
      _GuidanceWebExportBatchViewState();
}

/// What a preview shows: optionally the batch summary, plus some scans.
class _Preview {
  const _Preview({required this.includeSummary, required this.scans});
  final bool includeSummary;
  final List<LocalScan> scans;
}

class _GuidanceWebExportBatchViewState
    extends State<GuidanceWebExportBatchView> {
  late final GuidanceWebResultsService _service =
      widget._service ?? GuidanceWebResultsService();
  late final GuidanceWebExportService _export =
      widget._exportService ??
      GuidanceWebExportService(
        analytics: widget._analyticsService,
        results: _service,
      );

  bool _loading = true;
  String? _error;
  List<LocalScan> _scans = [];

  bool _includeSummary = true;
  late bool _includeCertificates = widget.initialIncludeCertificates;
  final Set<String> _selected = {};
  _Preview? _preview;
  Future<Uint8List>? _pdf;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scans = await _service.loadScansForBatch(widget.batch);
      if (!mounted) return;
      setState(() {
        _scans = scans;
        // Tagged scans start checked; untagged ones start unchecked — except
        // when opened from the list's "View output", which previews the
        // whole-batch export (every examinee).
        _selected
          ..clear()
          ..addAll([
            for (final s in scans)
              if (s.examinee != null || widget.startInPreview) s.id,
          ]);
        _loading = false;
      });
      if (widget.startInPreview && _preview == null) {
        _openPreview(_Preview(includeSummary: _includeSummary, scans: _selectedScans));
      }
    } on GuidanceWebResultsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load results for this batch. Please try again.';
        _loading = false;
      });
    }
  }

  /// Builds the PDF for [p] (batch summary and/or the given scans).
  Future<Uint8List> _buildPdf(_Preview p) => _export.buildPdf(
    batch: widget.batch,
    includeSummary: p.includeSummary,
    selected: p.scans,
    allScans: _scans,
    includeCertificates: _includeCertificates,
  );

  void _openPreview(_Preview p) {
    setState(() {
      _preview = p;
      _pdf = _buildPdf(p);
    });
  }

  String get _fileName => '${widget.batch.batchCode}_export.pdf';

  String get _selectionSummary {
    final count = _selected.length;
    final summary = _includeSummary ? 'the batch summary and ' : '';
    return 'Export ${widget.batch.batchCode} as one PDF containing '
        '$summary$count examinee analytics page${count == 1 ? '' : 's'}'
        '${_includeCertificates ? ', each followed by its certificate' : ''}.';
  }

  Future<void> _confirmExport() async {
    final decision = await showExportConfirmDialog(
      context,
      summary: _selectionSummary,
      includeCertificates: _includeCertificates,
    );
    if (!mounted || decision == null) return;
    setState(() => _includeCertificates = decision.includeCertificates);
    if (decision.choice == ExportChoice.viewOutput) {
      _openPreview(
        _Preview(includeSummary: _includeSummary, scans: _selectedScans),
      );
    } else {
      await _exportSelection();
    }
  }

  Future<void> _exportSelection() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final bytes = await _buildPdf(
        _Preview(includeSummary: _includeSummary, scans: _selectedScans),
      );
      await Printing.sharePdf(bytes: bytes, filename: _fileName);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the PDF. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  List<LocalScan> get _selectedScans => [
    for (final s in _scans)
      if (_selected.contains(s.id)) s,
  ];

  bool get _hasSelection => _includeSummary || _selected.isNotEmpty;

  bool get _allChecked =>
      _includeSummary && _scans.isNotEmpty && _selected.length == _scans.length;

  /// "Check all": checks the batch summary and every scan; when everything is
  /// already checked, unchecks everything.
  void _toggleAll() {
    setState(() {
      if (_allChecked) {
        _includeSummary = false;
        _selected.clear();
      } else {
        _includeSummary = true;
        _selected
          ..clear()
          ..addAll([for (final s in _scans) s.id]);
      }
    });
  }

  String _nameOf(LocalScan s) => s.examinee?.displayName ?? 'Untagged';

  int get _denominatorBase => widget.batch.examCode == 'TAT' ? 160 : 0;

  String _scoreOf(LocalScan s) {
    final r = s.result;
    if (r == null) return '—';
    final denom = _denominatorBase != 0 ? _denominatorBase : r.totalItems;
    return '${r.rawScore} / $denom';
  }

  String _percentOf(LocalScan s) {
    final r = s.result;
    return r == null ? '—' : '${r.percentage.toStringAsFixed(1)}%';
  }

  String _statusOf(LocalScan s) => s.result?.status ?? 'Ungraded';

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmtDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

  BoxDecoration get _cardDecoration => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: AppColors.cardBorder),
  );

  String get _batchTitle {
    final b = widget.batch;
    final title = b.examTitle.isNotEmpty ? b.examTitle : b.examCode;
    return '${b.batchCode} — $title (${_fmtDate(b.createdAt)})';
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    if (preview != null) {
      return _PdfPreviewPane(
        pdf: _pdf!,
        fileName: _fileName,
        onBack: () => setState(() {
          _preview = null;
          _pdf = null;
        }),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TextButton.icon(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Back to List'),
              ),
              const Spacer(),
              if (!_loading && _scans.isNotEmpty) ...[
                IncludeCertificatesSwitch(
                  value: _includeCertificates,
                  onChanged: (v) => setState(() => _includeCertificates = v),
                ),
                const SizedBox(width: 24),
              ],
              if (!_loading && _scans.isNotEmpty)
                Padding(
                  // Aligns the checkbox with the row checkboxes below.
                  padding: const EdgeInsets.only(right: 16),
                  child: Row(
                    children: [
                      Text(
                        'Check all',
                        style: AppTextStyles.body(
                          size: 11,
                          weight: FontWeight.w700,
                          color: AppColors.textGray,
                        ),
                      ),
                      _selectionCheckbox(
                        key: const Key('checkAllDot'),
                        on: _allChecked,
                        tooltip: _allChecked ? 'Uncheck all' : 'Check all',
                        onTap: _toggleAll,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _buildSummaryRow(),
          const SizedBox(height: 16),
          Expanded(child: _buildBody()),
          const SizedBox(height: 12),
          _buildActions(),
        ],
      ),
    );
  }

  Widget _selectionCheckbox({
    required bool on,
    required VoidCallback onTap,
    required String tooltip,
    Key? key,
  }) {
    return Tooltip(
      message: tooltip,
      child: Checkbox(
        key: key,
        value: on,
        onChanged: (_) => onTap(),
        activeColor: AppColors.primaryGreen,
        checkColor: Colors.white,
        semanticLabel: tooltip,
      ),
    );
  }

  Widget _viewButton(VoidCallback onPressed, {Key? key}) => TextButton(
    key: key,
    onPressed: onPressed,
    child: Text(
      'view',
      style: AppTextStyles.body(
        size: 12.5,
        weight: FontWeight.w800,
        color: AppColors.darkNavy,
      ),
    ),
  );

  Widget _buildSummaryRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: _cardDecoration,
      child: Row(
        children: [
          Expanded(
            child: Text(
              _batchTitle,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body(size: 13, weight: FontWeight.w600),
            ),
          ),
          Text(
            'Batch summary',
            style: AppTextStyles.body(size: 11, color: AppColors.textGray),
          ),
          const SizedBox(width: 12),
          _viewButton(
            () => _openPreview(
              const _Preview(includeSummary: true, scans: []),
            ),
            key: const Key('summaryView'),
          ),
          _selectionCheckbox(
            key: const Key('summaryDot'),
            on: _includeSummary,
            tooltip: _includeSummary
                ? 'Included in export'
                : 'Not included in export',
            onTap: () => setState(() => _includeSummary = !_includeSummary),
          ),
        ],
      ),
    );
  }

  Widget _message(String text, {bool isError = false}) => Center(
    child: Text(
      text,
      style: AppTextStyles.body(
        size: 11.5,
        color: isError ? AppColors.warmRedOrange : AppColors.textGray,
      ),
    ),
  );

  Widget _buildBody() {
    if (_loading) return _message('Loading results...');
    if (_error != null) return _message(_error!, isError: true);
    if (_scans.isEmpty) return _message('No results found for this batch.');

    final headerStyle = AppTextStyles.body(
      size: 9.5,
      weight: FontWeight.w800,
      color: AppColors.textGray,
    );
    return Container(
      decoration: _cardDecoration,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                SizedBox(width: 32, child: Text('#', style: headerStyle)),
                Expanded(flex: 4, child: Text('EXAMINEE', style: headerStyle)),
                Expanded(flex: 2, child: Text('SCORE', style: headerStyle)),
                Expanded(flex: 1, child: Text('%', style: headerStyle)),
                Expanded(flex: 2, child: Text('STATUS', style: headerStyle)),
                const SizedBox(width: 96),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.cardBorder),
          Expanded(
            child: ListView.separated(
              itemCount: _scans.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.cardBorder),
              itemBuilder: (_, i) => _scanRow(i, _scans[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scanRow(int index, LocalScan s) {
    final tagged = s.examinee != null;
    final on = _selected.contains(s.id);
    final textStyle = AppTextStyles.body(
      size: 11,
      color: tagged ? AppColors.textDark : AppColors.textGray,
    );
    return Padding(
      key: Key('exportScanRow_${s.id}'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          SizedBox(width: 32, child: Text('${index + 1}', style: textStyle)),
          Expanded(
            flex: 4,
            child: Text(
              _nameOf(s),
              style: textStyle.copyWith(
                fontWeight: tagged ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
          Expanded(flex: 2, child: Text(_scoreOf(s), style: textStyle)),
          Expanded(flex: 1, child: Text(_percentOf(s), style: textStyle)),
          Expanded(flex: 2, child: Text(_statusOf(s), style: textStyle)),
          SizedBox(
            width: 96,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _viewButton(
                  () => _openPreview(_Preview(includeSummary: false, scans: [s])),
                  key: Key('scanView_${s.id}'),
                ),
                _selectionCheckbox(
                  key: Key('scanDot_${s.id}'),
                  on: on,
                  tooltip: on ? 'Included in export' : 'Not included in export',
                  onTap: () => setState(() {
                    on ? _selected.remove(s.id) : _selected.add(s.id);
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    final count = _selected.length;
    final summary = _includeSummary ? 'batch summary + ' : '';
    return Row(
      children: [
        Text(
          _hasSelection
              ? 'Selected: $summary$count examinee${count == 1 ? '' : 's'}'
              : 'Nothing selected',
          key: const Key('selectionLabel'),
          style: AppTextStyles.body(size: 11, color: AppColors.textGray),
        ),
        const Spacer(),
        OutlinedButton(
          key: const Key('viewOutputButton'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.darkNavy,
            side: BorderSide(
              color: _hasSelection ? AppColors.darkNavy : AppColors.cardBorder,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _hasSelection
              ? () => _openPreview(
                  _Preview(
                    includeSummary: _includeSummary,
                    scans: _selectedScans,
                  ),
                )
              : null,
          child: Text(
            'View Selected',
            style: AppTextStyles.body(
              size: 15,
              weight: FontWeight.w800,
              color: _hasSelection ? AppColors.darkNavy : AppColors.textGray,
            ),
          ),
        ),
        const SizedBox(width: 16),
        FilledButton(
          key: const Key('exportPdfButton'),
          onPressed: (_hasSelection && !_exporting) ? _confirmExport : null,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primaryGreen,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
          child: Text(
            _exporting ? 'Exporting...' : 'Export Selected',
            style: AppTextStyles.body(
              size: 15,
              weight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}

/// While Ctrl (or Cmd) is held the page scrollers ignore the mouse wheel, so
/// Ctrl+scroll can zoom the preview instead of scrolling it.
class _CtrlAwareScrollPhysics extends ScrollPhysics {
  const _CtrlAwareScrollPhysics({super.parent});

  @override
  _CtrlAwareScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _CtrlAwareScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed) return false;
    return super.shouldAcceptUserOffset(position);
  }
}

/// One rendered page of the preview: PNG bytes (decoded lazily by the list, so
/// a big batch does not hold every page as raw pixels) and its shape.
class _PageImage {
  const _PageImage(this.png, this.aspect);
  final Uint8List png;

  /// width / height
  final double aspect;
}

/// The export as printed: the real PDF (built by [GuidanceWebExportService])
/// in a fixed frame, drawn page by page.
///
///  * Pages appear as soon as each one is drawn — there is no full-screen
///    spinner; a blank page holds the place of the one being drawn.
///  * Zoom (slider, buttons, Ctrl+wheel) just resizes the pages already drawn,
///    so it is instant and never redraws anything.
///  * The frame and the toolbar above it never change size.
class _PdfPreviewPane extends StatefulWidget {
  const _PdfPreviewPane({
    required this.pdf,
    required this.fileName,
    required this.onBack,
  });

  final Future<Uint8List> pdf;
  final String fileName;
  final VoidCallback onBack;

  @override
  State<_PdfPreviewPane> createState() => _PdfPreviewPaneState();
}

class _PdfPreviewPaneState extends State<_PdfPreviewPane> {
  static const double _minZoom = 0.3;
  static const double _maxZoom = 2.0;

  /// The zoom every preview opens at, and what "Fit" returns to (50%).
  static const double _defaultZoom = 0.5;

  /// Pages are drawn at this resolution and scaled to the zoom, so they stay
  /// reasonably sharp up to about 100%.
  static const double _renderDpi = 150;

  double _zoom = _defaultZoom;

  Uint8List? _bytes;
  final List<_PageImage> _pages = [];
  bool _drawing = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.pdf;
      if (!mounted) return;
      setState(() => _bytes = bytes);
      // A fresh copy: on the web the viewer takes ownership of the bytes it is
      // given, so the same buffer cannot be handed over twice.
      await for (final page in Printing.raster(_copy(bytes), dpi: _renderDpi)) {
        final png = await page.toPng();
        if (!mounted) return;
        setState(() => _pages.add(_PageImage(png, page.width / page.height)));
      }
    } catch (_) {
      if (mounted && _pages.isEmpty) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _drawing = false);
    }
  }

  void _setZoom(double v) =>
      setState(() => _zoom = v.clamp(_minZoom, _maxZoom).toDouble());

  static Uint8List _copy(Uint8List bytes) => Uint8List.fromList(bytes);

  /// Ctrl (or Cmd) + mouse wheel zooms the preview: wheel up zooms in.
  ///
  /// Flutter on the web reports Ctrl+wheel (and trackpad pinch) as a
  /// [PointerScaleEvent], other platforms as a [PointerScrollEvent]; both are
  /// handled.
  void _onPointerSignal(PointerSignalEvent event) {
    double? factor;
    if (event is PointerScaleEvent) {
      // scale is 1.0 = no change; soften it so one wheel notch is ~15%.
      factor = math.pow(event.scale, 0.35).toDouble();
    } else if (event is PointerScrollEvent) {
      final kb = HardwareKeyboard.instance;
      if (!(kb.isControlPressed || kb.isMetaPressed)) return;
      factor = event.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15;
    } else {
      return;
    }
    final f = factor;
    // Registering marks the event as handled, so the browser does not also
    // zoom the whole page.
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _setZoom(_zoom * f),
    );
  }

  Widget _zoomControls() {
    return Row(
      key: const Key('previewZoomControls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('zoomOut'),
          tooltip: 'Zoom out',
          icon: const Icon(Icons.zoom_out),
          onPressed: _zoom > _minZoom ? () => _setZoom(_zoom - 0.1) : null,
        ),
        SizedBox(
          width: 170,
          child: Slider(
            key: const Key('zoomSlider'),
            min: _minZoom,
            max: _maxZoom,
            value: _zoom,
            onChanged: _setZoom,
          ),
        ),
        IconButton(
          key: const Key('zoomIn'),
          tooltip: 'Zoom in',
          icon: const Icon(Icons.zoom_in),
          onPressed: _zoom < _maxZoom ? () => _setZoom(_zoom + 0.1) : null,
        ),
        SizedBox(
          width: 48,
          child: Text(
            '${(_zoom * 100).round()}%',
            key: const Key('zoomLabel'),
            textAlign: TextAlign.right,
            style: AppTextStyles.body(size: 12, weight: FontWeight.w700),
          ),
        ),
        // "Fit" is the default view size: 50%.
        TextButton(
          key: const Key('zoomFit'),
          onPressed: () => _setZoom(_defaultZoom),
          child: const Text('Fit'),
        ),
      ],
    );
  }

  Widget _toolbar() {
    final bytes = _bytes;
    return Row(
      children: [
        TextButton.icon(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Back to Checklist'),
        ),
        const Spacer(),
        if (_pages.isNotEmpty) _zoomControls(),
        if (bytes != null) ...[
          const SizedBox(width: 12),
          OutlinedButton.icon(
            key: const Key('previewPrint'),
            onPressed: () => Printing.layoutPdf(
              onLayout: (_) async => _copy(bytes),
              name: widget.fileName,
            ),
            icon: const Icon(Icons.print, size: 16),
            label: const Text('Print'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('previewDownload'),
            onPressed: () => Printing.sharePdf(
              bytes: _copy(bytes),
              filename: widget.fileName,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primaryGreen,
            ),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Download'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(),
          const SizedBox(height: 8),
          Expanded(child: _frame(context)),
        ],
      ),
    );
  }

  /// A white page-shaped placeholder for a page that is not drawn yet.
  Widget _placeholderPage(double width, String label) {
    return Container(
      key: const Key('previewPlaceholder'),
      width: width,
      height: width * 11 / 8.5,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Text(
        label,
        style: AppTextStyles.body(size: 12, color: AppColors.textGray),
      ),
    );
  }

  Widget _pageTile(double width, _PageImage page) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Image.memory(
        page.png,
        width: width,
        fit: BoxFit.fitWidth,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  /// The fixed frame: same size whatever the zoom. Pages narrower than the
  /// frame are centred; wider ones scroll sideways inside it.
  Widget _frame(BuildContext context) {
    Widget inner;
    if (_failed) {
      inner = Center(
        child: Text(
          'Could not build the export preview. Please try again.',
          key: const Key('previewError'),
          style: AppTextStyles.body(
            size: 11.5,
            color: AppColors.warmRedOrange,
          ),
        ),
      );
    } else {
      inner = LayoutBuilder(
        builder: (context, box) {
          final width = (box.maxWidth - 32) * _zoom;
          final extra = _drawing ? 1 : 0;
          final list = ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 16),
            itemCount: _pages.length + extra,
            separatorBuilder: (_, _) => const SizedBox(height: 14),
            itemBuilder: (_, i) {
              final child = i < _pages.length
                  ? _pageTile(width, _pages[i])
                  : _placeholderPage(
                      width,
                      _bytes == null
                          ? 'Preparing your export...'
                          : 'Drawing page ${_pages.length + 1}...',
                    );
              return Center(child: child);
            },
          );
          return _zoom > 1.0
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: width + 32, child: list),
                )
              : list;
        },
      );
    }
    return Container(
      key: const Key('previewFrame'),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: const Color(0xFFE9E9E9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(
            context,
          ).copyWith(physics: const _CtrlAwareScrollPhysics()),
          child: inner,
        ),
      ),
    );
  }
}
