import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/local_batch.dart';
import '../export/guidance_web_export_service.dart';
import '../services/guidance_web_analytics_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_export_batch_view.dart';

const List<(String, String)> _exportExamTypes = [
  ('AT', 'Admission Test (AT)'),
  ('QTM', 'Quantitative Math Test (QTM)'),
  ('TAT', 'Teaching Aptitude Test (TAT)'),
];

/// The Guidance Council Web Console's Export page — READ-ONLY listing of the
/// batches that can be exported.
///
/// The search box matches a batch (by code or title) directly. It also finds
/// batches by examinee name or Temporary Examinee ID: those batches are shown
/// with a "Contains search" note, because the batch itself did not match, one
/// of its examinees did. Names are looked up in each batch's scans, loaded
/// once per batch on the first name search and cached for the session.
///
/// `view` opens the batch's export checklist ([GuidanceWebExportBatchView]);
/// the list's own `export` downloads the whole batch (batch analytics + a page
/// for every examinee) as a PDF.
class GuidanceWebExportView extends StatefulWidget {
  const GuidanceWebExportView({
    super.key,
    GuidanceWebAnalyticsService? analyticsService,
    GuidanceWebResultsService? resultsService,
  }) : _analyticsService = analyticsService,
       _resultsService = resultsService;

  final GuidanceWebAnalyticsService? _analyticsService;
  final GuidanceWebResultsService? _resultsService;

  @override
  State<GuidanceWebExportView> createState() => _GuidanceWebExportViewState();
}

class _GuidanceWebExportViewState extends State<GuidanceWebExportView> {
  late final GuidanceWebAnalyticsService _analytics =
      widget._analyticsService ?? GuidanceWebAnalyticsService();
  late final GuidanceWebResultsService _results =
      widget._resultsService ?? GuidanceWebResultsService();
  final TextEditingController _search = TextEditingController();

  bool _loading = true;
  String? _error;
  AnalyticsCatalog? _catalog;

  String _examCode = 'AT';
  AnalyticsBatchStatus _status = AnalyticsBatchStatus.all;

  /// batch id -> scans, filled lazily by name searches.
  final Map<String, List<LocalScan>> _scansByBatch = {};
  bool _searchingNames = false;
  Timer? _debounce;
  int _searchSeq = 0;

  LocalBatch? _viewing;

  /// Whether the next opened batch goes straight to its output preview.
  bool _startInPreview = false;

  /// "Include Certificates?" as chosen in the list's Export popup; carried
  /// into the opened batch and used by the quick export.
  bool _includeCertificates = true;

  /// Batch whose quick export (list `export` button) is being built.
  String? _exportingBatchId;

  late final GuidanceWebExportService _exporter = GuidanceWebExportService(
    analytics: _analytics,
    results: _results,
  );

  /// The list's `export`: asks first (Export / View output / Cancel).
  Future<void> _confirmQuickExport(LocalBatch b) async {
    final decision = await showExportConfirmDialog(
      context,
      summary:
          'Export ${b.batchCode} as one PDF containing the batch analytics and '
          'an analytics page for every examinee in the batch.',
      includeCertificates: _includeCertificates,
    );
    if (!mounted || decision == null) return;
    setState(() => _includeCertificates = decision.includeCertificates);
    if (decision.choice == ExportChoice.viewOutput) {
      setState(() {
        _viewing = b;
        _startInPreview = true;
      });
    } else {
      await _quickExport(b);
    }
  }

  /// Quick export straight from the list: the batch analytics plus a page for
  /// every examinee in the batch.
  Future<void> _quickExport(LocalBatch b) async {
    if (_exportingBatchId != null) return;
    setState(() => _exportingBatchId = b.id);
    try {
      final bytes = await _exporter.buildDefaultPdf(
        b,
        includeCertificates: _includeCertificates,
      );
      await Printing.sharePdf(bytes: bytes, filename: '${b.batchCode}_export.pdf');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the PDF. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _exportingBatchId = null);
    }
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    _loadCatalog();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await _analytics.loadCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } on GuidanceWebAnalyticsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load examination batches. Please try again.';
        _loading = false;
      });
    }
  }

  String get _term => _search.text.trim().toLowerCase();

  /// Batches for the chosen exam type and status, newest first.
  List<LocalBatch> get _baseBatches {
    final catalog = _catalog;
    if (catalog == null) return const [];
    if (_status != AnalyticsBatchStatus.all && !catalog.archiveFilterAvailable) {
      return const [];
    }
    return catalog.batchesFor(examCode: _examCode, status: _status);
  }

  bool _batchMatches(LocalBatch b, String term) =>
      b.batchCode.toLowerCase().contains(term) ||
      b.examTitle.toLowerCase().contains(term);

  bool _nameMatches(LocalBatch b, String term) {
    final scans = _scansByBatch[b.id];
    if (scans == null) return false;
    for (final scan in scans) {
      final e = scan.examinee;
      if (e == null) continue;
      if (e.firstName.toLowerCase().contains(term) ||
          e.middleName.toLowerCase().contains(term) ||
          e.lastName.toLowerCase().contains(term) ||
          e.examineeNumber.toLowerCase().contains(term)) {
        return true;
      }
    }
    return false;
  }

  void _onSearchChanged() {
    setState(() {});
    _debounce?.cancel();
    if (_term.isEmpty) {
      setState(() => _searchingNames = false);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), _loadScansForSearch);
  }

  /// Loads (once) the scans of every batch currently in scope so examinee
  /// names can be matched. A batch whose scans fail to load simply cannot
  /// match by name; it still matches by code/title.
  Future<void> _loadScansForSearch() async {
    final seq = ++_searchSeq;
    final missing = [
      for (final b in _baseBatches)
        if (!_scansByBatch.containsKey(b.id)) b,
    ];
    if (missing.isEmpty) {
      if (mounted) setState(() => _searchingNames = false);
      return;
    }
    setState(() => _searchingNames = true);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= missing.length) return;
        try {
          final scans = await _results.loadScansForBatch(missing[i]);
          _scansByBatch[missing[i].id] = scans;
        } catch (_) {
          // Leave uncached; it just can't match by name.
        }
      }
    }

    await Future.wait([
      for (var w = 0; w < math.min(4, missing.length); w++) worker(),
    ]);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _searchingNames = false);
  }

  void _setScope({String? examCode, AnalyticsBatchStatus? status}) {
    setState(() {
      _examCode = examCode ?? _examCode;
      _status = status ?? _status;
    });
    if (_term.isNotEmpty) _loadScansForSearch();
  }

  @override
  Widget build(BuildContext context) {
    final viewing = _viewing;
    if (viewing != null) {
      return GuidanceWebExportBatchView(
        key: ValueKey(viewing.id),
        batch: viewing,
        service: _results,
        analyticsService: _analytics,
        startInPreview: _startInPreview,
        initialIncludeCertificates: _includeCertificates,
        onBack: () => setState(() {
          _viewing = null;
          _startInPreview = false;
        }),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(),
          const SizedBox(height: 16),
          Text('Batches', style: AppTextStyles.heading(size: 16)),
          const SizedBox(height: 8),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: AppColors.cardBorder),
  );

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
  );

  Widget _buildControls() {
    final archiveOk = _catalog?.archiveFilterAvailable ?? false;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 420,
            child: TextField(
              key: const Key('exportSearch'),
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search batch, name or Temporary Examinee ID...',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _search.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _search.clear,
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 260,
            child: DropdownButtonFormField<String>(
              key: const Key('exportExamType'),
              initialValue: _examCode,
              isExpanded: true,
              decoration: _decoration('Exam Type'),
              items: [
                for (final (code, label) in _exportExamTypes)
                  DropdownMenuItem(value: code, child: Text(label)),
              ],
              onChanged: (v) {
                if (v != null && v != _examCode) _setScope(examCode: v);
              },
            ),
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<AnalyticsBatchStatus>(
              key: const Key('exportBatchStatus'),
              initialValue: _status,
              isExpanded: true,
              decoration: _decoration('Batch Status'),
              items: [
                const DropdownMenuItem(
                  value: AnalyticsBatchStatus.all,
                  child: Text('All'),
                ),
                DropdownMenuItem(
                  value: AnalyticsBatchStatus.current,
                  enabled: archiveOk,
                  child: const Text('Current'),
                ),
                DropdownMenuItem(
                  value: AnalyticsBatchStatus.archived,
                  enabled: archiveOk,
                  child: const Text('Archived'),
                ),
              ],
              onChanged: (v) {
                if (v != null && v != _status) _setScope(status: v);
              },
            ),
          ),
          if (_searchingNames)
            Text(
              'Searching names...',
              style: AppTextStyles.body(size: 11, color: AppColors.textGray),
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

  Widget _buildList() {
    if (_loading) return _message('Loading batches...');
    if (_error != null) return _message(_error!, isError: true);

    final term = _term;
    final rows = <(LocalBatch, bool)>[]; // (batch, containsSearchOnly)
    for (final b in _baseBatches) {
      if (term.isEmpty || _batchMatches(b, term)) {
        rows.add((b, false));
      } else if (_nameMatches(b, term)) {
        rows.add((b, true));
      }
    }
    if (rows.isEmpty) {
      if (_searchingNames) return _message('Searching...');
      return _message(
        term.isEmpty ? 'No batches for this selection.' : 'No matches found.',
      );
    }
    return ListView.separated(
      // Room for the hover shadow around each row.
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _batchRow(rows[i].$1, rows[i].$2),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmtDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

  Widget _batchRow(LocalBatch b, bool containsSearch) {
    final title = b.examTitle.isNotEmpty ? b.examTitle : b.examCode;
    return _HoverRow(
      key: Key('exportRow_${b.id}'),
      onTap: () => setState(() {
        _startInPreview = false;
        _viewing = b;
      }),
      child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '${b.batchCode} — $title (${_fmtDate(b.createdAt)})',
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body(size: 13),
            ),
          ),
          if (containsSearch) ...[
            const SizedBox(width: 16),
            Text(
              'Contains search',
              key: const Key('containsSearchNote'),
              style: AppTextStyles.body(
                size: 11.5,
                weight: FontWeight.w600,
                color: AppColors.textGray,
              ).copyWith(fontStyle: FontStyle.italic),
            ),
          ],
          const Spacer(),
          TextButton(
            key: Key('exportButton_${b.id}'),
            onPressed: _exportingBatchId == null ? () => _confirmQuickExport(b) : null,
            child: Text(
              _exportingBatchId == b.id ? 'exporting...' : 'export',
              style: AppTextStyles.body(
                size: 13,
                weight: FontWeight.w800,
                color: AppColors.primaryGreen,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: Key('viewButton_${b.id}'),
            onPressed: () => setState(() {
              _startInPreview = false;
              _viewing = b;
            }),
            child: Text(
              'view',
              style: AppTextStyles.body(
                size: 13,
                weight: FontWeight.w800,
                color: AppColors.darkNavy,
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// A batch row that lifts with a soft shadow while the pointer is over it.
class _HoverRow extends StatefulWidget {
  const _HoverRow({super.key, required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _hover ? AppColors.primaryGreen : AppColors.cardBorder,
          ),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ]
              : const [],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
