import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/omr/admission_category.dart';
import '../../../core/omr/cluster_analysis.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/qtm_category.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../core/omr/tat_category.dart';
import '../../../models/answer_key.dart';
import '../../../models/local_batch.dart';
import '../services/guidance_web_analytics_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_certificate.dart';
import 'guidance_web_export_models.dart';
import 'guidance_web_export_pdf.dart';

const Map<String, String> _examLabels = {
  'AT': 'Admission Test (AT)',
  'QTM': 'Quantitative Math Test (QTM)',
  'TAT': 'Teaching Aptitude Test (TAT)',
};

/// Category bands as printed, D first. Same score ranges the Analytics
/// detail screen shows; QTM and TAT carry the template's percentage labels.
List<ExportCategoryBand> exportCategoryBands(String examCode) =>
    switch (examCode) {
      'QTM' => const [
        ExportCategoryBand('D', '54 - 60', '90% and above'),
        ExportCategoryBand('C', '51 - 53', '85% - 89%'),
        ExportCategoryBand('B', '48 - 50', '80% - 84%'),
        ExportCategoryBand('A', '0 - 45', '76% and below'),
      ],
      'TAT' => const [
        ExportCategoryBand('D', '144 - 160', '90% and above'),
        ExportCategoryBand('C', '136 - 143', '85% - 89%'),
        ExportCategoryBand('B', '128 - 135', '80% - 84%'),
        ExportCategoryBand('A', '0 - 121', '76% and below'),
      ],
      _ => const [
        ExportCategoryBand('D', '65 - 72'),
        ExportCategoryBand('C', '61 - 64'),
        ExportCategoryBand('B', '58 - 60'),
        ExportCategoryBand('A', '0 - 54'),
      ],
    };

/// The category letter for a recorded [raw] score, or null when the score is
/// unclassified or out of range.
String? exportCategoryLetter(String examCode, int raw) => switch (examCode) {
  'QTM' => qtmCategory(raw)?.name.toUpperCase(),
  'TAT' => tatCategory(raw)?.name.toUpperCase(),
  _ => admissionCategory(raw)?.name.toUpperCase(),
};

/// Turns a batch and a selection into the export PDF. READ-ONLY: it reads
/// the answer key, the batch statistics and the scans already loaded, and
/// writes nothing anywhere.
class GuidanceWebExportService {
  GuidanceWebExportService({
    GuidanceWebAnalyticsService? analytics,
    GuidanceWebResultsService? results,
  }) : _analyticsOverride = analytics,
       _resultsOverride = results;

  final GuidanceWebAnalyticsService? _analyticsOverride;
  final GuidanceWebResultsService? _resultsOverride;
  late final GuidanceWebAnalyticsService _analytics =
      _analyticsOverride ?? GuidanceWebAnalyticsService();
  late final GuidanceWebResultsService _results =
      _resultsOverride ?? GuidanceWebResultsService();

  /// Builds the PDF: the Batch Analytics page when [includeSummary], then one
  /// Examinee Analytics page per scan in [selected] (in the given order).
  /// [allScans] is every scan of [batch] — the batch averages and the
  /// category distribution are computed over all of them, never only the
  /// selected ones.
  Future<Uint8List> buildPdf({
    required LocalBatch batch,
    required bool includeSummary,
    required List<LocalScan> selected,
    required List<LocalScan> allScans,
    bool includeCertificates = false,
  }) async {
    AnswerKey? key;
    try {
      key = await _results.loadAnswerKey(batch.examCode);
    } catch (_) {
      key = null; // unrated clusters, "-" instead of numbers
    }

    final section = includeSummary
        ? await _batchSection(batch, allScans)
        : null;
    // Every examinee uses the same whole-batch baseline for this export.
    final averages = selected.isNotEmpty && key != null && clusterDefsFor(batch.examCode) != null
        ? computeClusterAverages(batch.examCode, [
            for (final scan in allScans) scoreOmrResult(scan.decoded, key).items,
          ])
        : const <String, double>{};
    final examinees = [
      for (final s in selected)
        _examineeSection(batch, s, averages, key, includeCertificates),
    ];

    final left = (await rootBundle.load('assets/images/ndmu_logo.png'))
        .buffer
        .asUint8List();
    final right =
        (await rootBundle.load('assets/images/guidance_council_logo.png'))
            .buffer
            .asUint8List();
    return buildExportPdf(
      ExportDocument(batch: section, examinees: examinees),
      leftLogo: left,
      rightLogo: right,
    );
  }

  /// The whole-batch export used by the list's `export`: the batch analytics
  /// plus a page for every examinee (tagged or not) in the batch.
  Future<Uint8List> buildDefaultPdf(
    LocalBatch batch, {
    bool includeCertificates = false,
  }) async {
    final scans = await _results.loadScansForBatch(batch);
    return buildPdf(
      batch: batch,
      includeSummary: true,
      selected: scans,
      allScans: scans,
      includeCertificates: includeCertificates,
    );
  }

  // --- batch page ------------------------------------------------------------

  String _batchLabel(LocalBatch b) {
    final title = b.examTitle.isNotEmpty ? b.examTitle : b.examCode;
    return '${b.batchCode} - $title';
  }

  Future<ExportBatchSection> _batchSection(
    LocalBatch batch,
    List<LocalScan> allScans,
  ) async {
    final examLabel = _examLabels[batch.examCode] ?? batch.examCode;
    final categoryBars = _categoryBars(batch.examCode, allScans);

    try {
      final catalog = await _analytics.loadCatalog();
      final r = await _analytics.analyze(
        catalog: catalog,
        examCode: batch.examCode,
        status: AnalyticsBatchStatus.all,
        batch: batch,
      );
      if (!r.hasData) {
        return ExportBatchSection(
          examLabel: examLabel,
          batchLabel: _batchLabel(batch),
          batchDate: _date(batch.createdAt),
          stats: const [],
          scoreBars: const [],
          categoryBars: categoryBars,
          unavailableNote:
              'Statistics unavailable: this batch could not be fully retrieved.',
        );
      }
      final (stats, bars) = _statsFrom(r);
      return ExportBatchSection(
        examLabel: examLabel,
        batchLabel: _batchLabel(batch),
        batchDate: _date(batch.createdAt),
        stats: stats,
        scoreBars: bars,
        categoryBars: categoryBars,
      );
    } catch (_) {
      return ExportBatchSection(
        examLabel: examLabel,
        batchLabel: _batchLabel(batch),
        batchDate: _date(batch.createdAt),
        stats: const [],
        scoreBars: const [],
        categoryBars: categoryBars,
        unavailableNote: 'Statistics unavailable: could not load batch data.',
      );
    }
  }

  static String _combine(double? score, String? pct) {
    if (score == null) return '-';
    final s = score == score.roundToDouble()
        ? score.toStringAsFixed(0)
        : score.toStringAsFixed(1);
    return pct == null ? s : '$s ($pct)';
  }

  static String? _pct(double? p) => p == null ? null : '${p.toStringAsFixed(1)}%';

  /// The same figures and formatting the Analytics screen shows.
  (List<(String, String)>, List<ExportBar>) _statsFrom(AnalyticsResult r) {
    switch (r.examCode) {
      case 'AT':
        final a = r.at!;
        return (
          [
            ('Total', '${a.totalExaminees}'),
            ('Graded', '${a.gradedExaminees}'),
            ('Ungraded', '${a.ungradedExaminees}'),
            ('Average', _combine(a.averageRawScore, _pct(a.averagePercentage))),
            (
              'Highest',
              _combine(a.highestRawScore?.toDouble(), _pct(a.highestPercentage)),
            ),
            (
              'Lowest',
              _combine(a.lowestRawScore?.toDouble(), _pct(a.lowestPercentage)),
            ),
            ('Median', _combine(a.medianRawScore, _pct(a.medianPercentage))),
          ],
          [
            for (final e in a.scoreDistribution.entries)
              ExportBar('${e.key.categoryName} (${e.key.label})', e.value),
          ],
        );
      case 'QTM':
        final q = r.qtm!;
        String? pctOf(int? raw) {
          final p = raw == null ? null : qtmPercentage(raw);
          return _pct(p);
        }

        return (
          [
            ('Total', '${q.totalExaminees}'),
            ('Graded', '${q.gradedExaminees}'),
            ('Ungraded', '${q.ungradedExaminees}'),
            ('Average', _combine(q.averageRawScore, _pct(q.averagePercentage))),
            (
              'Highest',
              _combine(q.highestRawScore?.toDouble(), pctOf(q.highestRawScore)),
            ),
            (
              'Lowest',
              _combine(q.lowestRawScore?.toDouble(), pctOf(q.lowestRawScore)),
            ),
            (
              'Median',
              _combine(
                q.medianRawScore,
                q.medianRawScore == null
                    ? null
                    : _pct(q.medianRawScore! * 100 / 60),
              ),
            ),
          ],
          [
            for (final e in q.scoreDistribution.entries)
              ExportBar(e.key.label, e.value),
          ],
        );
      default:
        final o = r.tatOverall!;
        return (
          [
            ('Total', '${o.totalExaminees}'),
            ('Graded', '${o.gradedExaminees}'),
            ('Ungraded', '${o.ungradedExaminees}'),
            ('Average', _combine(o.averageTotal, _pct(o.averagePercentage))),
            (
              'Highest',
              _combine(o.highestTotal?.toDouble(), _pct(o.highestPercentage)),
            ),
            (
              'Lowest',
              _combine(o.lowestTotal?.toDouble(), _pct(o.lowestPercentage)),
            ),
            ('Median', _combine(o.medianTotal, _pct(o.medianPercentage))),
          ],
          [
            for (final e in o.totalScoreDistribution.entries)
              ExportBar(e.key.label, e.value),
          ],
        );
    }
  }

  /// Category Distribution: graded scans counted by their recorded score's
  /// letter (A first), plus the unclassified gap.
  List<ExportBar> _categoryBars(String examCode, List<LocalScan> scans) {
    final counts = <String, int>{'A': 0, 'B': 0, 'C': 0, 'D': 0};
    var unclassified = 0;
    for (final s in scans) {
      final result = s.result;
      if (result == null || result.status != 'Graded') continue;
      final letter = exportCategoryLetter(examCode, result.rawScore);
      if (letter == null) {
        unclassified++;
      } else {
        counts[letter] = (counts[letter] ?? 0) + 1;
      }
    }
    return [
      for (final l in ['A', 'B', 'C', 'D']) ExportBar(l, counts[l]!),
      ExportBar('Unclassified', unclassified),
    ];
  }

  // --- examinee page ---------------------------------------------------------

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
    'September', 'October', 'November', 'December',
  ];

  String _date(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

  ExportExamineeSection _examineeSection(
    LocalBatch batch,
    LocalScan scan,
    Map<String, double> averages,
    AnswerKey? key,
    bool includeCertificates,
  ) {
    final e = scan.examinee;
    final result = scan.result;
    final denominator = batch.examCode == 'TAT'
        ? 160
        : (result?.totalItems ?? 0);

    List<ClusterRow>? clusterRows;
    if (clusterDefsFor(batch.examCode) != null) {
      clusterRows = computeClusterRows(
        batch.examCode,
        scoreOmrResult(scan.decoded, key).items,
        averages: averages,
      );
    }

    String dash(String? v) => (v == null || v.trim().isEmpty) ? '-' : v.trim();
    final examDate = ExamineeInfo.examDateFor(
      scanCapturedAt: scan.capturedAt,
      batchCreatedAt: batch.createdAt,
    );
    final age = e?.ageOn(examDate);

    return ExportExamineeSection(
      examLabel: _examLabels[batch.examCode] ?? batch.examCode,
      batchLabel: _batchLabel(batch),
      examineeId: dash(e?.examineeNumber),
      firstName: dash(e?.firstName),
      middleName: dash(e?.middleName),
      lastName: dash(e?.lastName),
      age: age == null ? '-' : '$age',
      scanDate: _date(scan.capturedAt),
      score: result == null ? '-' : '${result.rawScore} / $denominator',
      percentage: result == null
          ? '-'
          : '${result.percentage.toStringAsFixed(2)}%',
      clusterRows: clusterRows,
      categoryBands: exportCategoryBands(batch.examCode),
      categoryLetter: result == null
          ? null
          : exportCategoryLetter(batch.examCode, result.rawScore),
      // Printed right after this examinee's analytics page.
      certificate: includeCertificates
          ? buildCertificate(
              examCode: batch.examCode,
              rawScore: result?.rawScore,
              status: result?.status,
              name: e?.displayName,
            )
          : null,
    );
  }
}
