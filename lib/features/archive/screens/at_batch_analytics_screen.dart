import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/analytics/at_batch_analytics.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/admission_category.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';

/// Read-only descriptive analytics for one archived **Admission Test (AT)**
/// batch.
///
/// PRESENTATION ONLY. Every number shown here comes from
/// [AtBatchAnalytics.fromBatch]; this screen performs no averaging /
/// median / ranking / percentage / distribution calculation of its own,
/// and never reads `LocalBatch.averagePercentage` or
/// `LocalScanResult.percentage`. It receives only the batch id and loads
/// the [LocalBatch] itself via `batchRepository.getBatchById`. The
/// official `rawScore / 72 * 100` percentage and the A / Unclassified /
/// B / C / D bands live in `at_batch_analytics.dart` /
/// `admission_category.dart` and are applied there, not here.
class AtBatchAnalyticsScreen extends StatefulWidget {
  const AtBatchAnalyticsScreen({super.key, required this.batchId});

  final String batchId;

  @override
  State<AtBatchAnalyticsScreen> createState() => _AtBatchAnalyticsScreenState();
}

class _AtBatchAnalyticsScreenState extends State<AtBatchAnalyticsScreen> {
  bool _didInit = false;
  bool _loading = true;
  LocalBatch? _batch;
  AtBatchAnalytics? _analytics;
  bool _notAt = false;

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
    AtBatchAnalytics? analytics;
    var notAt = false;
    if (batch != null) {
      try {
        analytics = AtBatchAnalytics.fromBatch(batch);
      } on ArgumentError {
        notAt = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _batch = batch;
      _analytics = analytics;
      _notAt = notAt;
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
        title:
            Text('Admission Analytics', style: AppTextStyles.heading(size: 13)),
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
    if (_notAt || _analytics == null) {
      return _centeredMessage('This batch is not an Admission Test batch.');
    }

    final batch = _batch!;
    final a = _analytics!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(batch),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.users, 'Overview'),
        const SizedBox(height: 8),
        _overview(a),
        if (a.excludedGradedCount > 0) ...[
          const SizedBox(height: 8),
          _amberNote(
            _excludedMessage(a),
            key: const Key('atAnalytics.excludedWarning'),
          ),
        ],
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.chartLine, 'Overall Performance'),
        const SizedBox(height: 8),
        _overallPerformance(a),
        const SizedBox(height: 16),
        _sectionTitle(
            FontAwesomeIcons.circleCheck, 'Admission Category Distribution'),
        const SizedBox(height: 8),
        _categoryDistribution(a),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.chartSimple, 'Score Distribution'),
        const SizedBox(height: 8),
        _scoreDistribution(a),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.trophy, 'Top Scorers'),
        const SizedBox(height: 8),
        _topScorers(a),
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

  Widget _card({Key? key, required Widget child}) => Container(
        key: key,
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

  /// Amber advisory row, matching the warning-row treatment already used on
  /// the batch archive detail screen and the TAT analytics screen.
  Widget _amberNote(String message, {Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFCD34D)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FaIcon(FontAwesomeIcons.triangleExclamation,
                size: 11, color: Color(0xFF92400E)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: AppTextStyles.body(
                    size: 9.5,
                    color: const Color(0xFF92400E),
                    weight: FontWeight.w600),
              ),
            ),
          ],
        ),
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
            _kv('Exam Type', 'Admission Test (AT)'),
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

  Widget _overview(AtBatchAnalytics a) => Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _statCard('Total Examinees', '${a.totalExaminees}',
                    cardKey: const Key('atAnalytics.totalExaminees')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard('Graded', '${a.gradedExaminees}',
                    cardKey: const Key('atAnalytics.gradedExaminees')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard('Ungraded', '${a.ungradedExaminees}',
                    cardKey: const Key('atAnalytics.ungradedExaminees')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _statCard('Analyzable', '${a.analyzableExaminees}',
                    cardKey: const Key('atAnalytics.analyzableExaminees')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard(
                    'Excluded Graded', '${a.excludedGradedCount}',
                    cardKey: const Key('atAnalytics.excludedGradedCount')),
              ),
            ],
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

  String _excludedMessage(AtBatchAnalytics a) {
    final n = a.excludedGradedCount;
    final sheets = n == 1 ? 'sheet is' : 'sheets are';
    return '$n graded $sheets excluded from these statistics because the '
        'answer key did not cover the full 72 items.';
  }

  // --- overall performance ----------------------------------------

  Widget _overallPerformance(AtBatchAnalytics a) => _card(
        child: Column(
          children: [
            _metricRow('Average Score', _scoreOf72(a.averageRawScore),
                rowKey: const Key('atAnalytics.averageScore')),
            _metricRow('Highest Score', _intOf72(a.highestRawScore),
                rowKey: const Key('atAnalytics.highestScore')),
            _metricRow('Lowest Score', _intOf72(a.lowestRawScore),
                rowKey: const Key('atAnalytics.lowestScore')),
            _metricRow('Median Score', _scoreOf72(a.medianRawScore),
                rowKey: const Key('atAnalytics.medianScore')),
            const Divider(height: 14, color: AppColors.cardBorder),
            _metricRow('Average Percentage', _pct(a.averagePercentage),
                rowKey: const Key('atAnalytics.averagePercentage')),
            _metricRow('Highest Percentage', _pct(a.highestPercentage),
                rowKey: const Key('atAnalytics.highestPercentage')),
            _metricRow('Lowest Percentage', _pct(a.lowestPercentage),
                rowKey: const Key('atAnalytics.lowestPercentage')),
            _metricRow('Median Percentage', _pct(a.medianPercentage),
                rowKey: const Key('atAnalytics.medianPercentage')),
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

  static String _scoreOf72(double? v) =>
      v == null ? '—' : '${v.toStringAsFixed(1)} / 72';
  static String _intOf72(int? v) => v == null ? '—' : '$v / 72';
  static String _pct(double? v) =>
      v == null ? '—' : '${v.toStringAsFixed(2)}%';
  static String _rate(double? v) =>
      v == null ? '—' : '${v.toStringAsFixed(1)}%';

  // --- admission category distribution ---------------------------

  Widget _categoryDistribution(AtBatchAnalytics a) {
    if (a.analyzableExaminees == 0) {
      return _card(
        child: _emptyLine(
          'No analyzable Admission Test results yet — the category '
          'distribution appears once fully-graded 72-item sheets exist.',
          key: const Key('atAnalytics.categoryDistribution.empty'),
        ),
      );
    }
    final aCount = a.categoryCount(AdmissionCategory.a);
    final uCount = a.unclassifiedCount;
    final bCount = a.categoryCount(AdmissionCategory.b);
    final cCount = a.categoryCount(AdmissionCategory.c);
    final dCount = a.categoryCount(AdmissionCategory.d);
    final maxCount = [aCount, uCount, bCount, cCount, dCount]
        .fold<int>(0, (m, c) => c > m ? c : m);
    return _card(
      child: Column(
        children: [
          _catRow('A', aCount, a.categoryRate(AdmissionCategory.a), maxCount,
              AppColors.catA,
              rowKey: const Key('atAnalytics.category.a')),
          _catRow('Unclassified', uCount, a.unclassifiedRate, maxCount,
              AppColors.catCutoff,
              rowKey: const Key('atAnalytics.category.unclassified')),
          _catRow('B', bCount, a.categoryRate(AdmissionCategory.b), maxCount,
              AppColors.catB,
              rowKey: const Key('atAnalytics.category.b')),
          _catRow('C', cCount, a.categoryRate(AdmissionCategory.c), maxCount,
              AppColors.catC,
              rowKey: const Key('atAnalytics.category.c')),
          _catRow('D', dCount, a.categoryRate(AdmissionCategory.d), maxCount,
              AppColors.catD,
              rowKey: const Key('atAnalytics.category.d')),
        ],
      ),
    );
  }

  Widget _catRow(
    String label,
    int count,
    double? rate,
    int maxCount,
    Color color, {
    required Key rowKey,
  }) {
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
                  label,
                  style:
                      AppTextStyles.body(size: 9.5, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _rate(rate),
                style: AppTextStyles.body(
                    size: 9,
                    color: AppColors.textGray,
                    weight: FontWeight.w600),
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

  // --- score distribution (official category-aligned bands) -----

  Widget _scoreDistribution(AtBatchAnalytics a) {
    if (a.scoreDistribution.isEmpty) {
      return _card(
        child: _emptyLine(
          'No analyzable Admission Test results yet — the score distribution '
          'appears once fully-graded 72-item sheets exist.',
          key: const Key('atAnalytics.scoreDistribution.empty'),
        ),
      );
    }
    final counts = {
      for (final band in AtScoreBand.values)
        band: a.scoreDistribution[band] ?? 0,
    };
    final maxCount = counts.values.fold<int>(0, (m, c) => c > m ? c : m);
    return _card(
      child: Column(
        children: [
          for (final band in AtScoreBand.values)
            _distBar(
              '${band.categoryName} · ${band.label}',
              counts[band]!,
              maxCount,
              barKey: Key('atAnalytics.scoreBand.${band.name}'),
            ),
        ],
      ),
    );
  }

  Widget _distBar(String label, int count, int maxCount, {required Key barKey}) {
    final fraction = maxCount == 0 ? 0.0 : count / maxCount;
    return Padding(
      key: barKey,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.body(
                      size: 9.5,
                      color: AppColors.textGray,
                      weight: FontWeight.w700),
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
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppColors.lightBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                Container(
                  height: 12,
                  width: constraints.maxWidth * fraction,
                  decoration: BoxDecoration(
                    color: AppColors.primaryGreen,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- top scorers ---------------------------------------------

  Widget _topScorers(AtBatchAnalytics a) {
    final scorers = a.topScorers(limit: 5);
    if (scorers.isEmpty) {
      return _card(
        child: _emptyLine(
          'No analyzable Admission Test results yet — top scorers appear '
          'once fully-graded 72-item sheets exist.',
          key: const Key('atAnalytics.topScorers.empty'),
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

  Widget _scorerRow(AtRankedScorer scorer) {
    final name = scorer.displayName ?? 'Unnamed examinee';
    final number = scorer.examineeNumber ?? '—';
    final pct = scorer.percentage == null
        ? '—'
        : '${scorer.percentage!.toStringAsFixed(2)}%';
    return Padding(
      key: Key('atAnalytics.topScorer.${scorer.scanId}'),
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
                  style:
                      AppTextStyles.body(size: 8.5, color: AppColors.textGray),
                ),
                Text(
                  _categoryLabel(scorer.category),
                  style: AppTextStyles.body(
                    size: 8.5,
                    color: _categoryColor(scorer.category),
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
                '${scorer.rawScore} / 72',
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

  /// The AT Analytics screen's own label for a category. Uses
  /// **"Unclassified"** for the intentional 55–57 gap (`null`). This is
  /// deliberately separate from `ScanResultSummary`'s "Not classified"
  /// wording, which is left untouched.
  static String _categoryLabel(AdmissionCategory? c) => switch (c) {
        AdmissionCategory.a => 'A',
        AdmissionCategory.b => 'B',
        AdmissionCategory.c => 'C',
        AdmissionCategory.d => 'D',
        null => 'Unclassified',
      };

  static Color _categoryColor(AdmissionCategory? c) => switch (c) {
        AdmissionCategory.a => AppColors.catA,
        AdmissionCategory.b => AppColors.catB,
        AdmissionCategory.c => AppColors.catC,
        AdmissionCategory.d => AppColors.catD,
        null => AppColors.catCutoff,
      };
}
