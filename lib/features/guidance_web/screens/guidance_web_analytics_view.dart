import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/analytics/at_batch_analytics.dart';
import '../../../core/analytics/qtm_batch_analytics.dart';
import '../../../core/analytics/tat_batch_analytics.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/admission_category.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../core/omr/tat_result.dart';
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
  const GuidanceWebBatchAnalyticsView({super.key, GuidanceWebAnalyticsService? service})
      : _service = service;

  final GuidanceWebAnalyticsService? _service;

  @override
  State<GuidanceWebBatchAnalyticsView> createState() => _GuidanceWebBatchAnalyticsViewState();
}

const List<(String, String)> _examTypes = [
  ('AT', 'Admission Test (AT)'),
  ('QTM', 'Quantitative Math Test (QTM)'),
  ('TAT', 'Teaching Aptitude Test (TAT)'),
];

class _GuidanceWebBatchAnalyticsViewState extends State<GuidanceWebBatchAnalyticsView> {
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
    if (_status != AnalyticsBatchStatus.all && !catalog.archiveFilterAvailable) return const [];
    return catalog.batchesFor(examCode: _examCode, status: _status);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
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

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: child,
      );

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
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
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButtonFormField<AnalyticsBatchStatus>(
                  key: const Key('batchStatusFilter'),
                  value: _status,
                  isExpanded: true,
                  decoration: _decoration('Batch Status'),
                  items: [
                    const DropdownMenuItem(value: AnalyticsBatchStatus.all, child: Text('All')),
                    DropdownMenuItem(
                      value: AnalyticsBatchStatus.current,
                      enabled: archiveOk,
                      child: Text('Current', style: archiveOk ? null : const TextStyle(color: Colors.grey)),
                    ),
                    DropdownMenuItem(
                      value: AnalyticsBatchStatus.archived,
                      enabled: archiveOk,
                      child: Text('Archived', style: archiveOk ? null : const TextStyle(color: Colors.grey)),
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
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<LocalBatch?>(
                  key: const Key('batchFilter'),
                  value: _batch,
                  isExpanded: true,
                  decoration: _decoration('Batch'),
                  items: [
                    const DropdownMenuItem<LocalBatch?>(value: null, child: Text('All Batches')),
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
              const SizedBox(width: 12),
              IconButton(
                key: const Key('analyticsRefresh'),
                tooltip: 'Refresh',
                onPressed: _loadingCatalog || _running ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (catalog != null && !archiveOk) ...[
            const SizedBox(height: 10),
            Text(
              'Archive filtering is temporarily unavailable, so only "All" can be used right now.',
              key: const Key('archiveUnavailableNotice'),
              style: AppTextStyles.body(size: 10.5, color: AppColors.warmRedOrange),
            ),
          ],
        ],
      ),
    );
  }

  // --- body ----------------------------------------------------------------

  Widget _buildBody() {
    if (_loadingCatalog) return _message(FontAwesomeIcons.spinner, 'Loading Analytics...');
    if (_catalogError != null) {
      return _message(FontAwesomeIcons.triangleExclamation, _catalogError!, isError: true);
    }
    if (_running) {
      return _message(FontAwesomeIcons.spinner, _progress ?? 'Loading Analytics...');
    }
    if (_narrowMessage != null) {
      return _message(FontAwesomeIcons.filter, _narrowMessage!, key: const Key('narrowMessage'));
    }
    if (_runError != null) {
      return _message(FontAwesomeIcons.triangleExclamation, _runError!, isError: true);
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();

    if (result.selectedBatches.isEmpty) {
      return _message(FontAwesomeIcons.boxOpen, 'No batches match the selected filters.');
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
              style: AppTextStyles.body(size: 11, color: AppColors.textGray),
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
            style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
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
    switch (r.examCode) {
      case 'AT':
        return _atSections(r.at!);
      case 'QTM':
        return _qtmSections(r.qtm!);
      default:
        return _tatSections(r.tatOverall!, r.tatDetail!);
    }
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
      _distribution(
        'Score Distribution',
        [for (final e in a.scoreDistribution.entries) ('${e.key.categoryName} (${e.key.label})', e.value)],
      ),
      const SizedBox(height: 16),
      _distribution('Category Distribution', [
        for (final c in AdmissionCategory.values) (c.name.toUpperCase(), a.categoryDistribution[c] ?? 0),
        ('Unclassified (55–57)', a.unclassifiedCount),
      ]),
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
        average: _combine(q.averageRawScore, q.averagePercentage == null ? null : '${q.averagePercentage!.toStringAsFixed(1)}%'),
        highest: _combine(q.highestRawScore?.toDouble(), pctOf(q.highestRawScore)),
        lowest: _combine(q.lowestRawScore?.toDouble(), pctOf(q.lowestRawScore)),
        median: _combine(q.medianRawScore, q.medianRawScore == null ? null : '${(q.medianRawScore! * 100 / 60).toStringAsFixed(1)}%'),
      ),
      const SizedBox(height: 16),
      _distribution(
        'Score Distribution',
        [for (final e in q.scoreDistribution.entries) (e.key.label, e.value)],
      ),
      const SizedBox(height: 16),
      _distribution('Eligibility Distribution', [
        for (final e in QtmEligibility.values)
          (
            switch (e) {
              QtmEligibility.allCoursesIncludingBscs => 'Qualifies for all courses, including BSCS (18+)',
              QtmEligibility.allCoursesExceptBscs => 'Qualifies for all courses except BSCS (15–17)',
              QtmEligibility.notEligible => 'Does not qualify (below 15)',
            },
            q.eligibilityDistribution[e] ?? 0,
          ),
      ]),
    ];
  }

  // --- TAT -----------------------------------------------------------------

  List<Widget> _tatSections(TatOverallStats o, TatDetail d) {
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
      _distribution(
        'Score Distribution',
        [for (final e in o.totalScoreDistribution.entries) (e.key.label, e.value)],
      ),
      const SizedBox(height: 16),
      _distribution('Eligibility Distribution', [
        for (final e in TatEligibility.values)
          (
            switch (e) {
              TatEligibility.meetsRequirement => 'Meets requirement (48 or above)',
              TatEligibility.doesNotMeetRequirement => 'Does not meet requirement (47 or below)',
            },
            o.eligibilityDistribution[e] ?? 0,
          ),
      ]),
      const SizedBox(height: 16),
      _tatDetail(d),
    ];
  }

  Widget _tatDetail(TatDetail d) {
    final children = <Widget>[
      Text('Detailed TAT Analysis', style: AppTextStyles.heading(size: 13)),
      const SizedBox(height: 10),
    ];

    final info = d.keyInfo;
    if (info != null) {
      children.addAll([
        Text('TAT Answer Key', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Version: ${info.version ?? '—'}', key: const Key('keyVersion'), style: AppTextStyles.body(size: 11)),
        Text('Updated: ${_date(info.updatedAt)}', key: const Key('keyUpdated'), style: AppTextStyles.body(size: 11)),
        Text('Updated by: ${(info.updatedByName == null || info.updatedByName!.isEmpty) ? '—' : info.updatedByName}',
            key: const Key('keyUpdatedBy'), style: AppTextStyles.body(size: 11)),
        const SizedBox(height: 12),
      ]);
    }

    switch (d.status) {
      case TatDetailStatus.keyMissing:
        children.add(_unavailable('⚠ Unavailable — Answer Key is not available.'));
      case TatDetailStatus.keyIncomplete:
        children.add(_unavailable('⚠ Unavailable — Answer Key appears incomplete.'));
      case TatDetailStatus.keyUnavailable:
        children.add(_unavailable('⚠ Unavailable — the Answer Key could not be loaded.'));
      case TatDetailStatus.available:
        final a = d.analytics!;
        if (d.drifts.isNotEmpty) children..add(_driftWarning(d.drifts))..add(const SizedBox(height: 12));
        children.add(Text(
          'Per-test breakdown uses the current Answer Key (${a.analyzableExaminees} scans).',
          style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
        ));
        children.add(const SizedBox(height: 8));
        for (final (label, s, dist) in [
          ('Test 1', a.test1, a.test1Distribution),
          ('Test 2', a.test2, a.test2Distribution),
          ('Test 3', a.test3, a.test3Distribution),
        ]) {
          children.add(_testSummary(label, s, dist));
        }
        children.add(const SizedBox(height: 8));
        children.add(Text(
          'Strongest test: ${_testName(a.strongestTestByPercent)}     '
          'Weakest test: ${_testName(a.weakestTestByPercent)}',
          key: const Key('strongestWeakest'),
          style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
        ));
    }

    return _card(
      child: Column(
        key: const Key('tatDetailSection'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _unavailable(String text) => Container(
        key: const Key('tatDetailUnavailable'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w600)),
      );

  Widget _driftWarning(List<TatKeyDrift> drifts) {
    return Container(
      key: const Key('tatDriftWarning'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF59E0B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '⚠ Current Answer Key recalculation differs from the recorded score '
            '(${drifts.length} scan${drifts.length == 1 ? '' : 's'}). '
            'The recorded score remains authoritative.',
            style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final d in drifts.take(5))
            Text(
              '${d.batchCode} · scan ${d.scanId} — Recorded total: ${d.recordedTotal} · '
              'Current-key total: ${d.currentKeyTotal}',
              style: AppTextStyles.body(size: 10.5),
            ),
          if (drifts.length > 5)
            Text('…and ${drifts.length - 5} more', style: AppTextStyles.body(size: 10.5, color: AppColors.textGray)),
        ],
      ),
    );
  }

  Widget _testSummary(String label, TatTestSummary s, Map<TatTestQuartile, int> dist) {
    String f(num? n) => n == null ? '—' : (n is int ? '$n' : n.toStringAsFixed(1));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label (max ${s.maxPossible}): average ${f(s.average)} · highest ${f(s.highest)} · '
            'lowest ${f(s.lowest)} · median ${f(s.median)}'
            '${s.averagePercentOfMax == null ? '' : ' · ${s.averagePercentOfMax!.toStringAsFixed(1)}% of max'}',
            style: AppTextStyles.body(size: 11),
          ),
          if (dist.isNotEmpty)
            Text(
              [for (final e in dist.entries) '${e.key.label}: ${e.value}'].join('   '),
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
        ],
      ),
    );
  }

  String _testName(TatTestKey? k) => switch (k) {
        TatTestKey.test1 => 'Test 1',
        TatTestKey.test2 => 'Test 2',
        TatTestKey.test3 => 'Test 3',
        null => '—',
      };

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
              Text(label, style: AppTextStyles.body(size: 10, weight: FontWeight.w700, color: AppColors.textGray)),
              const SizedBox(height: 4),
              Text(value, style: AppTextStyles.body(size: 13, weight: FontWeight.w700)),
            ],
          ),
        );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.heading(size: 13)),
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
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
          ],
        ],
      ),
    );
  }

  Widget _distribution(String title, List<(String, int)> rows) {
    final max = rows.fold<int>(0, (m, r) => r.$2 > m ? r.$2 : m);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.heading(size: 13)),
          const SizedBox(height: 10),
          for (final (label, count) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(width: 300, child: Text(label, style: AppTextStyles.body(size: 11))),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : count / max,
                      minHeight: 8,
                      backgroundColor: AppColors.lightBg,
                      color: AppColors.primaryGreen,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 48,
                    child: Text('$count', textAlign: TextAlign.right, style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
                  ),
                ],
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
    final s = score == score.roundToDouble() ? score.toStringAsFixed(0) : score.toStringAsFixed(1);
    return pct == null ? s : '$s ($pct)';
  }

  String _int(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
    'September', 'October', 'November', 'December',
  ];

  String _date(DateTime? d) {
    if (d == null) return '—';
    final l = d.toLocal();
    return '${_months[l.month - 1]} ${l.day}, ${l.year}';
  }

  Widget _message(FaIconData icon, String message, {bool isError = false, double? height, Key? key}) {
    final color = isError ? AppColors.warmRedOrange : AppColors.textGray;
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FaIcon(icon, size: 34, color: color),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(message, key: key, textAlign: TextAlign.center, style: AppTextStyles.body(size: 11.5, color: color)),
        ),
      ],
    );
    return height == null ? Center(child: content) : SizedBox(height: height, child: Center(child: content));
  }
}

/// Analytics page: a Batch Analytics tab (the original page, unchanged) and
/// an Examinee Analytics tab for per-examinee cluster analysis.
class GuidanceWebAnalyticsView extends StatefulWidget {
  const GuidanceWebAnalyticsView({super.key, GuidanceWebAnalyticsService? service})
    : _service = service;

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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Row(
            children: [
              _tab(
                'Batch Analytics',
                !_examineeTab,
                () => setState(() => _examineeTab = false),
              ),
              const SizedBox(width: 8),
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
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: GuidanceWebExamineeAnalyticsView(),
                )
              : GuidanceWebBatchAnalyticsView(service: widget._service),
        ),
      ],
    );
  }
}
