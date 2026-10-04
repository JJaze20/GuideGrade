import 'package:flutter/material.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../shared/widgets/state_views.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/surface_card.dart';

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
  }) : _service = service,
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
      padding: EdgeInsets.all(
        AppSpace.gutterFor(MediaQuery.sizeOf(context).width),
      ),
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

  Widget _buildControls() => SurfaceCard(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final search = TextField(
          key: const Key('archiveSearch'),
          controller: _search,
          style: AppTextStyles.text(),
          decoration: InputDecoration(
            labelText: 'Search completed batches',
            floatingLabelBehavior: constraints.maxWidth < 600
                ? FloatingLabelBehavior.always
                : FloatingLabelBehavior.auto,
            hintText: constraints.maxWidth < 600
                ? 'Search batches'
                : 'Batch code, exam, description or archived by',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: _search.clear,
                    icon: const Icon(Icons.close),
                  ),
          ),
        );
        final filter = DropdownButtonFormField<String>(
          key: const Key('archiveExamFilter'),
          initialValue: _examFilter,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Exam type'),
          items: _examFilterOptions
              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
              .toList(),
          onChanged: (v) => setState(() => _examFilter = v ?? 'All'),
        );
        if (constraints.maxWidth < 600) {
          return Column(
            children: [
              search,
              const SizedBox(height: AppSpace.md),
              filter,
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 2, child: search),
            const SizedBox(width: AppSpace.lg),
            Expanded(child: filter),
          ],
        );
      },
    ),
  );

  Widget _buildBody() {
    if (_loading) {
      return const LoadingState(message: 'Loading completed batches...');
    }
    if (_error != null) {
      return ErrorState(
        title: 'Could not load completed batches',
        message: _error!,
        onRetry: _load,
      );
    }
    if (_entries.isEmpty) {
      return const EmptyState(
        title: 'No completed batches yet.',
        message: 'Archive an eligible batch from Results to see it here.',
        icon: Icons.inventory_2_outlined,
      );
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return EmptyState(
        title: 'No completed batches match your search or filter.',
        message: 'Try another search or reset the filters.',
        action: OutlinedButton(
          onPressed: () {
            _search.clear();
            setState(() => _examFilter = 'All');
          },
          child: const Text('Clear filters'),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 700) {
          return ListView.separated(
            key: const Key('archiveCards'),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
            itemBuilder: (_, i) => _recordCard(rows[i]),
          );
        }
        final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
        final minimumWidth = 1100 * scale.clamp(1.0, 2.0);
        final width = constraints.maxWidth > minimumWidth
            ? constraints.maxWidth
            : minimumWidth;
        return Scrollbar(
          notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            key: const Key('archiveTable'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _headerRow(),
                    const Divider(),
                    Expanded(
                      child: ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (_, i) => _row(rows[i]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _headerRow() {
    Widget h(String text, int flex) => Expanded(
      flex: flex,
      child: Text(text, style: AppTextStyles.label()),
    );
    return Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        children: [
          h('BATCH CODE', 2),
          h('EXAM', 1),
          h('EXAM TITLE', 3),
          h('SCANS', 1),
          h('STATUS', 2),
          h('ARCHIVED', 2),
          h('ARCHIVED BY', 2),
          const SizedBox(width: 80, child: Text('ACTION')),
        ],
      ),
    );
  }

  Widget _viewButton(ArchivedBatchEntry e) => Tooltip(
    message: 'View results for ${e.batch.batchCode}',
    child: TextButton(
      onPressed: () => setState(() => _viewing = e),
      style: TextButton.styleFrom(
        minimumSize: const Size(64, AppHit.minTarget),
      ),
      child: const Text('View'),
    ),
  );

  Widget _row(ArchivedBatchEntry e) {
    Widget c(String text, int flex, {bool strong = false}) => Expanded(
      flex: flex,
      child: Tooltip(
        message: text,
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.text(
            weight: strong ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.sm,
      ),
      child: Row(
        children: [
          c(e.batch.batchCode, 2, strong: true),
          c(e.batch.examCode, 1),
          c(
            e.batch.examTitle.isEmpty ? e.batch.examCode : e.batch.examTitle,
            3,
          ),
          c('${e.scanCount}', 1),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: BatchStatusBadge(status: e.batch.status),
            ),
          ),
          c(_formatDate(e.archive.archivedAt), 2),
          c(e.archive.archivedByName ?? '—', 2),
          SizedBox(width: 80, child: _viewButton(e)),
        ],
      ),
    );
  }

  Widget _recordCard(ArchivedBatchEntry e) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(e.batch.batchCode, style: AppTextStyles.subtitle()),
        const SizedBox(height: AppSpace.sm),
        BatchStatusBadge(status: e.batch.status),
        const SizedBox(height: AppSpace.md),
        Text(
          '${e.batch.examCode} · ${e.batch.examTitle}',
          style: AppTextStyles.text(),
        ),
        if (e.batch.description.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          Text(e.batch.description, style: AppTextStyles.caption()),
        ],
        const SizedBox(height: AppSpace.sm),
        Text(
          '${e.scanCount} scans · Archived ${_formatDate(e.archive.archivedAt)}',
          style: AppTextStyles.caption(),
        ),
        Text(
          'Archived by: ${e.archive.archivedByName ?? '—'}',
          style: AppTextStyles.caption(),
        ),
        Align(alignment: Alignment.centerRight, child: _viewButton(e)),
      ],
    ),
  );

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String _formatDate(DateTime d) {
    final l = d.toLocal();
    return '${_months[l.month - 1]} ${l.day}, ${l.year}';
  }
}
