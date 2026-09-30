import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/analytics/qtm_batch_analytics.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';

/// Read-only descriptive analytics for one archived **QTM** batch.
///
/// PRESENTATION ONLY. Every number shown here comes from
/// [QtmBatchAnalytics.fromBatch]; this screen performs no averaging /
/// median / ranking / percentage / distribution / eligibility calculation
/// of its own, and never reads `LocalBatch.averagePercentage` or
/// `LocalScanResult.percentage`. It receives only the batch id and loads
/// the [LocalBatch] itself via `batchRepository.getBatchById`.
class QtmBatchAnalyticsScreen extends StatefulWidget {
  const QtmBatchAnalyticsScreen({super.key, required this.batchId});

  final String batchId;

  @override
  State<QtmBatchAnalyticsScreen> createState() =>
      _QtmBatchAnalyticsScreenState();
}

class _QtmBatchAnalyticsScreenState extends State<QtmBatchAnalyticsScreen> {
  bool _didInit = false;
  bool _loading = true;
  LocalBatch? _batch;
  QtmBatchAnalytics? _analytics;
  bool _notQtm = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    _load();
  }

  Future<void> _load() async {
    final repo = AppStateScope.of(context).batchRepository;
    final batch = await repo.getBatchById(widget.batchId);
    QtmBatchAnalytics? analytics;
    var notQtm = false;
    if (batch != null) {
      try {
        analytics = QtmBatchAnalytics.fromBatch(batch);
      } on ArgumentError {
        notQtm = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _batch = batch;
      _analytics = analytics;
      _notQtm = notQtm;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('QTM Analytics', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_batch == null) {
      return _centeredMessage('Batch could not be found.');
    }
    if (_notQtm || _analytics == null) {
      return _centeredMessage('This batch is not a QTM batch.');
    }

    final batch = _batch!;
    final analytics = _analytics!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(batch),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.users, 'Overview'),
        const SizedBox(height: 8),
        _overview(analytics),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.chartLine, 'Performance'),
        const SizedBox(height: 8),
        _performance(analytics),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.chartSimple, 'Score Distribution'),
        const SizedBox(height: 8),
        _scoreDistribution(analytics),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.circleCheck, 'Eligibility'),
        const SizedBox(height: 8),
        _eligibilityDistribution(analytics),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.trophy, 'Top Scorers'),
        const SizedBox(height: 8),
        _topScorers(analytics),
        const SizedBox(height: 8),
      ],
    );
  }

  // --- shared bits ------------------------------------------------------

  Widget _centeredMessage(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.body(size: 11, color: AppColors.textGray),
          ),
        ),
      );

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: child,
      );

  Widget _sectionTitle(FaIconData icon, String title) => Row(
        children: [
          FaIcon(icon, size: 12, color: AppColors.primaryGreen),
          const SizedBox(width: 6),
          Text(title, style: AppTextStyles.heading(size: 12)),
        ],
      );

  Widget _emptyLine(String message, {Key? key}) => Text(
        message,
        key: key,
        style: AppTextStyles.body(size: 10, color: AppColors.textGray),
      );

  // --- header --------------------------------------------------------

  Widget _header(LocalBatch batch) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              batch.description.isNotEmpty
                  ? batch.description
                  : 'Batch ${batch.batchCode}',
              style: AppTextStyles.heading(size: 15),
            ),
            const SizedBox(height: 4),
            _kv('Batch Code', batch.batchCode),
            _kv('Exam Type', examTypeDisplayLabel('QTM')),
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                k,
                style: AppTextStyles.body(
                    size: 9.5,
                    color: AppColors.textGray,
                    weight: FontWeight.w700),
              ),
            ),
            Expanded(child: Text(v, style: AppTextStyles.body(size: 10))),
          ],
        ),
      );

  // --- overview -----------------------------------------------------

  Widget _overview(QtmBatchAnalytics a) => Row(
        children: [
          Expanded(
            child: _statCard('Total Examinees', '${a.totalExaminees}',
                cardKey: const Key('qtmAnalytics.totalExaminees')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _statCard('Graded', '${a.gradedExaminees}',
                cardKey: const Key('qtmAnalytics.gradedExaminees')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _statCard('Ungraded', '${a.ungradedExaminees}',
                cardKey: const Key('qtmAnalytics.ungradedExaminees')),
          ),
        ],
      );

  Widget _statCard(String label, String value, {Key? cardKey}) => Container(
        key: cardKey,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Column(
          children: [
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w800,
                color: AppColors.textGray,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                color: AppColors.darkNavy,
              ),
            ),
          ],
        ),
      );

  // --- performance ---------------------------------------------------

  Widget _performance(QtmBatchAnalytics a) => _card(
        child: Column(
          children: [
            _metricRow('Average Raw Score', _fmt1(a.averageRawScore),
                rowKey: const Key('qtmAnalytics.averageRawScore')),
            _metricRow(
                'Average Official Percentage', _fmtPct(a.averagePercentage),
                rowKey: const Key('qtmAnalytics.averagePercentage')),
            _metricRow('Highest Raw Score', a.highestRawScore?.toString() ?? '—',
                rowKey: const Key('qtmAnalytics.highestRawScore')),
            _metricRow('Lowest Raw Score', a.lowestRawScore?.toString() ?? '—',
                rowKey: const Key('qtmAnalytics.lowestRawScore')),
            _metricRow('Median Raw Score', _fmt1(a.medianRawScore),
                rowKey: const Key('qtmAnalytics.medianRawScore')),
          ],
        ),
      );

  Widget _metricRow(String label, String value, {Key? rowKey}) => Padding(
        key: rowKey,
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTextStyles.body(
                    size: 10,
                    color: AppColors.textGray,
                    weight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                color: AppColors.darkNavy,
              ),
            ),
          ],
        ),
      );

  static String _fmt1(double? v) => v == null ? '—' : v.toStringAsFixed(1);
  static String _fmtPct(double? v) => v == null ? '—' : '${v.toStringAsFixed(2)}%';

  // --- score distribution ----------------------------------------

  Widget _scoreDistribution(QtmBatchAnalytics a) {
    if (a.scoreDistribution.isEmpty) {
      return _card(
        child: _emptyLine(
          'No graded scans yet — the score distribution appears once sheets are graded.',
          key: const Key('qtmAnalytics.scoreDistribution.empty'),
        ),
      );
    }
    final counts = {
      for (final band in QtmScoreBand.values)
        band: a.scoreDistribution[band] ?? 0,
    };
    final maxCount = counts.values.fold<int>(0, (m, c) => c > m ? c : m);
    return _card(
      child: Column(
        children: [
          for (final band in QtmScoreBand.values)
            _bar(
              band.label,
              counts[band]!,
              maxCount,
              AppColors.primaryGreen,
              barKey: Key('qtmAnalytics.scoreBand.${band.name}'),
            ),
        ],
      ),
    );
  }

  Widget _bar(String label, int count, int maxCount, Color color,
      {Key? barKey}) {
    final fraction = maxCount == 0 ? 0.0 : count / maxCount;
    return Padding(
      key: barKey,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: AppTextStyles.body(
                  size: 9.5,
                  color: AppColors.textGray,
                  weight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: [
                  Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: AppColors.lightBg,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  Container(
                    height: 14,
                    width: constraints.maxWidth * fraction,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 22,
            child: Text(
              '$count',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                color: AppColors.darkNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- eligibility distribution --------------------------------

  Widget _eligibilityDistribution(QtmBatchAnalytics a) {
    if (a.eligibilityDistribution.isEmpty) {
      return _card(
        child: _emptyLine(
          'No graded scans yet — eligibility appears once sheets are graded.',
          key: const Key('qtmAnalytics.eligibilityDistribution.empty'),
        ),
      );
    }
    final counts = {
      for (final band in QtmEligibility.values)
        band: a.eligibilityDistribution[band] ?? 0,
    };
    final maxCount = counts.values.fold<int>(0, (m, c) => c > m ? c : m);
    return _card(
      child: Column(
        children: [
          for (final band in QtmEligibility.values)
            _eligRow(
              band,
              counts[band]!,
              maxCount,
              rowKey: Key('qtmAnalytics.eligibility.${band.name}'),
            ),
        ],
      ),
    );
  }

  Widget _eligRow(QtmEligibility band, int count, int maxCount, {Key? rowKey}) {
    final color = eligibilityColor(band);
    final fraction = maxCount == 0 ? 0.0 : count / maxCount;
    return Padding(
      key: rowKey,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  eligibilityLabel(band),
                  style: AppTextStyles.body(size: 9.5, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$count',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                  color: AppColors.darkNavy,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: AppColors.lightBg,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                Container(
                  height: 10,
                  width: constraints.maxWidth * fraction,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- top scorers ------------------------------------------------

  Widget _topScorers(QtmBatchAnalytics a) {
    final scorers = a.topScorers(limit: 5);
    if (scorers.isEmpty) {
      return _card(
        child: _emptyLine(
          'No graded examinees yet — top scorers appear once sheets are graded.',
          key: const Key('qtmAnalytics.topScorers.empty'),
        ),
      );
    }
    return _card(
      child: Column(
        children: [
          for (var i = 0; i < scorers.length; i++) ...[
            if (i > 0)
              const Divider(height: 12, color: AppColors.cardBorder),
            _scorerRow(scorers[i]),
          ],
        ],
      ),
    );
  }

  Widget _scorerRow(QtmRankedScorer scorer) {
    final name = scorer.displayName ?? 'Unnamed examinee';
    final number = scorer.examineeNumber ?? '—';
    final pct = scorer.percentage == null
        ? '—'
        : '${scorer.percentage!.toStringAsFixed(2)}%';
    final eligibility = scorer.eligibility;
    return Padding(
      key: Key('qtmAnalytics.topScorer.${scorer.rank}.${scorer.scanId}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '#${scorer.rank}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: AppColors.darkNavy,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body(size: 10, weight: FontWeight.w700),
                ),
                Text(
                  number,
                  style: AppTextStyles.body(size: 8.5, color: AppColors.textGray),
                ),
                if (eligibility != null)
                  Text(
                    eligibilityLabel(eligibility),
                    style: AppTextStyles.body(
                      size: 8.5,
                      color: eligibilityColor(eligibility),
                      weight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${scorer.rawScore} / 60',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                  color: AppColors.darkNavy,
                ),
              ),
              Text(
                pct,
                style: AppTextStyles.body(
                    size: 9,
                    color: AppColors.textGray,
                    weight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The established QTM eligibility label for one band. Kept here (not
/// imported from the private helpers in `ScanResultSummary`) so the
/// analytics screen stays self-contained; these are constant strings, not
/// calculation.
String eligibilityLabel(QtmEligibility band) => switch (band) {
      QtmEligibility.allCoursesIncludingBscs =>
        'All QTM-required courses, incl. BSCS',
      QtmEligibility.allCoursesExceptBscs =>
        'All QTM-required courses, except BSCS',
      QtmEligibility.notEligible => 'Does not meet the QTM requirement',
    };

/// The established QTM eligibility colour for one band (`AppColors` tokens).
Color eligibilityColor(QtmEligibility band) => switch (band) {
      QtmEligibility.allCoursesIncludingBscs => AppColors.catC,
      QtmEligibility.allCoursesExceptBscs => AppColors.catB,
      QtmEligibility.notEligible => AppColors.catA,
    };
