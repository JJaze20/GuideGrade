import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/analytics/tat_batch_analytics.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/tat_result.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';

/// Read-only descriptive analytics for one archived **TAT** batch.
///
/// PRESENTATION ONLY. Every number shown here comes from
/// [TatBatchAnalytics.fromBatch]; this screen performs no averaging /
/// median / ranking / percentage / distribution / eligibility calculation
/// of its own, and never reads `LocalBatch.averagePercentage`,
/// `LocalScanResult.percentage`, or the legacy `rawScore`. It receives
/// only the batch id and loads the [LocalBatch] itself via
/// `batchRepository.getBatchById`. The official TAT percentage and the
/// `48 / 160` (30%) eligibility rule live in `tat_result.dart` and are
/// applied inside [TatBatchAnalytics], not here.
class TatBatchAnalyticsScreen extends StatefulWidget {
  const TatBatchAnalyticsScreen({super.key, required this.batchId});

  final String batchId;

  @override
  State<TatBatchAnalyticsScreen> createState() =>
      _TatBatchAnalyticsScreenState();
}

class _TatBatchAnalyticsScreenState extends State<TatBatchAnalyticsScreen> {
  bool _didInit = false;
  bool _loading = true;
  LocalBatch? _batch;
  TatBatchAnalytics? _analytics;
  bool _notTat = false;

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
    TatBatchAnalytics? analytics;
    var notTat = false;
    if (batch != null) {
      try {
        analytics = TatBatchAnalytics.fromBatch(batch);
      } on ArgumentError {
        notTat = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _batch = batch;
      _analytics = analytics;
      _notTat = notTat;
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
        title: Text('TAT Analytics', style: AppTextStyles.heading(size: 13)),
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
    if (_notTat || _analytics == null) {
      return _centeredMessage('This batch is not a TAT batch.');
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
            key: const Key('tatAnalytics.excludedWarning'),
          ),
        ],
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.chartLine, 'Overall Performance'),
        const SizedBox(height: 8),
        _overallPerformance(a),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.listOl, 'Test Performance'),
        const SizedBox(height: 8),
        _testPerformance(a),
        const SizedBox(height: 16),
        _sectionTitle(FontAwesomeIcons.circleCheck, 'Eligibility'),
        const SizedBox(height: 8),
        _eligibility(a),
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
  /// the batch archive detail screen.
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
            _kv('Exam Type', 'Teaching Aptitude Test (TAT)'),
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

  Widget _overview(TatBatchAnalytics a) => Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _statCard('Total Examinees', '${a.totalExaminees}',
                    cardKey: const Key('tatAnalytics.totalExaminees')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard('Graded', '${a.gradedExaminees}',
                    cardKey: const Key('tatAnalytics.gradedExaminees')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard('Ungraded', '${a.ungradedExaminees}',
                    cardKey: const Key('tatAnalytics.ungradedExaminees')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _statCard('Analyzable', '${a.analyzableExaminees}',
                    cardKey: const Key('tatAnalytics.analyzableExaminees')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard('Excluded', '${a.excludedGradedCount}',
                    cardKey: const Key('tatAnalytics.excludedGradedCount')),
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

  String _excludedMessage(TatBatchAnalytics a) {
    final n = a.excludedGradedCount;
    final k = a.analyzableExaminees;
    final sheetWas = n == 1 ? 'sheet was' : 'sheets were';
    final itDoes = n == 1 ? 'it does' : 'they do';
    return '$n graded $sheetWas excluded from TAT analytics because $itDoes '
        'not contain a valid, complete TAT breakdown. The figures below '
        'reflect only the $k sheet(s) with valid TAT data.';
  }

  // --- overall performance -----------------------------------------

  Widget _overallPerformance(TatBatchAnalytics a) => _card(
        child: Column(
          children: [
            _metricRow('Average Score', _scoreOf160(a.averageTatTotal),
                rowKey: const Key('tatAnalytics.averageScore')),
            _metricRow('Highest Score', _intOf160(a.highestTatTotal),
                rowKey: const Key('tatAnalytics.highestScore')),
            _metricRow('Lowest Score', _intOf160(a.lowestTatTotal),
                rowKey: const Key('tatAnalytics.lowestScore')),
            _metricRow('Median Score', _scoreOf160(a.medianTatTotal),
                rowKey: const Key('tatAnalytics.medianScore')),
            const Divider(height: 14, color: AppColors.cardBorder),
            _metricRow(
                'Average Percentage', _pct(a.averageTatPercentage),
                rowKey: const Key('tatAnalytics.averagePercentage')),
            _metricRow(
                'Highest Percentage', _pct(a.highestTatPercentage),
                rowKey: const Key('tatAnalytics.highestPercentage')),
            _metricRow(
                'Lowest Percentage', _pct(a.lowestTatPercentage),
                rowKey: const Key('tatAnalytics.lowestPercentage')),
            _metricRow(
                'Median Percentage', _pct(a.medianTatPercentage),
                rowKey: const Key('tatAnalytics.medianPercentage')),
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

  static String _n1(double? v) => v == null ? '—' : v.toStringAsFixed(1);
  static String _pct(double? v) =>
      v == null ? '—' : '${v.toStringAsFixed(2)}%';
  static String _scoreOf160(double? v) =>
      v == null ? '—' : '${v.toStringAsFixed(1)} / 160';
  static String _intOf160(int? v) => v == null ? '—' : '$v / 160';

  // --- test performance ------------------------------------------

  Widget _testPerformance(TatBatchAnalytics a) => Column(
        children: [
          _testCard('tatAnalytics.test1', 'Test 1', a.test1),
          const SizedBox(height: 8),
          _testCard('tatAnalytics.test2', 'Test 2', a.test2),
          const SizedBox(height: 8),
          _testCard('tatAnalytics.test3', 'Test 3', a.test3),
          const SizedBox(height: 8),
          _card(
            child: Column(
              children: [
                _metricRow(
                    'Strongest Test', _testKeyLabel(a.strongestTestByPercent),
                    rowKey: const Key('tatAnalytics.strongestTest')),
                _metricRow(
                    'Weakest Test', _testKeyLabel(a.weakestTestByPercent),
                    rowKey: const Key('tatAnalytics.weakestTest')),
              ],
            ),
          ),
        ],
      );

  Widget _testCard(String prefix, String title, TatTestSummary s) => _card(
        key: Key(prefix),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: AppTextStyles.heading(size: 12)),
                const Spacer(),
                Text(
                  'Score / ${s.maxPossible}',
                  style: AppTextStyles.body(
                      size: 9.5,
                      color: AppColors.textGray,
                      weight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _metricRow('Average', _n1(s.average),
                rowKey: Key('$prefix.average')),
            _metricRow('Highest', s.highest?.toString() ?? '—',
                rowKey: Key('$prefix.highest')),
            _metricRow('Lowest', s.lowest?.toString() ?? '—',
                rowKey: Key('$prefix.lowest')),
            _metricRow('Median', _n1(s.median), rowKey: Key('$prefix.median')),
            _metricRow(
                'Average % of maximum', _pct(s.averagePercentOfMax),
                rowKey: Key('$prefix.percentOfMax')),
          ],
        ),
      );

  static String _testKeyLabel(TatTestKey? k) => switch (k) {
        TatTestKey.test1 => 'Test 1',
        TatTestKey.test2 => 'Test 2',
        TatTestKey.test3 => 'Test 3',
        null => '—',
      };

  // --- eligibility --------------------------------------------------

  Widget _eligibility(TatBatchAnalytics a) {
    final rateRow = _metricRow(
      'Meets Requirement Rate',
      _pct(a.meetsRequirementRate),
      rowKey: const Key('tatAnalytics.meetsRequirementRate'),
    );

    if (a.eligibilityDistribution.isEmpty) {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _emptyLine(
              'No analyzable TAT results yet — eligibility appears once sheets '
              'with a valid TAT breakdown are graded.',
              key: const Key('tatAnalytics.eligibilityDistribution.empty'),
            ),
            const SizedBox(height: 8),
            rateRow,
            const SizedBox(height: 4),
            _eligibilityCaption(),
          ],
        ),
      );
    }

    final counts = {
      for (final band in TatEligibility.values)
        band: a.eligibilityDistribution[band] ?? 0,
    };
    final maxCount = counts.values.fold<int>(0, (m, c) => c > m ? c : m);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final band in TatEligibility.values)
            _eligRow(
              band,
              counts[band]!,
              maxCount,
              rowKey: Key('tatAnalytics.eligibility.${band.name}'),
            ),
          const Divider(height: 14, color: AppColors.cardBorder),
          rateRow,
          const SizedBox(height: 4),
          _eligibilityCaption(),
        ],
      ),
    );
  }

  Widget _eligibilityCaption() => Text(
        'A combined score of 48 / 160 (30%) or higher meets the TAT '
        'requirement; below 48 does not.',
        style: AppTextStyles.body(size: 8.5, color: AppColors.textGray),
      );

  Widget _eligRow(TatEligibility band, int count, int maxCount, {Key? rowKey}) {
    final color = _tatEligibilityColor(band);
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
                  _tatEligibilityLabel(band),
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

  // --- score distribution ----------------------------------------

  Widget _scoreDistribution(TatBatchAnalytics a) {
    if (a.totalScoreDistribution.isEmpty) {
      return _card(
        child: _emptyLine(
          'No analyzable TAT results yet — the score distribution appears once '
          'sheets with a valid TAT breakdown are graded.',
          key: const Key('tatAnalytics.scoreDistribution.empty'),
        ),
      );
    }
    final counts = {
      for (final band in TatTotalBand.values)
        band: a.totalScoreDistribution[band] ?? 0,
    };
    final maxCount = counts.values.fold<int>(0, (m, c) => c > m ? c : m);
    return _card(
      child: Column(
        children: [
          for (final band in TatTotalBand.values)
            _bar(
              band.label,
              counts[band]!,
              maxCount,
              AppColors.primaryGreen,
              barKey: Key('tatAnalytics.scoreBand.${band.name}'),
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
            width: 56,
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

  // --- top scorers ------------------------------------------------

  Widget _topScorers(TatBatchAnalytics a) {
    final scorers = a.topScorers(limit: 5);
    if (scorers.isEmpty) {
      return _card(
        child: _emptyLine(
          'No analyzable TAT results yet — top scorers appear once sheets with '
          'a valid TAT breakdown are graded.',
          key: const Key('tatAnalytics.topScorers.empty'),
        ),
      );
    }
    return _card(
      child: Column(
        children: [
          for (var i = 0; i < scorers.length; i++) ...[
            if (i > 0)
              const Divider(height: 12, color: AppColors.cardBorder),
            _scorerRow(scorers[i], i),
          ],
        ],
      ),
    );
  }

  Widget _scorerRow(TatRankedScorer scorer, int index) {
    final name = scorer.displayName ?? 'Unnamed';
    final number = scorer.examineeNumber ?? '—';
    final pct = scorer.percentage == null
        ? '—'
        : '${scorer.percentage!.toStringAsFixed(2)}%';
    final eligibility = scorer.eligibility;
    return Padding(
      key: Key('tatAnalytics.topScorer.$index'),
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
                if (eligibility != null)
                  Text(
                    _tatEligibilityLabel(eligibility),
                    style: AppTextStyles.body(
                      size: 8.5,
                      color: _tatEligibilityColor(eligibility),
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
                '${scorer.tatTotal} / 160',
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

/// The established TAT eligibility label for one outcome. Kept here as
/// constant strings (not calculation); the 30% / `48 / 160` rule itself
/// lives in `tat_result.dart` and is applied by [TatBatchAnalytics].
String _tatEligibilityLabel(TatEligibility band) => switch (band) {
      TatEligibility.meetsRequirement => 'Meets TAT Requirement',
      TatEligibility.doesNotMeetRequirement => 'Does Not Meet TAT Requirement',
    };

/// The established TAT eligibility colour for one outcome (`AppColors`
/// tokens — green for meets, red for does-not-meet).
Color _tatEligibilityColor(TatEligibility band) => switch (band) {
      TatEligibility.meetsRequirement => AppColors.catC,
      TatEligibility.doesNotMeetRequirement => AppColors.catA,
    };
