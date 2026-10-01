import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import '../../../core/constants/exam_catalog.dart';
import '../../../core/omr/admission_category.dart';
import '../../../core/omr/cluster_analysis.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/qtm_category.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../core/omr/tat_category.dart';
import '../../../models/answer_key.dart';
import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart';
import '../services/guidance_web_analytics_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_certificate.dart';
import 'guidance_web_export_models.dart';
import 'guidance_web_export_pdf.dart';

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

  /// Builds the [ExportDocument] (Batch Analytics section + one Examinee
  /// Analytics section per scan in [selected]) WITHOUT rendering it to PDF
  /// bytes or loading any asset -- the exact same content [buildPdf] would
  /// print, just stopped one step earlier so a test can inspect the plain
  /// [ExportBatchSection]/[ExportExamineeSection] data instead of parsing
  /// PDF bytes. [allScans] is every scan of [batch] -- the batch averages
  /// and the category distribution are computed over all of them, never
  /// only the selected ones.
  ///
  /// [linkedExamineeByScanId] supplies the OFFICIAL identity (Examinee ID/
  /// name) for a scan -- the same map [GuidanceWebResultsService.
  /// loadResultsForBatch] returns. This is the authoritative official-result
  /// eligibility gate, enforced HERE regardless of what [selected] the
  /// caller passed in: a scan in [selected] with no entry in
  /// [linkedExamineeByScanId] (`examinee_id` was null, or didn't resolve to
  /// a real `examinees` row -- a dangling link) produces NO examinee page at
  /// all. There is no OCR/staff-tag fallback for an unresolved scan -- see
  /// [_examineeSection]'s own doc comment -- so a stale or hand-built
  /// selection that still includes an unlinked/dangling scan can never make
  /// it into the output just by being passed in; the caller does not need
  /// to pre-filter [selected] itself for this to hold.
  @visibleForTesting
  Future<ExportDocument> buildExportDocument({
    required LocalBatch batch,
    required bool includeSummary,
    required List<LocalScan> selected,
    required List<LocalScan> allScans,
    bool includeCertificates = false,
    Map<String, ExamineeRecord> linkedExamineeByScanId = const {},
  }) async {
    AnswerKey? key;
    try {
      key = await _results.loadAnswerKey(batch.examCode);
    } catch (_) {
      key = null; // unrated clusters, "-" instead of numbers
    }

    // Official-result eligibility: only a scan whose examinee_id resolved
    // to a real examinees row produces an examinee page -- enforced here,
    // not left to the caller, so this can't be bypassed by passing an
    // unlinked/dangling scan in `selected`.
    final eligible = [
      for (final s in selected)
        if (linkedExamineeByScanId.containsKey(s.id)) s,
    ];

    final section = includeSummary
        ? await _batchSection(batch, allScans)
        : null;
    // Every examinee uses the same whole-batch baseline for this export.
    final averages = eligible.isNotEmpty && key != null && clusterDefsFor(batch.examCode) != null
        ? computeClusterAverages(batch.examCode, [
            for (final scan in allScans) scoreOmrResult(scan.decoded, key).items,
          ])
        : const <String, double>{};
    final examinees = [
      for (final s in eligible)
        _examineeSection(
          batch,
          s,
          averages,
          key,
          includeCertificates,
          linkedExamineeByScanId[s.id]!,
        ),
    ];
    return ExportDocument(batch: section, examinees: examinees);
  }

  /// Builds the PDF: [buildExportDocument] rendered to bytes via
  /// [buildExportPdf], with the two logo assets loaded.
  Future<Uint8List> buildPdf({
    required LocalBatch batch,
    required bool includeSummary,
    required List<LocalScan> selected,
    required List<LocalScan> allScans,
    bool includeCertificates = false,
    Map<String, ExamineeRecord> linkedExamineeByScanId = const {},
  }) async {
    final document = await buildExportDocument(
      batch: batch,
      includeSummary: includeSummary,
      selected: selected,
      allScans: allScans,
      includeCertificates: includeCertificates,
      linkedExamineeByScanId: linkedExamineeByScanId,
    );

    final left = (await rootBundle.load('assets/images/ndmu_logo.png'))
        .buffer
        .asUint8List();
    final right =
        (await rootBundle.load('assets/images/guidance_council_logo.png'))
            .buffer
            .asUint8List();
    return buildExportPdf(document, leftLogo: left, rightLogo: right);
  }

  /// The whole-batch [ExportDocument] used by [buildDefaultPdf]: the
  /// official-result set only -- a scan whose `examinee_id` resolves to a
  /// real `examinees` row (its own default exclusion of an archived retake
  /// attempt applies here unchanged -- this never passes
  /// `includeArchivedAttempts: true`). Used as both the batch summary's
  /// scope and the per-examinee pages, with the resolved official
  /// [ExamineeRecord] for each one -- never the scan's own OCR/staff-tagged
  /// [LocalScan.examinee] -- so an unlinked scan or a dangling `examinee_id`
  /// never appears anywhere in this export.
  ///
  /// [GuidanceWebResultsService.loadResultsForBatch] itself now returns
  /// EVERY scan in the batch (Results shows unlinked scans too), with
  /// [WebBatchResults.linkedExamineeByScanId] as the one signal for which
  /// are officially linked. [buildExportDocument] independently re-enforces
  /// this same eligibility for the examinee pages it builds (so that
  /// enforcement cannot be bypassed by any caller), but [allScans] here
  /// still MUST be pre-filtered: [_batchSection]'s category-distribution
  /// bars read straight from [allScans] with no filtering of their own, so
  /// passing the full (unlinked-inclusive) scan list here would leak
  /// unlinked scans back into that count even though the examinee pages
  /// themselves stay correctly official-only.
  @visibleForTesting
  Future<ExportDocument> buildDefaultExportDocument(
    LocalBatch batch, {
    bool includeCertificates = false,
  }) async {
    final results = await _results.loadResultsForBatch(batch);
    final officialScans = results.scans
        .where((s) => results.linkedExamineeByScanId.containsKey(s.id))
        .toList();
    return buildExportDocument(
      batch: batch,
      includeSummary: true,
      selected: officialScans,
      allScans: officialScans,
      includeCertificates: includeCertificates,
      linkedExamineeByScanId: results.linkedExamineeByScanId,
    );
  }

  /// The whole-batch export used by the list's `export`: the batch analytics
  /// plus a page for every official result in the batch (see
  /// [buildDefaultExportDocument]).
  Future<Uint8List> buildDefaultPdf(
    LocalBatch batch, {
    bool includeCertificates = false,
  }) async {
    final document = await buildDefaultExportDocument(
      batch,
      includeCertificates: includeCertificates,
    );

    final left = (await rootBundle.load('assets/images/ndmu_logo.png'))
        .buffer
        .asUint8List();
    final right =
        (await rootBundle.load('assets/images/guidance_council_logo.png'))
            .buffer
            .asUint8List();
    return buildExportPdf(document, leftLogo: left, rightLogo: right);
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
    final examLabel = examTypeDisplayLabel(batch.examCode);
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
      // Applicant Retake Management (additive): the batch is physically
      // complete, but every scan in it is an archived retake attempt --
      // there is nothing active to summarize. Stated plainly instead of
      // printing an all-zero Batch Analytics page, which would read as a
      // real (if unusually poor) result rather than "nothing active here".
      if (r.allActiveAttemptsArchived) {
        return ExportBatchSection(
          examLabel: examLabel,
          batchLabel: _batchLabel(batch),
          batchDate: _date(batch.createdAt),
          stats: const [],
          scoreBars: const [],
          categoryBars: categoryBars,
          unavailableNote: 'All examination attempts in this batch are '
              'archived. No active attempts are included in this export.',
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

  /// [linked] is the resolved official [ExamineeRecord] for [scan] --
  /// REQUIRED, never nullable. [buildExportDocument] only ever calls this
  /// for a scan that already has a resolved entry in its own
  /// `linkedExamineeByScanId`; a scan with no entry (null or dangling
  /// `examinee_id`) is filtered out before reaching this method at all, so
  /// there is no OCR/staff-tag fallback path here to accidentally take --
  /// official Examinee ID/name/certificate name come from [linked] alone.
  ExportExamineeSection _examineeSection(
    LocalBatch batch,
    LocalScan scan,
    Map<String, double> averages,
    AnswerKey? key,
    bool includeCertificates,
    ExamineeRecord linked,
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
    // Age has no established official-record input source yet (see
    // ExamineeRecord's own class doc comment) -- kept from the OCR/staff tag.
    // This is demographic data, not identity, and is unaffected by the
    // official-identity rule: the examinee ID/name/certificate name below
    // never do this.
    final age = e?.ageOn(examDate);

    return ExportExamineeSection(
      examLabel: examTypeDisplayLabel(batch.examCode),
      batchLabel: _batchLabel(batch),
      examineeId: dash(linked.temporaryExamineeId),
      firstName: dash(linked.firstName),
      middleName: dash(linked.middleName),
      lastName: dash(linked.lastName),
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
              name: linked.displayName,
            )
          : null,
    );
  }
}
