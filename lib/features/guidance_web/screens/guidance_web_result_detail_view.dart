import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/omr/admission_category.dart';
import '../../../core/omr/cluster_analysis.dart';
import '../../../core/omr/tat_cluster_analysis.dart';
import '../../../core/omr/exam_score.dart';
import '../../../core/omr/omr_mesh_correction.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/omr/qtm_category.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../core/omr/tat_category.dart';
import '../../../core/omr/tat_result.dart';
import '../../../models/answer_key.dart';
import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_cluster_radar.dart';

/// Which outcome an [ScoredItem] should be rendered as in the Answer
/// Details table — deliberately distinct from a plain correct/incorrect
/// boolean so an ambiguous mark is never mislabeled as a normal wrong
/// answer, and an item the current answer key doesn't cover is never
/// mislabeled as wrong either.
enum AnswerOutcome { correct, incorrect, ambiguous, notGraded }

/// Classifies one already-scored item ([ScoredItem] — produced by the
/// existing [scoreOmrResult], never recomputed here) into the outcome its
/// Answer Details row should show. Pure, no I/O.
///
///  * No [ScoredItem.correctChoice] at all (the current answer key doesn't
///    cover this item, or none exists) -> [AnswerOutcome.notGraded].
///  * [ScoredItem.isAmbiguous] -> [AnswerOutcome.ambiguous], regardless of
///    [ScoredItem.markedChoice] — matches the existing scoring model's own
///    distinction (an ambiguous double/stray mark is never "just wrong").
///  * Otherwise [ScoredItem.isCorrect] decides correct/incorrect — a blank
///    answer (`markedChoice == null`) falls into incorrect here, same as
///    every other non-matching mark.
@visibleForTesting
AnswerOutcome answerOutcomeFor(ScoredItem item) {
  if (item.correctChoice == null) return AnswerOutcome.notGraded;
  if (item.isAmbiguous) return AnswerOutcome.ambiguous;
  return item.isCorrect == true
      ? AnswerOutcome.correct
      : AnswerOutcome.incorrect;
}

/// Groups [items] by [ScoredItem.sectionName], preserving first-seen order
/// (AT/QTM naturally produce one section; TAT produces "Test I"/"Test
/// II"/"Test III" in that order) — mirrors the same grouping
/// `scanned_image_viewer_screen.dart`'s `_AnswerKeyPanel` already uses.
/// Pure, no I/O, no assumption about how many sections an exam has.
@visibleForTesting
Map<String, List<ScoredItem>> groupScoredItemsBySection(
  List<ScoredItem> items,
) {
  final bySection = <String, List<ScoredItem>>{};
  for (final item in items) {
    bySection.putIfAbsent(item.sectionName, () => []).add(item);
  }
  return bySection;
}

/// Which cloud image variant is currently loaded (or whether none is),
/// tracked so the OMR overlay is only ever attempted over the [rectified]
/// image — [BubblePos] fractions are page-flattened coordinates and would
/// misplace every ring/badge drawn over the [original], un-rectified photo
/// (see mobile's own `_GradedOverlayPainter` doc comment, which this Web
/// implementation mirrors).
enum ScanImageVariant { rectified, original, none }

/// The exact colors mobile's private `_GradedOverlayPainter`
/// (`scanned_image_viewer_screen.dart`) already uses — kept as two
/// separately-named constants for [ambiguous] and [key] even though they
/// share the same value, because they mean two different things: [key] is
/// the "here's the correct answer" ring shown on a wrong/blank item, while
/// [ambiguous] is specifically the badge color for a double/stray mark.
/// Collapsing them into one "yellow = ambiguous" concept would be wrong.
@visibleForTesting
abstract class WebOverlayColors {
  static const Color correct = Color(0xFF16A34A);
  static const Color wrong = Color(0xFFDC2626);
  static const Color ambiguous = Color(0xFFEAB308);
  static const Color key = Color(0xFFEAB308);
}

/// What to draw for one graded [ScoredItem] — the pure decision half of the
/// overlay (which bubble, which color), kept separate from the Canvas
/// drawing math so it's directly unit-testable without a painter/golden-image
/// harness. Returned by [planOverlayForItem]; consumed by
/// `_WebGradedOverlayPainter`.
@visibleForTesting
class ItemOverlayPlan {
  const ItemOverlayPlan({
    required this.markedBubble,
    required this.markedColor,
    required this.keyBubble,
    required this.badgeBubble,
    required this.badgeColor,
    required this.badgeIsCorrect,
  });

  /// The bubble the examinee actually marked, or null when nothing was
  /// confidently marked (blank, or an ambiguous mark with no resolvable
  /// choice).
  final BubblePos? markedBubble;

  /// Ring color for [markedBubble] — [WebOverlayColors.correct] or
  /// [WebOverlayColors.wrong]. Null exactly when [markedBubble] is null.
  final Color? markedColor;

  /// The correct-answer "key" ring bubble, always [WebOverlayColors.key] —
  /// drawn whenever the marked answer disagrees with it or nothing was
  /// marked at all. Null when the marked answer was already correct (no key
  /// ring is needed) or the correct choice isn't in the template.
  final BubblePos? keyBubble;

  /// Anchor bubble (the leftmost choice in the item's row) for the
  /// check/cross badge.
  final BubblePos badgeBubble;
  final Color badgeColor;
  final bool badgeIsCorrect;
}

/// Pure decision logic mirroring mobile's `_GradedOverlayPainter` byte for
/// byte (see that class's doc comment) — no Canvas, no I/O. Returns `null`
/// exactly when mobile would skip the item entirely:
///
///  * [ScoredItem.correctChoice] is null (ungraded — no answer key coverage);
///  * or [bubbles] has no entry for this item (the template doesn't cover
///    this section/item number).
///
/// Otherwise:
///  * a mark exists and is correct -> [ItemOverlayPlan.markedColor] is
///    [WebOverlayColors.correct], no key ring;
///  * a mark exists and is wrong -> `markedColor` is
///    [WebOverlayColors.wrong]; a [ItemOverlayPlan.keyBubble] is ALSO set
///    (yellow) when the correct choice resolves to a different bubble;
///  * no mark (blank) but the correct choice is known -> only the yellow
///    key ring, no marked ring;
///  * the badge is green/correct, red/wrong, or — specifically for
///    [ScoredItem.isAmbiguous] — yellow, regardless of the ring colors
///    above (an ambiguous item's RING is still red, matching mobile; only
///    its badge turns yellow).
@visibleForTesting
ItemOverlayPlan? planOverlayForItem(ScoredItem item, List<BubblePos>? bubbles) {
  if (item.correctChoice == null) return null;
  if (bubbles == null || bubbles.isEmpty) return null;

  BubblePos? find(String? choice) {
    if (choice == null) return null;
    for (final b in bubbles) {
      if (b.choice == choice) return b;
    }
    return null;
  }

  final marked = find(item.markedChoice);
  final correct = find(item.correctChoice);
  final isRight = item.isCorrect == true;

  BubblePos? keyBubble;
  if (marked != null) {
    if (!isRight && correct != null && correct.choice != marked.choice) {
      keyBubble = correct;
    }
  } else if (correct != null) {
    keyBubble = correct;
  }

  var leftmost = bubbles.first;
  for (final b in bubbles) {
    if (b.xFrac < leftmost.xFrac) leftmost = b;
  }
  final badgeColor = isRight
      ? WebOverlayColors.correct
      : (item.isAmbiguous
            ? WebOverlayColors.ambiguous
            : WebOverlayColors.wrong);

  return ItemOverlayPlan(
    markedBubble: marked,
    markedColor: marked == null
        ? null
        : (isRight ? WebOverlayColors.correct : WebOverlayColors.wrong),
    keyBubble: keyBubble,
    badgeBubble: leftmost,
    badgeColor: badgeColor,
    badgeIsCorrect: isRight,
  );
}

/// Maps one [BubblePos]'s template fraction to its actual on-canvas
/// [Offset], applying the SAME interior-fiducial mesh correction mobile's
/// `_GradedOverlayPainter` applies — a byte-for-byte port of that class's
/// `centerOf` (see `scanned_image_viewer_screen.dart`). Pure: no Canvas, no
/// I/O, so the coordinate math is directly testable without a painter or a
/// golden image.
///
/// [meshInteriorMeasuredFrac] is [OmrScanResult.meshInteriorMeasuredFrac] —
/// the exact same interior-fiducial readings [OmrDecoder.decode] used to
/// sample bubbles for this scan's [ScoredItem]s, persisted alongside them so
/// this overlay places its rings using the identical geometric mapping
/// scoring did, rather than assuming the displayed rectified image is an
/// undistorted 1:1 map of template fractions. `null` (a template with no
/// interior fiducials — e.g. TAT — or a scan decoded before this field
/// existed) makes [OmrMeshCorrection.fromMeasuredFractions] build an
/// inactive correction, so this reduces exactly to the pre-mesh
/// `Offset(b.xFrac * size.width, b.yFrac * size.height)` mapping.
///
/// [template]/[BubblePos] are the existing, unmodified geometry — never
/// redefined or copied here.
@visibleForTesting
Offset correctedBubbleCenter({
  required BubblePos bubble,
  required OmrExamTemplate template,
  required Map<String, (double, double)>? meshInteriorMeasuredFrac,
  required Size size,
}) {
  final canonicalW = template.pageWidthPt.round();
  final canonicalH = template.pageHeightPt.round();
  final mesh = OmrMeshCorrection.fromMeasuredFractions(
    template: template,
    canonicalWidth: canonicalW,
    canonicalHeight: canonicalH,
    measuredFrac: meshInteriorMeasuredFrac,
  );
  final (cx, cy) = mesh.correct(
    bubble.xFrac * canonicalW,
    bubble.yFrac * canonicalH,
  );
  return Offset(cx / canonicalW * size.width, cy / canonicalH * size.height);
}

/// The applicant identity the Detailed Result's Examinee Information card
/// shows, resolved from ONE source at a time -- never a mix of fields from
/// two sources.
///
///  * The linked canonical [ExamineeRecord] (`examinees`) when the scan is
///    linked to one AND that record has a usable name -- first or last name
///    non-blank, the same test [ExamineeRecord.displayName] uses.
///    [examineeId] is then the canonical `temporary_examinee_id`, and
///    [scanId] keeps the scan's own generated number (`scans.examinee_number`)
///    separate from it.
///  * Otherwise the scan's own tag (`scans.first_name` etc.): this covers an
///    unlinked/legacy scan (`examinee_id` NULL), and a linked scan whose
///    canonical record has no usable name. [examineeId] is then the scan's own
///    number exactly as before, and [scanId] is null (nothing to separate).
///  * With no usable source every field is null and the card falls back to its
///    existing "—" convention.
class WebExamineeIdentity {
  const WebExamineeIdentity({
    this.examineeId,
    this.firstName,
    this.middleName,
    this.lastName,
    this.scanId,
    required this.fromCanonicalExaminee,
  });

  final String? examineeId;
  final String? firstName;
  final String? middleName;
  final String? lastName;

  /// The scan's own generated number; set only when [fromCanonicalExaminee],
  /// so the canonical ID and the scan's number are never conflated.
  final String? scanId;
  final bool fromCanonicalExaminee;
}

/// Pure, read-only. Never writes or copies anything into [scan]; the
/// canonical record stays the authoritative applicant identity and the scan's
/// own tag stays scan-level data.
WebExamineeIdentity resolveWebExamineeIdentity({
  required LocalScan scan,
  ExamineeRecord? linkedExaminee,
}) {
  final tag = scan.examinee;
  final canonical = linkedExaminee;
  if (canonical != null &&
      (canonical.firstName.trim().isNotEmpty ||
          canonical.lastName.trim().isNotEmpty)) {
    return WebExamineeIdentity(
      examineeId: canonical.temporaryExamineeId,
      firstName: canonical.firstName,
      middleName: canonical.middleName,
      lastName: canonical.lastName,
      scanId: tag?.examineeNumber,
      fromCanonicalExaminee: true,
    );
  }
  return WebExamineeIdentity(
    examineeId: tag?.examineeNumber,
    firstName: tag?.firstName,
    middleName: tag?.middleName,
    lastName: tag?.lastName,
    fromCanonicalExaminee: false,
  );
}

/// Read-only Detailed Result view for one examinee's scan, opened from
/// [GuidanceWebResultsView]'s View button.
///
/// Fetches the CURRENT cloud answer key (read-only, via
/// [GuidanceWebResultsService.loadAnswerKey]) purely to drive the Answer
/// Details table (and, for TAT, the per-test breakdown) through the
/// existing [scoreOmrResult] / [computeExamScoreForCode] — never a new
/// scoring implementation. The headline score/percentage/status shown here
/// always come from [scan]'s own already-persisted, already-official
/// [LocalScanResult] (see `cloud_batch_mapper.dart`) and are never
/// recalculated from the freshly-fetched key — see [_resultForDisplay].
///
/// Also lazily fetches the scan's own image (Scanned Answer Sheet card,
/// rectified preferred, falling back to original) via
/// [GuidanceWebResultsService.loadScanImage] — the existing, already
/// Web-safe [SyncClient.downloadScanImage] under the hood. The image is
/// held only as in-memory bytes for as long as this view is mounted: never
/// written to disk, never encrypted, never routed through
/// `LocalBatchRepository`/`BatchCryptoService`/`CloudRestoreService`.
///
/// When the loaded image is the rectified variant ([ScanImageVariant.
/// rectified]) and the exam has a registered [OmrExamTemplate], the sheet is
/// shown with the same graded-bubble overlay mobile's View Scan shows —
/// green/red/yellow rings and check/cross badges — via [planOverlayForItem]
/// and a Web-owned `_WebGradedOverlayPainter`. This is presentation-only
/// duplication of mobile's private, unimportable `_GradedOverlayPainter`:
/// the OMR interpretation itself ([ScoredItem]/[scoreOmrResult]) and the
/// bubble geometry ([OmrExamTemplate]/[BubblePos]/`omrTemplates`) are the
/// SAME existing objects, never recomputed or redefined here. The overlay
/// is never attempted over the original/un-rectified image, since
/// [BubblePos] fractions are only valid against the flattened page.
///
/// Performs no writes of any kind: no scan/examinee/answer-key/image
/// mutation, no `BatchRepository` call, no `CloudRestoreService`, no
/// `SyncState`.
class GuidanceWebResultDetailView extends StatefulWidget {
  const GuidanceWebResultDetailView({
    super.key,
    required this.scan,
    required this.batch,
    required this.service,
    required this.onBack,
    this.linkedExaminee,
    this.showClusterAnalysis = false,
    this.backLabel = 'Back to Results',
  });

  final LocalScan scan;
  final LocalBatch batch;
  final GuidanceWebResultsService service;
  final VoidCallback onBack;

  /// The canonical applicant this scan is linked to, when the caller already
  /// has it (the Examinee Records detail page does). Null for the Results
  /// page and for legacy/unlinked scans, which keep showing the scan's own
  /// tag -- see [resolveWebExamineeIdentity].
  final ExamineeRecord? linkedExaminee;

  /// Analytics mode: for exams that have cluster definitions (AT, QTM) the
  /// Answer Details card is replaced by a Cluster Analysis table. Every other
  /// exam, and the default (false), keeps Answer Details.
  final bool showClusterAnalysis;
  final String backLabel;

  @override
  State<GuidanceWebResultDetailView> createState() =>
      _GuidanceWebResultDetailViewState();
}

class _GuidanceWebResultDetailViewState
    extends State<GuidanceWebResultDetailView> {
  bool _loading = true;
  String? _error;
  AnswerKey? _answerKey;

  /// Batch average right-count per cluster label (Analytics mode only);
  /// empty until loaded or when it could not be computed.
  Map<String, double> _clusterAverages = const {};

  /// Independent of [_loading]/[_error] above (which gate only the
  /// answer-key-driven Examinee Information/Result Summary/Answer Details)
  /// — a missing or failed image must never block the rest of the page, so
  /// the Scanned Answer Sheet card manages its own loading/error/empty
  /// state entirely on its own.
  bool _imageLoading = true;
  String? _imageError;
  Uint8List? _imageBytes;
  ScanImageVariant _imageVariant = ScanImageVariant.none;

  @override
  void initState() {
    super.initState();
    _loadAnswerKey();
    if (!widget.showClusterAnalysis) _loadScanImage();
  }

  Future<void> _loadAnswerKey() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final key = await widget.service.loadAnswerKey(widget.batch.examCode);
      var averages = const <String, double>{};
      if (widget.showClusterAnalysis && key != null && _hasClusters) {
        try {
          final List<LocalScan> scans;
          if (widget.batch.examCode == 'TAT') {
            final results = await widget.service.loadResultsForBatch(
              widget.batch,
            );
            scans = results.scans
                .where(
                  (scan) => results.linkedExamineeByScanId.containsKey(scan.id),
                )
                .toList();
          } else {
            scans = await widget.service.loadScansForBatch(widget.batch);
          }
          final scoredScans = scans.map(
            (s) => scoreOmrResult(s.decoded, key).items,
          );
          averages = widget.batch.examCode == 'TAT'
              ? tatClusterAverages(scoredScans)
              : computeClusterAverages(widget.batch.examCode, scoredScans);
        } catch (_) {
          // Averages are supplementary; the table still shows the counts.
        }
      }
      if (!mounted) return;
      setState(() {
        _answerKey = key;
        _clusterAverages = averages;
        _loading = false;
      });
    } on GuidanceWebResultsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the answer key. Please try again.';
        _loading = false;
      });
    }
  }

  /// Loads the Scanned Answer Sheet image: rectified preferred, original as
  /// fallback, a plain empty state when neither exists. Never touches local
  /// storage of any kind — [GuidanceWebResultsService.loadScanImage] returns
  /// bytes straight from Supabase Storage, held here only in memory.
  ///
  ///  * [LocalScan.rectifiedImageFileName] is used only to decide WHETHER to
  ///    attempt the rectified download at all (its own value is never used
  ///    as a Storage path -- see that field's own doc comment) -- skipping
  ///    a guaranteed-404 request when the cloud row never recorded one.
  ///  * A clean "absent" result (`null`, not an exception) for rectified
  ///    falls through to trying the original -- an absent original then
  ///    leaves [_imageBytes] null, rendered as a friendly empty state, never
  ///    an error.
  ///  * An actual thrown failure (network/permission/storage) is NOT
  ///    silently retried against the other variant -- it's surfaced as
  ///    [_imageError] immediately, matching [_loadAnswerKey]'s exact
  ///    sanitization pattern.
  Future<void> _loadScanImage() async {
    setState(() {
      _imageLoading = true;
      _imageError = null;
    });
    try {
      Uint8List? bytes;
      var variant = ScanImageVariant.none;
      if (widget.scan.rectifiedImageFileName != null) {
        bytes = await widget.service.loadScanImage(
          widget.batch.id,
          widget.scan.id,
          rectified: true,
        );
        if (bytes != null) variant = ScanImageVariant.rectified;
      }
      if (bytes == null) {
        bytes = await widget.service.loadScanImage(
          widget.batch.id,
          widget.scan.id,
          rectified: false,
        );
        if (bytes != null) variant = ScanImageVariant.original;
      }
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _imageVariant = variant;
        _imageLoading = false;
      });
    } on GuidanceWebResultsException catch (e) {
      if (!mounted) return;
      setState(() {
        _imageError = e.message;
        _imageLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _imageError =
            'Could not load the scanned answer sheet. Please try again.';
        _imageLoading = false;
      });
    }
  }

  /// Per-item scoring, via the existing pure [scoreOmrResult] — never a
  /// second comparison implementation. `answerKey: null` (no cloud row for
  /// this exam) is a supported input: every item's `correctChoice` comes
  /// back null, i.e. [AnswerOutcome.notGraded], not an error.
  ///
  /// Scores [LocalScan.effectiveDecoded] — the machine-detected answers with
  /// this capture's manual corrections applied (restored from the cloud row's
  /// `decoded.manual` block by `mapCloudScan`) — exactly what the Guidance
  /// App's View Scan reads, so the Answer Details table, the graded overlay
  /// and the TAT breakdown all agree with the stored (already recalculated)
  /// score. The machine-detected `decoded` itself is never modified; a scan
  /// with no active corrections gets `decoded` back unchanged.
  ScoredResult get _scored =>
      scoreOmrResult(widget.scan.effectiveDecoded, _answerKey);

  /// The exam's [OmrExamTemplate] to draw the graded overlay against, or
  /// null when the overlay must not be attempted — either because the
  /// loaded image isn't the rectified variant (see [ScanImageVariant]'s doc
  /// comment) or because this exam code has no registered template
  /// (`omrTemplates[examCode]` is imported verbatim, never redefined).
  OmrExamTemplate? get _overlayTemplate {
    if (_imageVariant != ScanImageVariant.rectified) return null;
    final currentTemplate = omrTemplates[widget.batch.examCode];
    if (currentTemplate == null) return null;
    return overlayTemplateForScan(
      currentTemplate,
      scanTemplateVersion: widget.scan.decoded.templateVersion,
      sectionName: _scored.items.isNotEmpty
          ? _scored.items.first.sectionName
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        TextButton.icon(
          onPressed: widget.onBack,
          icon: const FaIcon(
            FontAwesomeIcons.arrowLeft,
            size: 12,
            color: AppColors.primaryGreen,
          ),
          label: Text(
            widget.backLabel,
            style: AppTextStyles.body(
              size: 11.5,
              weight: FontWeight.w700,
              color: AppColors.primaryGreen,
            ),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        ),
        const SizedBox(width: 8),
        Container(width: 1, height: 18, color: AppColors.cardBorder),
        const SizedBox(width: 12),
        Text('Detailed Result', style: AppTextStyles.heading(size: 16)),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return _message(FontAwesomeIcons.spinner, 'Loading detailed result...');
    }
    if (_error != null) {
      return _errorState();
    }
    if (widget.showClusterAnalysis) return _buildAnalyticsCards();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildExamineeCard(),
          const SizedBox(height: 16),
          _buildResultSummaryCard(),
          const SizedBox(height: 16),
          _buildScannedSheetCard(),
          const SizedBox(height: 16),
          if (widget.showClusterAnalysis) ...[
            if (_hasClusters) ...[
              _buildClusterAnalysisCard(),
              const SizedBox(height: 16),
            ],
            _buildCategoryCard(),
          ] else
            _buildAnswerDetailsCard(),
        ],
      ),
    );
  }

  /// Analytics keeps the stored headline visible and puts longer details
  /// behind independently expandable cards. The Results view is unchanged.
  Widget _buildAnalyticsCards() {
    final identity = resolveWebExamineeIdentity(
      scan: widget.scan,
      linkedExaminee: widget.linkedExaminee,
    );
    final name = [identity.firstName, identity.middleName, identity.lastName]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join(' ');
    final result = widget.scan.result;
    final letter = _examineeLetter();
    final hasClusters = _hasClusters;
    return SingleChildScrollView(
      key: const Key('analyticsResultCards'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final identityCard = _card('EXAMINEE', [
                _analyticsFact('Name', _dash(name)),
                _analyticsFact('Exam', _examTitle()),
                _analyticsFact('Batch', widget.batch.batchCode),
              ]);
              final summaryCard = _card('RESULT SUMMARY', [
                Wrap(
                  spacing: 28,
                  runSpacing: 12,
                  children: [
                    _analyticsFact(
                      'Score',
                      result == null
                          ? '—'
                          : '${result.rawScore} / ${_denominatorFor(result)}',
                    ),
                    _analyticsFact(
                      'Percentage',
                      result == null
                          ? '—'
                          : '${result.percentage.toStringAsFixed(2)}%',
                    ),
                    _analyticsFact('Status', result?.status ?? 'Ungraded'),
                    _analyticsFact('Category', letter ?? '—'),
                  ],
                ),
              ]);
              if (constraints.maxWidth < 760) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    identityCard,
                    const SizedBox(height: 12),
                    summaryCard,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: identityCard),
                  const SizedBox(width: 16),
                  Expanded(child: summaryCard),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          _analyticsExpansion(
            id: 'identity',
            title: 'Examinee details',
            subtitle: 'Identification and scan date',
            child: _buildExamineeCard(),
          ),
          if (hasClusters)
            _analyticsExpansion(
              id: 'clusters',
              title: 'Cluster analysis',
              initiallyExpanded: widget.batch.examCode == 'TAT',
              subtitle: 'Correct answers and comparison with the batch',
              child: _buildClusterAnalysisCard(),
            ),
          _analyticsExpansion(
            id: 'category',
            title: 'Category and interpretation',
            subtitle: 'Classification details and supporting analysis',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildCategoryCard(),
                if (result != null && widget.batch.examCode == 'TAT')
                  _card('TEST BREAKDOWN', _tatBreakdownRows(result)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _analyticsFact(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTextStyles.body(size: 12, color: AppColors.textGray),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: AppTextStyles.body(size: 16, weight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _analyticsExpansion({
    required String id,
    required String title,
    required String subtitle,
    required Widget child,
    bool initiallyExpanded = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          key: PageStorageKey('analytics-${widget.scan.id}-$id'),
          initiallyExpanded: initiallyExpanded,
          title: Text(
            title,
            style: AppTextStyles.body(size: 14, weight: FontWeight.w700),
          ),
          subtitle: Text(
            subtitle,
            style: AppTextStyles.body(size: 12, color: AppColors.textGray),
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          children: [child],
        ),
      ),
    );
  }

  Widget _message(FaIconData icon, String text) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FaIcon(icon, size: 36, color: AppColors.textGray),
          const SizedBox(height: 14),
          Text(
            text,
            style: AppTextStyles.body(size: 11.5, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }

  Widget _errorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const FaIcon(
            FontAwesomeIcons.triangleExclamation,
            size: 36,
            color: AppColors.warmRedOrange,
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: AppTextStyles.body(
                size: 11.5,
                color: AppColors.warmRedOrange,
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: widget.onBack,
            child: Text(
              'Back to Results',
              style: AppTextStyles.body(
                size: 11.5,
                weight: FontWeight.w700,
                color: AppColors.primaryGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Examinee Information -------------------------------------------------

  Widget _buildExamineeCard() {
    final identity = resolveWebExamineeIdentity(
      scan: widget.scan,
      linkedExaminee: widget.linkedExaminee,
    );
    return _card('EXAMINEE INFORMATION', [
      if (!identity.fromCanonicalExaminee) _unverifiedIdentityNotice(),
      _infoRow('Examinee ID', _dash(identity.examineeId)),
      _infoRow('First Name', _dash(identity.firstName)),
      _infoRow('Middle Name', _dash(identity.middleName)),
      _infoRow('Last Name', _dash(identity.lastName)),
      // The scan's own generated number, kept apart from the canonical
      // Examinee ID above (only shown when the canonical record is the source).
      if (identity.fromCanonicalExaminee)
        _infoRow('Scan ID', _dash(identity.scanId)),
      _infoRow('Exam Type', _examTitle()),
      _infoRow('Batch', widget.batch.batchCode),
      _infoRow('Scan Date', _fmtDateTime(widget.scan.capturedAt)),
    ]);
  }

  /// Shown whenever [WebExamineeIdentity.fromCanonicalExaminee] is false.
  /// That covers TWO different scans ([resolveWebExamineeIdentity]'s own
  /// doc comment): one that is genuinely unlinked/has a dangling
  /// `examinee_id`, and one that IS linked but whose canonical record has
  /// no usable name. The wording below is deliberately neutral about which
  /// of the two this is -- it must stay true for a scan that really is
  /// linked, so it never says "not linked" outright, only that whatever
  /// name/ID appears below is not a verified one. Status indication only,
  /// matching [GuidanceWebResultsView]'s own row-level badge -- this card
  /// offers no linking action of its own.
  Widget _unverifiedIdentityNotice() {
    return Container(
      key: const Key('unverifiedIdentityNotice'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Text(
        'The name/ID shown below is not from a verified Examinee Record.',
        style: AppTextStyles.body(
          size: 10,
          weight: FontWeight.w600,
          color: AppColors.textGray,
        ),
      ),
    );
  }

  String _examTitle() => widget.batch.examTitle.isNotEmpty
      ? widget.batch.examTitle
      : widget.batch.examCode;

  // --- Result Summary ---------------------------------------------------

  Widget _buildResultSummaryCard() {
    final result = widget.scan.result;
    if (result == null) {
      return _card('RESULT SUMMARY', [_infoRow('Status', 'Ungraded')]);
    }
    return _card('RESULT SUMMARY', [
      _infoRow('Score', '${result.rawScore} / ${_denominatorFor(result)}'),
      _infoRow('Percentage', '${result.percentage.toStringAsFixed(2)}%'),
      _infoRow('Status', result.status),
      ..._examSpecificRows(result),
    ]);
  }

  /// TAT's official denominator is its 160-point maximum score, never
  /// `LocalScanResult.totalItems` — matches the exact convention already
  /// used by the Results table ([GuidanceWebResultsView._denominatorFor])
  /// and the mobile app's own TAT display.
  int _denominatorFor(LocalScanResult result) =>
      widget.batch.examCode == 'TAT' ? 160 : result.totalItems;

  /// AT category / QTM eligibility / TAT per-test breakdown — every value
  /// here comes from an EXISTING helper ([admissionCategory], [qtmEligibility],
  /// [computeExamScoreForCode]'s TAT fields), never a new classification
  /// rule. AT's category and QTM's eligibility are pure functions of
  /// [result]'s own already-stored `rawScore`, so they can never disagree
  /// with the recorded headline result. Only the TAT breakdown depends on
  /// the freshly-fetched (possibly since-changed) answer key — see this
  /// class's doc comment and the notice in [_buildAnswerDetailsCard].
  List<Widget> _examSpecificRows(LocalScanResult result) {
    switch (widget.batch.examCode) {
      case 'AT':
        final category = admissionCategory(result.rawScore);
        return [_infoRow('Category', _categoryLabel(category))];
      case 'QTM':
        final eligibility = qtmEligibility(result.rawScore);
        return [_infoRow('Eligibility', _eligibilityLabel(eligibility))];
      case 'TAT':
        return _tatBreakdownRows(result);
      default:
        return const [];
    }
  }

  static String _categoryLabel(AdmissionCategory? c) => switch (c) {
    AdmissionCategory.a => 'A',
    AdmissionCategory.b => 'B',
    AdmissionCategory.c => 'C',
    AdmissionCategory.d => 'D',
    null => 'Not classified',
  };

  static String _eligibilityLabel(QtmEligibility? e) => switch (e) {
    QtmEligibility.allCoursesIncludingBscs =>
      'All QTM-required courses, incl. BSCS',
    QtmEligibility.allCoursesExceptBscs =>
      'All QTM-required courses, except BSCS',
    QtmEligibility.notEligible => 'Does not meet the QTM requirement',
    null => '—',
  };

  /// TAT breakdown, recomputed via the existing [computeExamScoreForCode]
  /// against the currently-fetched answer key when [result] itself doesn't
  /// already carry one (the Web Results list maps scans without an answer
  /// key — see `GuidanceWebResultsService.loadScansForBatch`'s doc
  /// comment). Shown only as additional detail; [result]'s own `rawScore`/
  /// `percentage`/`status` (already displayed above, unchanged) remain the
  /// recorded result regardless of what this recomputation produces.
  List<Widget> _tatBreakdownRows(LocalScanResult result) {
    final breakdown = result.hasTatBreakdown ? result : _liveTatBreakdown();
    if (breakdown == null) {
      return [_infoRow('Breakdown', 'Unavailable for this result')];
    }
    return [
      _infoRow(
        'Test 1',
        '${breakdown.tatTest1Correct ?? 0} correct × 2 = ${breakdown.tatTest1Score ?? 0} / 60',
      ),
      _infoRow(
        'Test 2',
        '${breakdown.tatTest2Correct ?? 0} correct − ${breakdown.tatTest2Wrong ?? 0} wrong = ${breakdown.tatTest2Score ?? 0} / 80',
      ),
      _infoRow(
        'Test 3',
        '${breakdown.tatTest3Correct ?? 0} correct − ${breakdown.tatTest3Wrong ?? 0} wrong = ${breakdown.tatTest3Score ?? 0} / 20',
      ),
    ];
  }

  /// A display-only [LocalScanResult] carrying the TAT per-test breakdown
  /// computed from the current answer key, with every headline field
  /// (`rawScore`/`totalGraded`/`totalItems`/`percentage`/`status`/audit
  /// fields) copied verbatim from [widget.scan.result] — never replaced.
  /// Null when no answer key is available or the exam template doesn't
  /// resolve to a TAT score.
  LocalScanResult? _liveTatBreakdown() {
    final stored = widget.scan.result;
    if (stored == null || _answerKey == null) return null;
    final examScore = computeExamScoreForCode(_scored);
    if (examScore == null || !examScore.isTat) return null;
    return LocalScanResult(
      rawScore: stored.rawScore,
      totalGraded: stored.totalGraded,
      totalItems: stored.totalItems,
      percentage: stored.percentage,
      status: stored.status,
      scannedAt: stored.scannedAt,
      processedByUid: stored.processedByUid,
      processedByName: stored.processedByName,
      tatTest1Correct: examScore.tatTest1Correct,
      tatTest1Wrong: examScore.tatTest1Wrong,
      tatTest1Score: examScore.tatTest1Score,
      tatTest2Correct: examScore.tatTest2Correct,
      tatTest2Wrong: examScore.tatTest2Wrong,
      tatTest2Score: examScore.tatTest2Score,
      tatTest3Correct: examScore.tatTest3Correct,
      tatTest3Wrong: examScore.tatTest3Wrong,
      tatTest3Score: examScore.tatTest3Score,
      tatTotal: examScore.tatTotal,
    );
  }

  // --- Scanned Answer Sheet -------------------------------------------

  Widget _buildScannedSheetCard() {
    return _card('SCANNED ANSWER SHEET', [
      if (_imageLoading)
        _imageMessage(FontAwesomeIcons.spinner, 'Loading scanned sheet...')
      else if (_imageError != null)
        _imageMessage(
          FontAwesomeIcons.triangleExclamation,
          _imageError!,
          isError: true,
        )
      else if (_imageBytes == null)
        _imageMessage(
          FontAwesomeIcons.image,
          'No scanned image available for this sheet.',
        )
      else
        _buildImagePreview(_imageBytes!),
    ]);
  }

  Widget _imageMessage(FaIconData icon, String text, {bool isError = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(
            icon,
            size: 26,
            color: isError ? AppColors.warmRedOrange : AppColors.textGray,
          ),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: AppTextStyles.body(
              size: 11,
              color: isError ? AppColors.warmRedOrange : AppColors.textGray,
            ),
          ),
        ],
      ),
    );
  }

  /// The preview: a fixed-height, full-width box so the page never grows
  /// unreasonably tall regardless of the photo's real resolution. Clicking/
  /// tapping opens [_FullScreenScanImageViewer] for a zoomable look — this
  /// preview itself never zooms. When [_overlayTemplate] is non-null (the
  /// rectified image loaded and a template exists for this exam), the SAME
  /// graded overlay shown full-screen is also drawn here, at whatever size
  /// the preview box ends up — see [_buildScanImageBox] for how the
  /// image/overlay box is sized without letterbox misalignment.
  Widget _buildImagePreview(Uint8List bytes) {
    final template = _overlayTemplate;
    final items = template != null ? _scored.items : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('scannedSheetPreview'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => _openFullImageViewer(bytes),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: double.infinity,
              height: 360,
              child: LayoutBuilder(
                builder: (context, constraints) => Center(
                  child: _buildScanImageBox(
                    bytes: bytes,
                    template: template,
                    items: items,
                    meshInteriorMeasuredFrac:
                        widget.scan.decoded.meshInteriorMeasuredFrac,
                    maxWidth: constraints.maxWidth,
                    maxHeight: constraints.maxHeight,
                    errorBuilder: (context, error, stackTrace) => _imageMessage(
                      FontAwesomeIcons.triangleExclamation,
                      'Unable to display this scanned sheet.',
                      isError: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Scanned answer sheet — click to enlarge',
          style: AppTextStyles.body(size: 9.5, color: AppColors.textGray),
        ),
      ],
    );
  }

  void _openFullImageViewer(Uint8List bytes) {
    final template = _overlayTemplate;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullScreenScanImageViewer(
          bytes: bytes,
          overlayTemplate: template,
          overlayItems: template != null ? _scored.items : null,
          meshInteriorMeasuredFrac:
              widget.scan.decoded.meshInteriorMeasuredFrac,
        ),
      ),
    );
  }

  // --- Cluster Analysis (Analytics mode, AT / QTM / TAT) --------------------------

  bool get _hasClusters =>
      widget.batch.examCode == 'TAT' ||
      clusterDefsFor(widget.batch.examCode) != null;

  Widget _buildClusterAnalysisCard() {
    final rows = widget.batch.examCode == 'TAT'
        ? tatClusterRows(_scored.items, averages: _clusterAverages)
        : computeClusterRows(
            widget.batch.examCode,
            _scored.items,
            averages: _clusterAverages,
          )!;
    final headerStyle = AppTextStyles.body(
      size: 9.5,
      weight: FontWeight.w800,
      color: AppColors.textGray,
    );
    Widget cell(Widget child) => Expanded(child: Center(child: child));
    Widget minus() => Text(
      '–',
      style: AppTextStyles.body(size: 12, color: AppColors.textGray),
    );
    Widget belowMark(ClusterRow r) => r.band == ClusterBand.below
        ? const Icon(Icons.check, size: 16, color: AppColors.warmRedOrange)
        : minus();
    Widget aboveMark(ClusterRow r) => r.band == ClusterBand.above
        ? const Icon(Icons.check, size: 16, color: AppColors.primaryGreen)
        : minus();
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    Widget averageCell(ClusterRow r) => Text(
      r.average == null
          ? '—'
          : '${r.right?.toString() ?? '—'}/${fmt(r.average!)}',
      style: AppTextStyles.body(
        size: 11,
        weight: r.band == ClusterBand.average
            ? FontWeight.w800
            : FontWeight.w400,
      ),
    );
    return _card('CLUSTER ANALYSIS', [
      if (widget.batch.examCode == 'TAT') ...[
        Text(
          tatClusterScoringNote,
          style: AppTextStyles.body(size: 12, color: AppColors.textGray),
        ),
        const SizedBox(height: 12),
      ],
      if (_answerKey == null) ...[
        _answerKeyNotice(),
        const SizedBox(height: 12),
      ],
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(flex: 4, child: Text('CLUSTER', style: headerStyle)),
            cell(Text('TOTAL ITEMS', style: headerStyle)),
            cell(Text('RIGHT', style: headerStyle)),
            cell(Text('BELOW AVG', style: headerStyle)),
            cell(Text('AVERAGE', style: headerStyle)),
            cell(Text('ABOVE AVG', style: headerStyle)),
          ],
        ),
      ),
      const Divider(height: 1, color: AppColors.cardBorder),
      for (final r in rows)
        Container(
          key: Key('clusterRow_${r.def.label}'),
          color: r.def.isGroup ? AppColors.lightBg : null,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Padding(
                  padding: EdgeInsets.only(left: r.def.isGroup ? 8 : 20),
                  child: Text(
                    '${r.def.label} (${r.def.fromItem}–${r.def.toItem})',
                    style: AppTextStyles.body(
                      size: 11,
                      weight: r.def.isGroup ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
              cell(Text('${r.total}', style: AppTextStyles.body(size: 11))),
              cell(
                Text(
                  r.right?.toString() ?? '—',
                  style: AppTextStyles.body(size: 11, weight: FontWeight.w700),
                ),
              ),
              cell(belowMark(r)),
              cell(averageCell(r)),
              cell(aboveMark(r)),
            ],
          ),
        ),
    ]);
  }

  // --- Category (Analytics mode, AT / QTM) ----------------------------------

  static const Color _catA = Color(0xFFEF4444);
  static const Color _catB = Color(0xFFFFB000);
  static const Color _catC = Color(0xFF4A7AF5);
  static const Color _catD = Color(0xFF10B981);

  /// (letter, color, score range, optional percent label) per exam, lowest
  /// band first - mirrors the Guidance Council's category templates.
  List<(String, Color, String, String?)> get _categoryBands =>
      widget.batch.examCode == 'TAT'
      ? const [
          ('A', _catA, '0 – 121', '76% and below'),
          ('B', _catB, '128 – 135', '80% – 84%'),
          ('C', _catC, '136 – 143', '85% – 89%'),
          ('D', _catD, '144 – 160', '90% and above'),
        ]
      : widget.batch.examCode == 'QTM'
      ? const [
          ('A', _catA, '0 – 45', '76% and below'),
          ('B', _catB, '48 – 50', '80% – 84%'),
          ('C', _catC, '51 – 53', '85% – 89%'),
          ('D', _catD, '54 – 60', '90% and above'),
        ]
      : const [
          ('A', _catA, '0 – 54', null),
          ('B', _catB, '58 – 60', null),
          ('C', _catC, '61 – 64', null),
          ('D', _catD, '65 – 72', null),
        ];

  String? _examineeLetter() {
    final raw = widget.scan.result?.rawScore;
    if (raw == null) return null;
    if (widget.batch.examCode == 'QTM') {
      return qtmCategory(raw)?.name.toUpperCase();
    }
    if (widget.batch.examCode == 'TAT') {
      return tatCategory(raw)?.name.toUpperCase();
    }
    return admissionCategory(raw)?.name.toUpperCase();
  }

  Widget _buildCategoryCard() {
    final letter = _examineeLetter();
    final letterColor = _categoryBands
        .firstWhere(
          (b) => b.$1 == letter,
          orElse: () => ('', AppColors.textGray, '', null),
        )
        .$2;
    final isQtm = widget.batch.examCode == 'QTM';
    // The category radar remains AT/QTM; TAT has its own cluster table above.
    final allRows = computeClusterRows(
      widget.batch.examCode,
      _scored.items,
      averages: _clusterAverages,
    );
    final rows = (allRows ?? const <ClusterRow>[])
        .where((r) => !r.def.isGroup)
        .toList();

    List<double?> fractions(double? Function(ClusterRow r) value) => [
      for (final r in rows)
        () {
          final v = value(r);
          return v == null || r.total == 0 ? null : v / r.total;
        }(),
    ];

    final raw = widget.scan.result?.rawScore;
    final eligibility = (isQtm && raw != null) ? qtmEligibility(raw) : null;
    final tatMeets =
        widget.batch.examCode == 'TAT' &&
        raw != null &&
        tatEligibility(raw) == TatEligibility.meetsRequirement;

    return _card('CATEGORY', [
      Wrap(
        spacing: 32,
        runSpacing: 24,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          if (allRows != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClusterRadarChart(
                  key: const Key('clusterRadar'),
                  axes: [for (final r in rows) r.def.label],
                  series: [
                    ClusterRadarSeries(
                      label: 'Batch average',
                      color: _catB,
                      fractions: fractions((r) => r.average),
                    ),
                    ClusterRadarSeries(
                      label: 'This examinee',
                      color: _catC,
                      fractions: fractions((r) => r.right?.toDouble()),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _legendDot(_catC, 'This examinee'),
                    const SizedBox(width: 16),
                    _legendDot(_catB, 'Batch average'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  "Each axis is the share of that cluster's items answered correctly.",
                  style: AppTextStyles.body(
                    size: 9.5,
                    color: AppColors.textGray,
                  ),
                ),
              ],
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 280, maxWidth: 380),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Category', style: AppTextStyles.heading(size: 20)),
                Text(
                  letter == null ? '—' : '$letter.',
                  key: const Key('categoryLetter'),
                  style: AppTextStyles.heading(size: 88).copyWith(
                    color: letter == null ? AppColors.textGray : letterColor,
                    height: 1.1,
                  ),
                ),
                if (letter == null)
                  Text(
                    raw == null
                        ? 'No recorded score.'
                        : 'Unclassified for this score.',
                    style: AppTextStyles.body(
                      size: 11,
                      color: AppColors.textGray,
                    ),
                  ),
                const SizedBox(height: 12),
                _categoryLegend(letter, isQtm, eligibility, tatMeets),
              ],
            ),
          ),
          if (allRows != null)
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 240, maxWidth: 340),
              child: _buildInsightsPanel(allRows),
            ),
        ],
      ),
    ]);
  }

  Widget _buildInsightsPanel(List<ClusterRow> rows) {
    final insights = buildClusterInsights(rows);
    return Container(
      key: const Key('insightsPanel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.lightBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Insights', style: AppTextStyles.heading(size: 15)),
          const SizedBox(height: 10),
          if (insights.isEmpty)
            Text(
              'No graded results to comment on yet.',
              style: AppTextStyles.body(size: 11, color: AppColors.textGray),
            )
          else
            for (final i in insights)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      switch (i.kind) {
                        InsightKind.strength => Icons.trending_up,
                        InsightKind.concern => Icons.flag_outlined,
                        InsightKind.neutral => Icons.horizontal_rule,
                      },
                      size: 16,
                      color: switch (i.kind) {
                        InsightKind.strength => AppColors.primaryGreen,
                        InsightKind.concern => AppColors.warmRedOrange,
                        InsightKind.neutral => AppColors.textGray,
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        i.text,
                        style: AppTextStyles.body(size: 11.5),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: AppTextStyles.body(size: 10.5)),
    ],
  );

  Widget _categoryLegend(
    String? letter,
    bool isQtm,
    QtmEligibility? elig,
    bool tatMeets,
  ) {
    final isTat = widget.batch.examCode == 'TAT';
    final title = examTypeDisplayLabel(widget.batch.examCode);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final b in _categoryBands.reversed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
              decoration: BoxDecoration(
                color: b.$1 == letter ? b.$2.withValues(alpha: 0.12) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      '${b.$1}.',
                      style: AppTextStyles.heading(
                        size: 16,
                      ).copyWith(color: b.$2),
                    ),
                  ),
                  if (b.$4 != null)
                    Expanded(
                      child: Text(b.$4!, style: AppTextStyles.body(size: 11)),
                    )
                  else
                    const Spacer(),
                  Text(
                    b.$3,
                    style: AppTextStyles.body(
                      size: 11,
                      weight: FontWeight.w700,
                      color: b.$2,
                    ),
                  ),
                ],
              ),
            ),
          if (isTat) ...[
            const Divider(height: 16, color: AppColors.cardBorder),
            _eligibilityRow(
              'C.2',
              _catC,
              '30% (48) for English, Filipino, Mathematics, Science, Social Studies and Religious Education',
              tatMeets,
            ),
          ],
          if (isQtm) ...[
            const Divider(height: 16, color: AppColors.cardBorder),
            _eligibilityRow(
              'C.2',
              _catC,
              '30% (18) for Computer Science',
              elig == QtmEligibility.allCoursesIncludingBscs,
            ),
            _eligibilityRow(
              'D.2',
              const Color(0xFFA78BFA),
              '25% (15) for Architecture, Civil, Computer, Electrical and Electronics Engineering',
              elig == QtmEligibility.allCoursesIncludingBscs ||
                  elig == QtmEligibility.allCoursesExceptBscs,
            ),
          ],
        ],
      ),
    );
  }

  Widget _eligibilityRow(String tag, Color color, String text, bool met) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: Text(
              tag,
              style: AppTextStyles.heading(size: 14).copyWith(color: color),
            ),
          ),
          Expanded(child: Text(text, style: AppTextStyles.body(size: 10.5))),
          if (met)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.check, size: 15, color: AppColors.primaryGreen),
            ),
        ],
      ),
    );
  }

  // --- Answer Details -----------------------------------------------------

  Widget _buildAnswerDetailsCard() {
    final bySection = groupScoredItemsBySection(_scored.items);
    final groupBySection = bySection.length > 1;
    return _card('ANSWER DETAILS', [
      _answerKeyNotice(),
      const SizedBox(height: 12),
      if (bySection.isEmpty)
        Text(
          'No decoded items available for this scan.',
          style: AppTextStyles.body(size: 11, color: AppColors.textGray),
        )
      else if (groupBySection)
        ...bySection.entries.map((e) => _buildSectionBlock(e.key, e.value))
      else
        _buildAnswerTable(bySection.values.first),
    ]);
  }

  Widget _answerKeyNotice() {
    final text = _answerKey == null
        ? 'No answer key is currently available for this exam. Marked answers are shown below without a correctness comparison.'
        : 'Answer details are compared against the current answer key. The displayed score and percentage are the recorded result.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.lightBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const FaIcon(
            FontAwesomeIcons.circleInfo,
            size: 12,
            color: AppColors.textGray,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionBlock(String sectionName, List<ScoredItem> items) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sectionName,
            style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          _buildAnswerTable(items),
        ],
      ),
    );
  }

  Widget _buildAnswerTable(List<ScoredItem> items) {
    final headerStyle = AppTextStyles.body(
      size: 9.5,
      weight: FontWeight.w800,
      color: AppColors.textGray,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              SizedBox(width: 44, child: Text('ITEM', style: headerStyle)),
              Expanded(
                flex: 2,
                child: Text('CORRECT ANSWER', style: headerStyle),
              ),
              Expanded(
                flex: 2,
                child: Text('EXAMINEE ANSWER', style: headerStyle),
              ),
              Expanded(flex: 2, child: Text('RESULT', style: headerStyle)),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.cardBorder),
        ...items.map(_buildAnswerRow),
      ],
    );
  }

  Widget _buildAnswerRow(ScoredItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '${item.itemNumber}',
              style: AppTextStyles.body(size: 11),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              item.correctChoice ?? '—',
              style: AppTextStyles.body(size: 11),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              item.markedChoice ?? '—',
              style: AppTextStyles.body(size: 11),
            ),
          ),
          Expanded(flex: 2, child: _outcomeChip(answerOutcomeFor(item))),
        ],
      ),
    );
  }

  Widget _outcomeChip(AnswerOutcome outcome) {
    final (label, background, foreground) = switch (outcome) {
      AnswerOutcome.correct => (
        'Correct',
        AppColors.emerald100,
        const Color(0xFF065F46),
      ),
      AnswerOutcome.incorrect => (
        'Incorrect',
        const Color(0xFFFEE2E2),
        const Color(0xFF991B1B),
      ),
      AnswerOutcome.ambiguous => (
        'Ambiguous mark',
        const Color(0xFFFEF3C7),
        const Color(0xFF92400E),
      ),
      AnswerOutcome.notGraded => (
        'Not graded',
        AppColors.lightBg,
        AppColors.textGray,
      ),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: AppTextStyles.body(
            size: 9.5,
            weight: FontWeight.w700,
            color: foreground,
          ),
        ),
      ),
    );
  }

  // --- shared bits -----------------------------------------------------

  Widget _card(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTextStyles.body(
              size: 10.5,
              weight: FontWeight.w800,
              color: AppColors.textGray,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: AppTextStyles.body(
                size: 10.5,
                weight: FontWeight.w700,
                color: AppColors.textGray,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body(size: 11.5, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// A blank/missing individual field displays as a plain dash — never a
  /// placeholder like "UNKNOWN"/"N/A"/"No Name Found" (matches the
  /// automatic-Examinee-ID feature's own "no fake values" rule).
  String _dash(String? value) =>
      (value == null || value.trim().isEmpty) ? '—' : value;

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

  String _fmtDateTime(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ap = d.hour < 12 ? 'AM' : 'PM';
    return '${_months[d.month - 1]} ${d.day}, ${d.year} · $h:$m $ap';
  }
}

/// Minimal, Web-specific full-screen viewer for one already-in-memory scan
/// image — deliberately NOT a reuse of mobile's `ScannedImageViewerScreen`
/// (its black immersive chrome, per-item answer-key end drawer are a
/// different, mobile-review-workflow concern; the Detailed Result page
/// already has its own Answer Details table, so repeating that drawer here
/// would be redundant). Just what this task asks for: a large image,
/// zoom/pan via [InteractiveViewer], the SAME graded overlay the preview
/// shows (when [overlayTemplate]/[overlayItems] are given), and a close
/// button — no editing, no answer-key panel, no rescan/correction controls.
///
/// The image and its overlay are built as ONE fixed-size box (see
/// [_buildScanImageBox]) that is itself [InteractiveViewer]'s child, so
/// zooming/panning moves and scales them together — never two independently
/// zoomable layers.
class _FullScreenScanImageViewer extends StatelessWidget {
  const _FullScreenScanImageViewer({
    required this.bytes,
    this.overlayTemplate,
    this.overlayItems,
    this.meshInteriorMeasuredFrac,
  });

  final Uint8List bytes;
  final OmrExamTemplate? overlayTemplate;
  final List<ScoredItem>? overlayItems;
  final Map<String, (double, double)>? meshInteriorMeasuredFrac;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 6,
                child: Center(
                  child: _buildScanImageBox(
                    bytes: bytes,
                    template: overlayTemplate,
                    items: overlayItems,
                    meshInteriorMeasuredFrac: meshInteriorMeasuredFrac,
                    maxWidth: screenSize.width,
                    maxHeight: screenSize.height,
                    errorBuilder: (context, error, stackTrace) => Center(
                      child: Text(
                        'Unable to display this scanned sheet.',
                        style: AppTextStyles.body(
                          size: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Builds the scanned sheet, sized to fit within [maxWidth] x [maxHeight],
/// with the SAME graded overlay mobile's View Scan shows when [template]
/// and [items] are both given — shared by the preview card and the
/// full-screen viewer so both size it identically.
///
/// The critical alignment problem this solves: naively wrapping
/// `Image.memory(fit: BoxFit.contain)` and a `CustomPaint` in a
/// `Stack(fit: StackFit.expand)` inside an outer box would letterbox the
/// IMAGE (contain scales it down, centering it with blank bars) while the
/// CustomPaint's canvas would still be the FULL outer box — misaligning
/// every ring/badge by the letterbox offset. Instead, the OUTER box itself
/// is pre-sized to [template]'s own page aspect ratio
/// (`pageWidthPt`/`pageHeightPt` — the exact aspect ratio the rectification
/// step targets, the same assumption mobile's own painter relies on for its
/// independent per-axis `pxPerPtX`/`pxPerPtY` scale factors), so the image
/// (`BoxFit.fill`) and the `CustomPaint` (`StackFit.expand`) always occupy
/// the IDENTICAL rectangle — no letterboxing, no misalignment, no need to
/// separately track the image's true decoded pixel size.
///
/// When [template] or [items] is null (no overlay — original-only fallback,
/// no registered template, or the image isn't the rectified variant), this
/// falls back to a plain `BoxFit.contain` image with no CustomPaint at all,
/// sized to the full [maxWidth]/[maxHeight] box.
Widget _buildScanImageBox({
  required Uint8List bytes,
  required OmrExamTemplate? template,
  required List<ScoredItem>? items,
  required Map<String, (double, double)>? meshInteriorMeasuredFrac,
  required double maxWidth,
  required double maxHeight,
  required Widget Function(BuildContext, Object, StackTrace?) errorBuilder,
}) {
  if (template == null ||
      items == null ||
      template.pageWidthPt <= 0 ||
      template.pageHeightPt <= 0) {
    return SizedBox(
      width: maxWidth,
      height: maxHeight,
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: errorBuilder,
      ),
    );
  }

  final aspect = template.pageWidthPt / template.pageHeightPt;
  var width = maxWidth;
  var height = width / aspect;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspect;
  }

  return SizedBox(
    width: width,
    height: height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(bytes, fit: BoxFit.fill, errorBuilder: errorBuilder),
        CustomPaint(
          key: const Key('gradedOverlayPaint'),
          painter: _WebGradedOverlayPainter(
            scoredItems: items,
            template: template,
            meshInteriorMeasuredFrac: meshInteriorMeasuredFrac,
          ),
        ),
      ],
    ),
  );
}

/// Web-owned equivalent of mobile's private `_GradedOverlayPainter`
/// (`scanned_image_viewer_screen.dart`) — duplicated here only because that
/// class is library-private and mobile code must not be modified to export
/// it. The decision logic ([planOverlayForItem]) and the mesh-corrected
/// coordinate mapping ([correctedBubbleCenter]) are byte-for-byte mirrors of
/// that class; this painter's `paint()` is purely the remaining Canvas
/// mechanics (ring/badge drawing) applied to their output — no scoring, no
/// OMR interpretation, no coordinate generation happens here.
class _WebGradedOverlayPainter extends CustomPainter {
  const _WebGradedOverlayPainter({
    required this.scoredItems,
    required this.template,
    this.meshInteriorMeasuredFrac,
  });

  final List<ScoredItem> scoredItems;
  final OmrExamTemplate template;

  /// See [OmrScanResult.meshInteriorMeasuredFrac] / [correctedBubbleCenter]'s
  /// doc comment — the same interior-fiducial readings [OmrDecoder.decode]
  /// used to sample bubbles for [scoredItems], so this overlay places its
  /// rings using the identical geometric mapping scoring did.
  final Map<String, (double, double)>? meshInteriorMeasuredFrac;

  @override
  void paint(Canvas canvas, Size size) {
    if (template.pageWidthPt <= 0 || template.pageHeightPt <= 0) return;
    final pxPerPtX = size.width / template.pageWidthPt;
    final pxPerPtY = size.height / template.pageHeightPt;
    final ringRx = template.bubbleRadiusPt * 1.8 * pxPerPtX;
    final ringRy = template.bubbleRadiusYPt * 1.8 * pxPerPtY;
    final strokeWidth = (ringRx < ringRy ? ringRx : ringRy) * 0.3;
    final badgeRadius = (ringRx < ringRy ? ringRx : ringRy) * 0.6;

    Offset centerOf(BubblePos b) => correctedBubbleCenter(
      bubble: b,
      template: template,
      meshInteriorMeasuredFrac: meshInteriorMeasuredFrac,
      size: size,
    );

    void ring(BubblePos b, Color color) {
      canvas.drawOval(
        Rect.fromCenter(
          center: centerOf(b),
          width: ringRx * 2,
          height: ringRy * 2,
        ),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
    }

    void badge(BubblePos leftmost, Color color, bool correct) {
      final anchor = centerOf(leftmost);
      final center = Offset(
        anchor.dx - (template.bubbleRadiusPt + 9) * pxPerPtX,
        anchor.dy,
      );
      canvas.drawCircle(center, badgeRadius, Paint()..color = color);
      final tp = TextPainter(
        text: TextSpan(
          text: correct ? '✓' : '✕',
          style: TextStyle(
            color: Colors.white,
            fontSize: badgeRadius * 1.35,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    }

    for (final item in scoredItems) {
      final bubbles = bubblesForOverlayItem(
        template,
        item.sectionName,
        item.itemNumber,
      );
      final plan = planOverlayForItem(item, bubbles);
      if (plan == null) {
        continue;
      }

      if (plan.markedBubble != null) {
        ring(plan.markedBubble!, plan.markedColor!);
      }
      if (plan.keyBubble != null) {
        ring(plan.keyBubble!, WebOverlayColors.key);
      }
      badge(plan.badgeBubble, plan.badgeColor, plan.badgeIsCorrect);
    }
  }

  @override
  bool shouldRepaint(covariant _WebGradedOverlayPainter oldDelegate) =>
      oldDelegate.scoredItems != scoredItems ||
      oldDelegate.template != template ||
      oldDelegate.meshInteriorMeasuredFrac != meshInteriorMeasuredFrac;
}
