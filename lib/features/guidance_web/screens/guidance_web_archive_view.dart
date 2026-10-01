import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/batch_archive.dart';
import '../services/guidance_web_archive_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_results_view.dart';

/// The Guidance Council Web Console's Archive page: every batch archived in
/// the Web application (a `batch_archives` marker exists), with search and
/// an exam-type filter.
///
/// Archiving is an organization marker only — nothing was deleted or moved,
/// and there is no restore. "View" opens the batch in the EXISTING
/// [GuidanceWebResultsView] (archive mode), so its scans, scores, answers,
/// examinee information, scanned images and every Detailed Result view are
/// exactly what the normal Results page shows — no second implementation.
class GuidanceWebArchiveView extends StatefulWidget {
  const GuidanceWebArchiveView({
    super.key,
    GuidanceWebArchiveService? service,
    GuidanceWebResultsService? resultsService,
  })  : _service = service,
        _resultsService = resultsService;

  final GuidanceWebArchiveService? _service;
  final GuidanceWebResultsService? _resultsService;

  @override
  State<GuidanceWebArchiveView> createState() => _GuidanceWebArchiveViewState();
}

const List<String> _examFilterOptions = ['All', 'AT', 'TAT', 'QTM'];

class _GuidanceWebArchiveViewState extends State<GuidanceWebArchiveView> {
  late final GuidanceWebArchiveService _service =
      widget._service ?? GuidanceWebArchiveService();
  late final GuidanceWebResultsService _resultsService =
      widget._resultsService ?? GuidanceWebResultsService();
  final TextEditingController _search = TextEditingController();

  bool _loading = true;
  String? _error;
  List<ArchivedBatchEntry> _entries = [];
  String _examFilter = 'All';
  ArchivedBatchEntry? _viewing;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _service.loadArchivedBatches();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on GuidanceWebArchiveException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load completed batches. Please try again.';
        _loading = false;
      });
    }
  }

  List<ArchivedBatchEntry> get _filtered {
    final term = _search.text.trim().toLowerCase();
    return _entries.where((e) {
      if (_examFilter != 'All' && e.batch.examCode != _examFilter) return false;
      if (term.isEmpty) return true;
      return e.batch.batchCode.toLowerCase().contains(term) ||
          e.batch.examTitle.toLowerCase().contains(term) ||
          e.batch.description.toLowerCase().contains(term) ||
          (e.archive.archivedByName ?? '').toLowerCase().contains(term);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final viewing = _viewing;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: viewing != null
          ? GuidanceWebResultsView(
              service: _resultsService,
              archivedBatch: viewing.batch,
              onBackToArchive: () => setState(() => _viewing = null),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildControls(),
                const SizedBox(height: 16),
                Expanded(child: _buildBody()),
              ],
            ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search batch code, exam title, or archived by...',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _examFilter,
              decoration: InputDecoration(
                labelText: 'Exam type',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              items: _examFilterOptions
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) => setState(() => _examFilter = v ?? 'All'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return _message(FontAwesomeIcons.spinner, 'Loading completed batches...');
    if (_error != null) {
      return _message(FontAwesomeIcons.triangleExclamation, _error!, isError: true);
    }
    if (_entries.isEmpty) {
      return _message(FontAwesomeIcons.boxArchive, 'No completed batches yet.');
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return _message(FontAwesomeIcons.magnifyingGlass, 'No completed batches match your search or filter.');
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headerRow(),
          const Divider(height: 1, color: AppColors.cardBorder),
          Expanded(
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.cardBorder),
              itemBuilder: (_, i) => _row(rows[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerRow() {
    final style = AppTextStyles.body(size: 10, weight: FontWeight.w700, color: AppColors.textGray);
    Widget h(String t, int flex) => Expanded(flex: flex, child: Text(t, style: style));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          h('BATCH CODE', 2),
          h('EXAM', 1),
          h('EXAM TITLE', 3),
          h('SCANS', 1),
          h('STATUS', 2),
          h('ARCHIVED', 2),
          h('ARCHIVED BY', 2),
          const SizedBox(width: 70),
        ],
      ),
    );
  }

  Widget _row(ArchivedBatchEntry e) {
    final cell = AppTextStyles.body(size: 11);
    Widget c(String t, int flex, {TextStyle? style}) =>
        Expanded(flex: flex, child: Text(t, style: style ?? cell, overflow: TextOverflow.ellipsis));
    final by = e.archive.archivedByName;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          c(e.batch.batchCode, 2, style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
          c(e.batch.examCode, 1),
          c(e.batch.examTitle.isNotEmpty ? e.batch.examTitle : e.batch.examCode, 3),
          c('${e.scanCount}', 1),
          c(e.batch.status, 2),
          c(_formatDate(e.archive.archivedAt), 2),
          c((by == null || by.isEmpty) ? '—' : by, 2),
          SizedBox(
            width: 70,
            child: TextButton(
              onPressed: () => setState(() => _viewing = e),
              child: Text(
                'View',
                style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.primaryGreen),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(FaIconData icon, String message, {bool isError = false}) {
    final color = isError ? AppColors.warmRedOrange : AppColors.textGray;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FaIcon(icon, size: 36, color: color),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.body(size: 11.5, color: color),
            ),
          ),
        ],
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) {
    final l = d.toLocal();
    return '${_months[l.month - 1]} ${l.day}, ${l.year}';
  }
}
