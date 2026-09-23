import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/local_batch.dart';
import '../export/guidance_web_export_service.dart';
import '../services/guidance_web_analytics_service.dart';
import '../services/guidance_web_results_service.dart';

/// What the person chose in the export confirmation popup.
enum ExportChoice { exportNow, viewOutput }

/// The "Export?" safety popup: says what will be exported and offers
/// `view output` first, so nobody exports blind. Null when cancelled.
Future<ExportChoice?> showExportConfirmDialog(
  BuildContext context, {
  required String summary,
}) {
  return showDialog<ExportChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('exportConfirmDialog'),
      title: const Text('Export?'),
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
          onPressed: () => Navigator.pop(ctx, ExportChoice.viewOutput),
          child: const Text('View output'),
        ),
        FilledButton(
          key: const Key('exportConfirmExport'),
          onPressed: () => Navigator.pop(ctx, ExportChoice.exportNow),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primaryGreen,
          ),
          child: const Text('Export'),
        ),
      ],
    ),
  );
}

/// Export → view: one batch's export checklist.
///
/// The batch summary row and every scan row has a checklist dot (green =
/// included in the export, grey = left out). `view output` previews what the
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
  }) : _service = service,
       _analyticsService = analyticsService,
       _exportService = exportService;

  final LocalBatch batch;
  final VoidCallback onBack;

  /// Open straight into the output preview of the default selection once the
  /// scans are loaded (used by the list page's "View output").
  final bool startInPreview;
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
        '$summary$count examinee page${count == 1 ? '' : 's'}.';
  }

  Future<void> _confirmExport() async {
    final choice = await showExportConfirmDialog(
      context,
      summary: _selectionSummary,
    );
    if (!mounted || choice == null) return;
    if (choice == ExportChoice.viewOutput) {
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
              if (!_loading && _scans.isNotEmpty)
                Padding(
                  // Lines the dot up with the row dots below.
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
                      _dot(
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

  Widget _dot({
    required bool on,
    required VoidCallback onTap,
    required String tooltip,
    Key? key,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? AppColors.primaryGreen : const Color(0xFFBDBDBD),
            ),
          ),
        ),
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
          _dot(
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
                _dot(
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
        TextButton(
          key: const Key('viewOutputButton'),
          onPressed: _hasSelection
              ? () => _openPreview(
                  _Preview(
                    includeSummary: _includeSummary,
                    scans: _selectedScans,
                  ),
                )
              : null,
          child: Text(
            'view output',
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
            _exporting ? 'exporting...' : 'export',
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

/// The export as printed: renders the real PDF (built by
/// [GuidanceWebExportService]) in a paged preview with print and download
/// actions.
class _PdfPreviewPane extends StatelessWidget {
  const _PdfPreviewPane({
    required this.pdf,
    required this.fileName,
    required this.onBack,
  });

  final Future<Uint8List> pdf;
  final String fileName;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back to Checklist'),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<Uint8List>(
              future: pdf,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError || snap.data == null) {
                  return Center(
                    child: Text(
                      'Could not build the export preview. Please try again.',
                      key: const Key('previewError'),
                      style: AppTextStyles.body(
                        size: 11.5,
                        color: AppColors.warmRedOrange,
                      ),
                    ),
                  );
                }
                final bytes = snap.data!;
                return PdfPreview(
                  key: const Key('pdfPreview'),
                  build: (_) async => bytes,
                  pdfFileName: fileName,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
