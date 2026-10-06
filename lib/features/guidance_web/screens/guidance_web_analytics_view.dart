import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/analytics/at_batch_analytics.dart';
import '../../../core/analytics/qtm_batch_analytics.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../shared/widgets/surface_card.dart';
import '../../../shared/widgets/state_views.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../models/local_batch.dart';
import '../services/guidance_web_analytics_service.dart';
import 'guidance_web_examinee_analytics_view.dart';

/// The Guidance Council Web Console's Analytics page — READ-ONLY.
///
/// Filters (Exam Type, Batch Status, Batch) select which batches are
/// analyzed; the statistics come from the existing pure analytics helpers
/// over each scan's STORED result. Web-archived batches are included and are
/// identified by `batch_archives` markers only. See
/// [GuidanceWebAnalyticsService] for the retrieval and Answer Key rules.
class GuidanceWebBatchAnalyticsView extends StatefulWidget {
  const GuidanceWebBatchAnalyticsView({
    super.key,
    GuidanceWebAnalyticsService? service,
  }) : _service = service;

  final GuidanceWebAnalyticsService? _service;

  @override
  State<GuidanceWebBatchAnalyticsView> createState() =>
      _GuidanceWebBatchAnalyticsViewState();
}

/// (code, "Title (CODE)") pairs in the canonical catalog's own order
/// (AT, QTM, TAT) -- reads exam_catalog.dart's examTypeDisplayLabel
/// instead of a separately hand-maintained copy.
final List<(String, String)> _examTypes = [
  for (final entry in examCatalog)
    (entry.examCode, examTypeDisplayLabel(entry.examCode)),
];

class _GuidanceWebBatchAnalyticsViewState
    extends State<GuidanceWebBatchAnalyticsView> {
  late final GuidanceWebAnalyticsService _service =
      widget._service ?? GuidanceWebAnalyticsService();

  AnalyticsCatalog? _catalog;
  bool _loadingCatalog = true;
  String? _catalogError;

  String _examCode = 'AT';
  AnalyticsBatchStatus _status = AnalyticsBatchStatus.all;
  LocalBatch? _batch; // null = All Batches

  bool _running = false;
  String? _progress;
  String? _narrowMessage;
  String? _runError;
  AnalyticsResult? _result;
  int _runSeq = 0;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loadingCatalog = true;
      _catalogError = null;
    });
    try {
      final catalog = await _service.loadCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loadingCatalog = false;
        _batch = null;
        // Archive status unknown -> never leave a status filter selected
        // that cannot be trusted.
        if (!catalog.archiveFilterAvailable) _status = AnalyticsBatchStatus.all;
      });
      _run();
    } on GuidanceWebAnalyticsException catch (e) {
      if (!mounted) return;
      setState(() {
        _catalogError = e.message;
        _loadingCatalog = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _catalogError = 'Could not load Analytics data. Please try again.';
        _loadingCatalog = false;
      });
    }
  }

  Future<void> _run() async {
    final catalog = _catalog;
    if (catalog == null) return;
    final seq = ++_runSeq;
    setState(() {
      _running = true;
      _progress = null;
      _narrowMessage = null;
      _runError = null;
      _result = null;
    });
    try {
      final result = await _service.analyze(
        catalog: catalog,
        examCode: _examCode,
        status: _status,
        batch: _batch,
        onProgress: (loaded, total) {
          if (mounted && seq == _runSeq) {
            setState(() => _progress = 'Loaded $loaded of $total batches');
          }
        },
      );
      if (!mounted || seq != _runSeq) return;
      setState(() {
        _result = result;
        _running = false;
      });
    } on AnalyticsTooManyBatchesException catch (e) {
      if (!mounted || seq != _runSeq) return;
      setState(() {
        _narrowMessage = e.message;
        _running = false;
      });
    } on GuidanceWebAnalyticsException catch (e) {
      if (!mounted || seq != _runSeq) return;
      setState(() {
        _runError = e.message;
        _running = false;
      });
    } catch (_) {
      if (!mounted || seq != _runSeq) return;
      setState(() {
        _runError = 'Could not load Analytics data. Please try again.';
        _running = false;
      });
    }
  }

  void _refresh() {
    _service.clearCache();
    _loadCatalog();
  }

  List<LocalBatch> get _batchOptions {
    final catalog = _catalog;
    if (catalog == null) return const [];
    if (_status != AnalyticsBatchStatus.all && !catalog.archiveFilterAvailable)
      return const [];
    return catalog.batchesFor(examCode: _examCode, status: _status);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(
        AppSpace.gutterFor(MediaQuery.sizeOf(context).width),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFilters(),
          const SizedBox(height: 16),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // --- filters -----------------------------------------------------------

  Widget _card({required Widget child}) =>
      SurfaceCard(color: const Color(0xFFF1F5FB), child: child);

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
  );

  Widget _buildFilters() {
    final catalog = _catalog;
    final archiveOk = catalog?.archiveFilterAvailable ?? true;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final narrow = box.maxWidth < 700;
              final fieldWidth = narrow
                  ? box.maxWidth
                  : (box.maxWidth - 80) / 4;
              return Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: fieldWidth,
                    child: DropdownButtonFormField<String>(
                      key: const Key('examTypeFilter'),
                      value: _examCode,
                      isExpanded: true,
                      decoration: _decoration('Exam Type'),
                      items: [
                        for (final (code, label) in _examTypes)
                          DropdownMenuItem(value: code, child: Text(label)),
                      ],
                      onChanged: catalog == null
                          ? null
                          : (v) {
                              if (v == null || v == _examCode) return;
                              setState(() {
                                _examCode = v;
                                _batch = null;
                              });
                              _run();
                            },
                    ),
                  ),
                  SizedBox(
                    width: fieldWidth,
                    child: DropdownButtonFormField<AnalyticsBatchStatus>(
                      key: const Key('batchStatusFilter'),
                      value: _status,
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
                          child: Text(
                            'Current',
                            style: archiveOk
                                ? null
                                : const TextStyle(color: Colors.grey),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AnalyticsBatchStatus.archived,
                          enabled: archiveOk,
                          child: Text(
                            'Archived',
                            style: archiveOk
                                ? null
                                : const TextStyle(color: Colors.grey),
                          ),
                        ),
                      ],
                      onChanged: catalog == null
                          ? null
                          : (v) {
                              if (v == null || v == _status) return;
                              setState(() {
                                _status = v;
                                _batch = null;
                              });
                              _run();
                            },
                    ),
                  ),
                  SizedBox(
                    width: narrow ? fieldWidth : fieldWidth * 2,
                    child: DropdownButtonFormField<LocalBatch?>(
                      key: const Key('batchFilter'),
                      value: _batch,
                      isExpanded: true,
                      decoration: _decoration('Batch'),
                      items: [
                        const DropdownMenuItem<LocalBatch?>(
                          value: null,
                          child: Text('All Batches'),
                        ),
                        for (final b in _batchOptions)
                          DropdownMenuItem<LocalBatch?>(
                            value: b,
                            child: Text(
                              '${b.batchCode} — ${b.examTitle.isNotEmpty ? b.examTitle : b.examCode}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: catalog == null
                          ? null
                          : (v) {
                              setState(() => _batch = v);
                              _run();
                            },
                    ),
                  ),
                  IconButton(
                    key: const Key('analyticsRefresh'),
                    tooltip: 'Refresh',
                    onPressed: _loadingCatalog || _running ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              );
            },
          ),
          if (catalog != null && !archiveOk) ...[
            const SizedBox(height: 10),
            Text(
              'Archive filtering is temporarily unavailable, so only "All" can be used right now.',
              key: const Key('archiveUnavailableNotice'),
              style: AppTextStyles.body(
                size: 12,
                color: AppColors.warmRedOrange,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // --- body ----------------------------------------------------------------

  Widget _buildBody() {
    if (_loadingCatalog)
      return _message(FontAwesomeIcons.spinner, 'Loading Analytics...');
    if (_catalogError != null) {
      return _message(
        FontAwesomeIcons.triangleExclamation,
        _catalogError!,
        isError: true,
      );
    }
    if (_running) {
      return _message(
        FontAwesomeIcons.spinner,
        _progress ?? 'Loading Analytics...',
      );
    }
    if (_narrowMessage != null) {
      return _message(
        FontAwesomeIcons.filter,
        _narrowMessage!,
        key: const Key('narrowMessage'),
      );
    }
    if (_runError != null) {
      return _message(
        FontAwesomeIcons.triangleExclamation,
        _runError!,
        isError: true,
      );
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();

    if (result.selectedBatches.isEmpty) {
      return _message(
        FontAwesomeIcons.boxOpen,
        'No batches match the selected filters.',
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (result.incompleteBatches.isNotEmpty) ...[
            _incompleteWarning(result),
            const SizedBox(height: 16),
          ],
          if (!result.hasData)
            _message(
              FontAwesomeIcons.triangleExclamation,
              'No complete batch data is available for Analytics.',
              height: 160,
              key: const Key('noCompleteData'),
            )
          else if (result.allActiveAttemptsArchived)
            _message(
              FontAwesomeIcons.boxArchive,
              'All examination attempts in this batch are archived. '
              'No active attempts to analyze.',
              height: 160,
              key: const Key('allAttemptsArchived'),
            )
          else ...[
            Text(
              'Analyzing ${result.analyzedBatches.length} batch'
              '${result.analyzedBatches.length == 1 ? '' : 'es'}',
              style: AppTextStyles.body(size: 13, color: AppColors.textGray),
            ),
            const SizedBox(height: 10),
            ..._sectionsFor(result),
          ],
        ],
      ),
    );
  }

  Widget _incompleteWarning(AnalyticsResult result) {
    return Container(
      key: const Key('incompleteBatchWarning'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF59E0B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '⚠ Some batches could not be fully retrieved and are excluded from these statistics.',
            style: AppTextStyles.body(size: 13, weight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final b in result.incompleteBatches)
            Text(
              '${b.batch.batchCode}: expected ${_int(b.expectedScans)} scans, '
              'retrieved ${_int(b.retrievedScans)}',
              style: AppTextStyles.body(size: 11),
            ),
        ],
      ),
    );
  }

  List<Widget> _sectionsFor(AnalyticsResult r) {
    final distributions = switch (r.examCode) {
      'AT' => _atSections(r.at!),
      'QTM' => _qtmSections(r.qtm!),
      _ => _tatSections(r.tatOverall!),
    };
    return [...distributions, const SizedBox(height: 16), _topScorers(r)];
  }

  Widget _topScorers(AnalyticsResult result) {
    final scorers = result.topScorers;
    final exam = result.examCode == 'AT' ? 'Admission Test' : result.examCode;
    return _card(
      child: Column(
        key: const Key('analytics.topScorers'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Top Scorers — $exam', style: AppTextStyles.heading(size: 15)),
          const SizedBox(height: 8),
          const Text(
            'Competition ranks 1–10, including all ties. Each examinee appears once with their highest eligible score in the selected batches.',
            style: TextStyle(fontSize: 13, color: AppColors.textGray),
          ),
          const SizedBox(height: 16),
          if (scorers.isEmpty)
            const Text('No scored examinees available.')
          else ...[
            const Row(
              children: [
                SizedBox(
                  width: 68,
                  child: Text(
                    'Rank',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Expanded(
                  child: Text(
                    'Examinee',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    'Score',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            for (final scorer in scorers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  key: ValueKey('topScorer.${scorer.result.examinee.id}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 68,
                      child: Text(
                        'Top ${scorer.rank}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            scorer.result.examinee.displayName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            scorer.result.examinee.officialStudentId ??
                                scorer.result.examinee.temporaryExamineeId,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textGray,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${scorer.result.score}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  // --- AT ------------------------------------------------------------------

  List<Widget> _atSections(AtBatchAnalytics a) {
    return [
      _overall(
        title: 'Overall Statistics',
        total: a.totalExaminees,
        graded: a.gradedExaminees,
        ungraded: a.ungradedExaminees,
        average: _scorePct(a.averageRawScore, a.averagePercentage),
        highest: _scorePct(a.highestRawScore?.toDouble(), a.highestPercentage),
        lowest: _scorePct(a.lowestRawScore?.toDouble(), a.lowestPercentage),
        median: _scorePct(a.medianRawScore, a.medianPercentage),
        excluded: a.excludedGradedCount,
      ),
      const SizedBox(height: 16),
      _distribution('Score Distribution'),
      const SizedBox(height: 16),
      _distribution('Category Distribution'),
    ];
  }

  // --- QTM -----------------------------------------------------------------

  List<Widget> _qtmSections(QtmBatchAnalytics q) {
    String? pctOf(int? raw) {
      final p = raw == null ? null : qtmPercentage(raw);
      return p == null ? null : '${p.toStringAsFixed(1)}%';
    }

    return [
      _overall(
        title: 'Overall Statistics',
        total: q.totalExaminees,
        graded: q.gradedExaminees,
        ungraded: q.ungradedExaminees,
        average: _combine(
          q.averageRawScore,
          q.averagePercentage == null
              ? null
              : '${q.averagePercentage!.toStringAsFixed(1)}%',
        ),
        highest: _combine(
          q.highestRawScore?.toDouble(),
          pctOf(q.highestRawScore),
        ),
        lowest: _combine(q.lowestRawScore?.toDouble(), pctOf(q.lowestRawScore)),
        median: _combine(
          q.medianRawScore,
          q.medianRawScore == null
              ? null
              : '${(q.medianRawScore! * 100 / 60).toStringAsFixed(1)}%',
        ),
      ),
      const SizedBox(height: 16),
      _distribution('Score Distribution'),
      const SizedBox(height: 16),
      _distribution('Eligibility Distribution'),
    ];
  }

  // --- TAT -----------------------------------------------------------------

  List<Widget> _tatSections(TatOverallStats o) {
    String? pct(double? p) => p == null ? null : '${p.toStringAsFixed(1)}%';
    return [
      _overall(
        title: 'Overall Statistics (recorded scores)',
        total: o.totalExaminees,
        graded: o.gradedExaminees,
        ungraded: o.ungradedExaminees,
        average: _combine(o.averageTotal, pct(o.averagePercentage)),
        highest: _combine(o.highestTotal?.toDouble(), pct(o.highestPercentage)),
        lowest: _combine(o.lowestTotal?.toDouble(), pct(o.lowestPercentage)),
        median: _combine(o.medianTotal, pct(o.medianPercentage)),
        excluded: o.excludedGradedCount,
      ),
      const SizedBox(height: 16),
      _distribution('Score Distribution'),
      const SizedBox(height: 16),
      _distribution('Eligibility Distribution'),
    ];
  }

  // --- shared pieces ---------------------------------------------------------

  Widget _overall({
    required String title,
    required int total,
    required int graded,
    required int ungraded,
    required String average,
    required String highest,
    required String lowest,
    required String median,
    int excluded = 0,
  }) {
    Widget tile(String label, String value) => SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppTextStyles.body(
              size: 12,
              weight: FontWeight.w700,
              color: AppColors.textGray,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppTextStyles.body(size: 13, weight: FontWeight.w700),
          ),
        ],
      ),
    );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.heading(size: 15)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 14,
            children: [
              tile('TOTAL', '$total'),
              tile('GRADED', '$graded'),
              tile('UNGRADED', '$ungraded'),
              tile('AVERAGE', average),
              tile('HIGHEST', highest),
              tile('LOWEST', lowest),
              tile('MEDIAN', median),
            ],
          ),
          if (excluded > 0) ...[
            const SizedBox(height: 10),
            Text(
              '$excluded graded scan${excluded == 1 ? '' : 's'} excluded from the score statistics (score outside the valid range).',
              style: AppTextStyles.body(size: 12, color: AppColors.textGray),
            ),
          ],
        ],
      ),
    );
  }

  void _showDistribution(AnalyticsDistributionGroup group) {
    final exam = examTypeDisplayLabel(_result!.examCode);
    final examinees = group.byExaminee.values.toList()
      ..sort(
        (a, b) => a.first.examinee.displayName.compareTo(
          b.first.examinee.displayName,
        ),
      );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFFF1F5FB),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF14243D),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            'Examinees — ${group.label}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        content: SizedBox(
          width: 680,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: group.results.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No examinees found in this range.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${group.results.length} matching result${group.results.length == 1 ? '' : 's'} · ${examinees.length} examinee${examinees.length == 1 ? '' : 's'}',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Each examinee appears once. Multiple matching results are listed together.',
                      ),
                      const SizedBox(height: 12),
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: examinees.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final matches = examinees[index];
                            final person = matches.first.examinee;
                            return Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: index.isEven
                                    ? const Color(0xFFE2EBF7)
                                    : const Color(0xFFE6F2EC),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFFCFDAE8),
                                ),
                              ),
                              child: Column(
                                key: ValueKey(
                                  'distribution.examinee.${person.id}',
                                ),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    person.displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                      color: Color(0xFF14243D),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'ID: ${person.officialStudentId ?? person.temporaryExamineeId}',
                                  ),
                                  Text('Exam: $exam'),
                                  for (final match in matches)
                                    Text(
                                      'Score: ${match.score} · Batch: ${match.batchCode}',
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _distribution(String title) {
    final groups = _result!.distributionGroups(title);
    const barColors = [
      Color(0xFF3B82F6),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFF8B5CF6),
      Color(0xFFEC4899),
      Color(0xFF06B6D4),
      Color(0xFFEF4444),
    ];
    // Every row's count and action share the same resolved result membership.
    final max = groups.fold<int>(
      0,
      (m, g) => g.results.length > m ? g.results.length : m,
    );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTextStyles.heading(
              size: 18,
              color: const Color(0xFF14243D),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Number of results · Bars scaled to the largest group',
            style: AppTextStyles.caption(),
          ),
          const SizedBox(height: 12),
          for (final group in groups)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 560;
                  final barColor =
                      barColors[groups.indexOf(group) % barColors.length];
                  final label = Text(
                    group.label,
                    style: AppTextStyles.body(
                      size: 13,
                      weight: FontWeight.w600,
                    ),
                  );
                  final bar = Semantics(
                    label: '${group.label}: ${group.results.length} results',
                    child: Container(
                      height: 22,
                      decoration: BoxDecoration(
                        color: const Color(0xFFDDE6F1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: max == 0
                              ? 0
                              : group.results.length / max,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  barColor,
                                  Color.lerp(
                                    barColor,
                                    const Color(0xFF14243D),
                                    0.2,
                                  )!,
                                ],
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  final action = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${group.results.length}',
                          textAlign: TextAlign.right,
                          style: AppTextStyles.body(
                            size: 13,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        key: ValueKey(
                          'distribution.search.$title.${group.label}',
                        ),
                        tooltip: 'View examinees — ${group.label}',
                        onPressed: () => _showDistribution(group),
                        icon: const Icon(Icons.search, size: 20),
                      ),
                    ],
                  );
                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        label,
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(child: bar),
                            const SizedBox(width: 12),
                            action,
                          ],
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      SizedBox(width: constraints.maxWidth * .28, child: label),
                      const SizedBox(width: 16),
                      Expanded(child: bar),
                      const SizedBox(width: 12),
                      action,
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  String _scorePct(double? score, double? pct) =>
      _combine(score, pct == null ? null : '${pct.toStringAsFixed(1)}%');

  String _combine(double? score, String? pct) {
    if (score == null) return '—';
    final s = score == score.roundToDouble()
        ? score.toStringAsFixed(0)
        : score.toStringAsFixed(1);
    return pct == null ? s : '$s ($pct)';
  }

  String _int(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );

  Widget _message(
    FaIconData icon,
    String message, {
    bool isError = false,
    double? height,
    Key? key,
  }) {
    if (isError)
      return ErrorState(
        message: message,
        onRetry: _catalogError != null ? _loadCatalog : _run,
      );
    if (icon == FontAwesomeIcons.spinner) return LoadingState(message: message);
    final color = isError ? AppColors.warmRedOrange : AppColors.textGray;
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FaIcon(icon, size: 34, color: color),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            message,
            key: key,
            textAlign: TextAlign.center,
            style: AppTextStyles.body(size: 13, color: color),
          ),
        ),
      ],
    );
    return height == null
        ? Center(child: content)
        : SizedBox(
            height: height,
            child: Center(child: content),
          );
  }
}

/// Analytics page: a Batch Analytics tab (the original page, unchanged) and
/// an Examinee Analytics tab for per-examinee cluster analysis.
class GuidanceWebAnalyticsView extends StatefulWidget {
  const GuidanceWebAnalyticsView({
    super.key,
    GuidanceWebAnalyticsService? service,
  }) : _service = service;

  final GuidanceWebAnalyticsService? _service;

  @override
  State<GuidanceWebAnalyticsView> createState() =>
      _GuidanceWebAnalyticsViewState();
}

class _GuidanceWebAnalyticsViewState extends State<GuidanceWebAnalyticsView> {
  bool _examineeTab = false;

  Widget _tab(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.emerald100 : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: AppTextStyles.body(
            size: 12,
            weight: FontWeight.w700,
            color: selected ? AppColors.primaryGreen : AppColors.textDark,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpace.gutterFor(MediaQuery.sizeOf(context).width),
            16,
            AppSpace.gutterFor(MediaQuery.sizeOf(context).width),
            0,
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _tab(
                'Batch Analytics',
                !_examineeTab,
                () => setState(() => _examineeTab = false),
              ),
              _tab(
                'Examinee Analytics',
                _examineeTab,
                () => setState(() => _examineeTab = true),
              ),
            ],
          ),
        ),
        Expanded(
          child: _examineeTab
              ? Padding(
                  padding: EdgeInsets.all(
                    AppSpace.gutterFor(MediaQuery.sizeOf(context).width),
                  ),
                  child: GuidanceWebExamineeAnalyticsView(),
                )
              : GuidanceWebBatchAnalyticsView(service: widget._service),
        ),
      ],
    );
  }
}
