import 'dart:io';
import '../../../core/omr/omr_template_registry.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/omr/omr_mesh_correction.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../models/answer_correction.dart';
import '../../../models/local_batch.dart';
import '../widgets/answer_correction_sheet.dart';

/// Full-screen viewer for one originally-captured OMR sheet photo, so staff
/// can manually verify a scan (marked bubbles, unclear/ambiguous marks)
/// against what the decoder actually read. View-only -- never writes back
/// to the image file.
///
/// The image gets the full screen for zoom/pan; the answer key (see
/// [_AnswerKeyPanel]) lives in an end drawer opened via the app bar so it
/// never eats into the viewing area -- blank and flagged (ambiguous) items
/// are highlighted since those are exactly the ones most likely to need a
/// manual look.
///
/// When [rectifiedImagePath] and [template] are both available, a per-item
/// graded overlay (see [_GradedOverlayPainter]) is drawn directly on the
/// sheet: a green ring on a correctly-marked bubble, a red ring on a wrong
/// one plus a yellow ring on the actual correct bubble, and a small
/// check/cross badge beside each item's number -- modeled on a reference
/// screenshot the user shared. This needs the *rectified* (perspective-
/// corrected) image, not the raw photo, since bubble positions are only
/// known as fractions of the flattened page. When either is unavailable
/// (older scans, or rectification failed for this sheet -- see
/// [AppState.rectifiedImagePaths]) this falls back to the plain photo with
/// no overlay, exactly as before.
class ScannedImageViewerScreen extends StatefulWidget {
  /// The original sheet photo, as a file path (an in-session, not-yet
  /// persisted capture) or already-loaded bytes (an archived scan, whose
  /// image is decrypted before this screen ever sees it — see
  /// [BatchRepository.resolveScanImage]). Exactly one must be given.
  final String? imagePath;
  final Uint8List? imageBytes;
  final String title;
  final List<ScoredItem> scoredItems;
  final String? rectifiedImagePath;
  final Uint8List? rectifiedImageBytes;
  final OmrExamTemplate? template;

  /// Which [OmrExamTemplate.templateVersion] this scan was actually
  /// decoded against, and the interior-fiducial mesh-correction readings
  /// from that same decode — see [ScoredResult.templateVersion]/
  /// [ScoredResult.meshInteriorMeasuredFrac]. When [scanTemplateVersion]
  /// doesn't match [template]'s own current version, the overlay skips
  /// the mesh correction rather than applying stale-geometry readings
  /// against a sheet layout that has since changed (see [_hasOverlay]'s
  /// doc comment) — the plain rectified image with no overlay is shown
  /// instead of a possibly-misplaced one.
  final String? scanTemplateVersion;
  final Map<String, (double, double)>? meshInteriorMeasuredFrac;

  /// When given, answers can be corrected from this screen: tap an item's
  /// bubbles/number on the sheet, or its row in the answer-key drawer. The
  /// items shown are then recomputed from the scan's corrected reading after
  /// every change ([scoredItems] is only the starting point). Null = view-only.
  final ScanEditing? editing;

  const ScannedImageViewerScreen({
    super.key,
    this.imagePath,
    this.imageBytes,
    required this.title,
    required this.scoredItems,
    this.rectifiedImagePath,
    this.rectifiedImageBytes,
    this.template,
    this.scanTemplateVersion,
    this.meshInteriorMeasuredFrac,
    this.editing,
  }) : assert(
          imagePath != null || imageBytes != null,
          'ScannedImageViewerScreen needs either imagePath or imageBytes.',
        );

  @override
  State<ScannedImageViewerScreen> createState() => _ScannedImageViewerScreenState();
}

class _ScannedImageViewerScreenState extends State<ScannedImageViewerScreen> {
  late LocalScan? _scan = widget.editing?.scan;

  String? get imagePath => widget.imagePath;
  Uint8List? get imageBytes => widget.imageBytes;
  String get title => widget.title;
  String? get rectifiedImagePath => widget.rectifiedImagePath;
  Uint8List? get rectifiedImageBytes => widget.rectifiedImageBytes;
  OmrExamTemplate? get template => widget.template;
  String? get scanTemplateVersion => widget.scanTemplateVersion;
  ScanEditing? get editing => widget.editing;

  /// Items as they read NOW: recomputed from the detected answers plus this
  /// capture's corrections through the unchanged scorer whenever the screen
  /// can edit; the caller's list otherwise.
  List<ScoredItem> get scoredItems {
    final e = editing;
    final scan = _scan;
    if (e == null || scan == null) return widget.scoredItems;
    return scoreOmrResult(scan.effectiveDecoded, e.answerKey).items;
  }

  /// A correction never moves the bubbles, so the mesh readings the scan was
  /// decoded with stay right for the overlay.
  Map<String, (double, double)>? get meshInteriorMeasuredFrac => widget.meshInteriorMeasuredFrac;

  /// True only when the scan's own recorded template version still
  /// matches [template]'s current one (or the scan predates version
  /// tracking, in which case there's nothing to compare against) — see
  /// [scanTemplateVersion]'s doc comment. A stale scan still gets its
  /// plain rectified image; it just skips the overlay/mesh correction
  /// rather than risk drawing it with coordinates from a sheet layout
  /// that has since changed underneath it.
  OmrExamTemplate? get _overlayTemplate {
    final t = template;
    if (t == null) return null;
    // The layout this scan was captured against (a scan from before version
    // tracking has no version and uses the current one).
    return scanTemplateVersion == null ? t : omrTemplateFor(t.examCode, scanTemplateVersion);
  }

  bool get _templateStillMatches =>
      (scanTemplateVersion == null && template?.examCode != 'TAT') ||
      (scanTemplateVersion != null && scanTemplateVersion == _overlayTemplate?.templateVersion);

  bool get _hasOverlay =>
      (rectifiedImagePath != null || rectifiedImageBytes != null) &&
      template != null &&
      _templateStillMatches &&
      scoredItems.any((i) => i.correctChoice != null);

  Widget _mainImage() => imageBytes != null ? Image.memory(imageBytes!) : Image.file(File(imagePath!));

  Widget _rectifiedImage() =>
      rectifiedImageBytes != null ? Image.memory(rectifiedImageBytes!) : Image.file(File(rectifiedImagePath!));

  bool get _canEdit => editing != null && _scan != null && _overlayTemplate != null;

  Future<void> _openItem(String sectionName, int itemNumber) async {
    final e = editing;
    final scan = _scan;
    final tpl = _overlayTemplate;
    if (e == null || scan == null || tpl == null) return;
    final updated = await editScanItem(
      context,
      editing: e,
      scan: scan,
      template: tpl,
      sectionName: sectionName,
      itemNumber: itemNumber,
      rectifiedBytes: rectifiedImageBytes,
      rectifiedPath: rectifiedImagePath,
    );
    if (updated != null && mounted) setState(() => _scan = updated);
  }

  /// The overlay item whose row (badge, number gutter and bubbles) was tapped.
  void _onOverlayTap(Offset local, Size size) {
    final items = scoredItems;
    final tpl = _overlayTemplate;
    if (tpl == null) return;
    final hit = _GradedOverlayPainter.itemAt(
      point: local,
      size: size,
      items: items,
      template: tpl,
      meshInteriorMeasuredFrac: meshInteriorMeasuredFrac,
    );
    if (hit != null) _openItem(hit.sectionName, hit.itemNumber);
  }

  @override
  Widget build(BuildContext context) {
    final items = scoredItems;
    final corrected = <String>{
      if (_scan != null)
        ...CorrectionRules.activeFor(_scan!.corrections, _scan!.captureRevision).keys,
    };
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(title),
        actions: [
          if (items.isNotEmpty)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.fact_check_outlined),
                tooltip: _canEdit ? 'Answer key and corrections' : 'Answer key',
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: items.isNotEmpty
          ? Drawer(
              backgroundColor: const Color(0xFF111827),
              width: 240,
              child: SafeArea(
                child: _AnswerKeyPanel(
                  items: items,
                  correctedKeys: corrected,
                  onTapItem: _canEdit
                      ? (item) {
                          Navigator.of(context).pop(); // close the drawer
                          _openItem(item.sectionName, item.itemNumber);
                        }
                      : null,
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            if (_hasOverlay) _GradedOverlayLegend(editable: _canEdit),
            Expanded(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 6,
                child: Center(
                  child: _hasOverlay
                      ? Stack(
                          children: [
                            _rectifiedImage(),
                            Positioned.fill(
                              child: LayoutBuilder(
                                builder: (context, box) => GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: _canEdit
                                      ? (d) => _onOverlayTap(d.localPosition, Size(box.maxWidth, box.maxHeight))
                                      : null,
                                  child: CustomPaint(
                                    painter: _GradedOverlayPainter(
                                      items: items,
                                      template: _overlayTemplate!,
                                      meshInteriorMeasuredFrac: meshInteriorMeasuredFrac,
                                      correctedKeys: corrected,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : _mainImage(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small always-visible key for the overlay's colors, so "green/red/yellow"
/// isn't left for staff to guess.
class _GradedOverlayLegend extends StatelessWidget {
  final bool editable;
  const _GradedOverlayLegend({this.editable = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF111827),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _LegendDot(color: Color(0xFF16A34A), label: 'Correct'),
              _LegendDot(color: Color(0xFFDC2626), label: 'Wrong'),
              // The yellow ring is the KEY's answer, never the student's mark.
              _LegendDot(color: Color(0xFFEAB308), label: 'Answer key (not the student’s mark)'),
            ],
          ),
          if (editable) ...[
            const SizedBox(height: 4),
            const Text(
              'Tap a question to correct what was read. Grading follows the answer key.',
              style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Draws the per-item graded overlay directly on the rectified sheet image:
/// a ring on whichever bubble was actually marked (green if it's the right
/// one, red if not), a yellow ring on the correct bubble whenever the mark
/// was wrong/blank/ambiguous, and a small check/cross badge in the label
/// gutter beside each item's printed number.
///
/// Positions are computed purely from [template]'s [BubblePos] fractions
/// against the painter's actual [size] -- the same fractions
/// [OmrDecoder.decode] samples against on the canonical (perspective-
/// corrected) image, which is exactly what [ScannedImageViewerScreen] shows
/// when this is active. Ungraded items (no answer key entry) are skipped.
class _GradedOverlayPainter extends CustomPainter {
  final List<ScoredItem> items;
  final OmrExamTemplate template;

  /// See [ScannedImageViewerScreen.meshInteriorMeasuredFrac] — the exact
  /// same interior-fiducial readings [OmrDecoder.decode] used to sample
  /// bubbles for [items], so this overlay places its rings using the
  /// identical geometric mapping scoring did, rather than assuming the
  /// displayed rectified image is an undistorted 1:1 map of template
  /// fractions (see [OmrMeshCorrection]'s doc comment on why a bent
  /// capture's rectified image can still show real residual bend even
  /// after the primary 4-corner homography).
  final Map<String, (double, double)>? meshInteriorMeasuredFrac;

  /// Items (section|number keys) whose reading was manually corrected; they
  /// get a small blue dot so a corrected result is never mistaken for a
  /// machine-read one.
  final Set<String> correctedKeys;

  const _GradedOverlayPainter({
    required this.items,
    required this.template,
    this.meshInteriorMeasuredFrac,
    this.correctedKeys = const {},
  });

  /// The graded item whose row (number gutter, badge and bubbles) contains
  /// [point], using the same geometry as [paint].
  static ScoredItem? itemAt({
    required Offset point,
    required Size size,
    required List<ScoredItem> items,
    required OmrExamTemplate template,
    Map<String, (double, double)>? meshInteriorMeasuredFrac,
  }) {
    if (template.pageWidthPt <= 0 || template.pageHeightPt <= 0) return null;
    final pxPerPtX = size.width / template.pageWidthPt;
    final pxPerPtY = size.height / template.pageHeightPt;
    final canonicalW = template.pageWidthPt.round();
    final canonicalH = template.pageHeightPt.round();
    final mesh = OmrMeshCorrection.fromMeasuredFractions(
      template: template,
      canonicalWidth: canonicalW,
      canonicalHeight: canonicalH,
      measuredFrac: meshInteriorMeasuredFrac,
    );
    Offset centerOf(BubblePos b) {
      final (cx, cy) = mesh.correct(b.xFrac * canonicalW, b.yFrac * canonicalH);
      return Offset(cx / canonicalW * size.width, cy / canonicalH * size.height);
    }

    final byNumber = <String, Map<int, List<BubblePos>>>{
      for (final section in template.sections) section.name: section.items,
    };
    final halfH = template.bubbleRadiusYPt * 1.5 * pxPerPtY;
    final gutter = (template.bubbleRadiusPt + 16) * pxPerPtX;
    final reach = template.bubbleRadiusPt * 1.5 * pxPerPtX;
    ScoredItem? best;
    var bestDy = double.infinity;
    for (final item in items) {
      final bubbles = byNumber[item.sectionName]?[item.itemNumber];
      if (bubbles == null || bubbles.isEmpty) continue;
      var left = double.infinity, right = -double.infinity, sumY = 0.0;
      for (final b in bubbles) {
        final c = centerOf(b);
        if (c.dx < left) left = c.dx;
        if (c.dx > right) right = c.dx;
        sumY += c.dy;
      }
      final cy = sumY / bubbles.length;
      final dy = (point.dy - cy).abs();
      if (dy > halfH || point.dx < left - gutter || point.dx > right + reach) continue;
      if (dy < bestDy) {
        bestDy = dy;
        best = item;
      }
    }
    return best;
  }

  static const _correctColor = Color(0xFF16A34A);
  static const _wrongColor = Color(0xFFDC2626);
  static const _ambiguousColor = Color(0xFFEAB308);
  static const _keyColor = Color(0xFFEAB308);

  @override
  void paint(Canvas canvas, Size size) {
    if (template.pageWidthPt <= 0 || template.pageHeightPt <= 0) return;
    final pxPerPtX = size.width / template.pageWidthPt;
    final pxPerPtY = size.height / template.pageHeightPt;
    // Keep the review indicator close to the printed oval. The previous
    // 1.8 multiplier made rings overlap adjacent choices and falsely looked
    // like a coordinate error on dense TAT rows.
    final ringRx = template.bubbleRadiusPt * 1.14 * pxPerPtX;
    final ringRy = template.bubbleRadiusYPt * 1.14 * pxPerPtY;
    final strokeWidth = (ringRx < ringRy ? ringRx : ringRy) * 0.3;
    final badgeRadius = (ringRx < ringRy ? ringRx : ringRy) * 0.6;

    final byNumber = <String, Map<int, List<BubblePos>>>{
      for (final section in template.sections) section.name: section.items,
    };

    // Mesh built at page-point scale (1 canonical unit = 1 pt) — the
    // triangulation/barycentric math is scale-invariant, so this is exactly
    // as accurate as decode()'s own canonical-px scale, just avoiding the
    // need to know what pixel resolution originally produced
    // [meshInteriorMeasuredFrac] (it's stored as page fractions already).
    final canonicalW = template.pageWidthPt.round();
    final canonicalH = template.pageHeightPt.round();
    final mesh = OmrMeshCorrection.fromMeasuredFractions(
      template: template,
      canonicalWidth: canonicalW,
      canonicalHeight: canonicalH,
      measuredFrac: meshInteriorMeasuredFrac,
    );

    Offset centerOf(BubblePos b) {
      final (cx, cy) = mesh.correct(b.xFrac * canonicalW, b.yFrac * canonicalH);
      return Offset(cx / canonicalW * size.width, cy / canonicalH * size.height);
    }

    void ring(BubblePos b, Color color) {
      canvas.drawOval(
        Rect.fromCenter(center: centerOf(b), width: ringRx * 2, height: ringRy * 2),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
    }

    void badge(BubblePos leftmost, bool correct, Color color) {
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

    for (final item in items) {
      if (item.correctChoice == null) continue; // ungraded -- nothing to compare against
      final bubbles = byNumber[item.sectionName]?[item.itemNumber];
      if (bubbles == null || bubbles.isEmpty) continue;

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

      if (marked != null) {
        ring(marked, isRight ? _correctColor : _wrongColor);
        if (!isRight && correct != null && correct.choice != marked.choice) {
          ring(correct, _keyColor);
        }
      } else if (correct != null) {
        // Blank or ambiguous -- nothing was confidently marked, so only show
        // where the correct answer was.
        ring(correct, _keyColor);
      }

      var leftmost = bubbles.first;
      for (final b in bubbles) {
        if (b.xFrac < leftmost.xFrac) leftmost = b;
      }
      final badgeColor = isRight ? _correctColor : (item.isAmbiguous ? _ambiguousColor : _wrongColor);
      badge(leftmost, isRight, badgeColor);
      if (correctedKeys.contains('${item.sectionName}|${item.itemNumber}')) {
        final a = centerOf(leftmost);
        canvas.drawCircle(
          Offset(a.dx - (template.bubbleRadiusPt + 9) * pxPerPtX - badgeRadius, a.dy - badgeRadius),
          badgeRadius * 0.45,
          Paint()..color = const Color(0xFF3B82F6),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GradedOverlayPainter oldDelegate) =>
      oldDelegate.items != items ||
      oldDelegate.template != template ||
      oldDelegate.correctedKeys != correctedKeys ||
      oldDelegate.meshInteriorMeasuredFrac != meshInteriorMeasuredFrac;
}

/// Scrollable answer-key list, grouped by section, one row per item.
class _AnswerKeyPanel extends StatelessWidget {
  final List<ScoredItem> items;

  /// Items whose reading was manually corrected, and the tap handler that
  /// opens the correction editor (null = read-only).
  final Set<String> correctedKeys;
  final void Function(ScoredItem item)? onTapItem;

  const _AnswerKeyPanel({required this.items, this.correctedKeys = const {}, this.onTapItem});

  @override
  Widget build(BuildContext context) {
    final bySection = <String, List<ScoredItem>>{};
    for (final item in items) {
      bySection.putIfAbsent(item.sectionName, () => []).add(item);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      children: [
        const Text(
          'ANSWER KEY',
          style: TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.6),
        ),
        const SizedBox(height: 12),
        ...bySection.entries.map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.key,
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                ...entry.value.map(_buildRow),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(ScoredItem item) {
    // Blank and ambiguous (flagged) items are exactly the ones a manual
    // review needs to focus on, so they get a distinct highlight; everything
    // else stays low-key so those two states still stand out at a glance.
    final Color background;
    final Color foreground;
    if (item.isAmbiguous) {
      background = const Color(0xFFFEF3C7);
      foreground = const Color(0xFF92400E);
    } else if (item.isBlank) {
      background = const Color(0xFF374151);
      foreground = Colors.white;
    } else {
      background = Colors.transparent;
      foreground = Colors.white70;
    }

    final wasCorrected = correctedKeys.contains('${item.sectionName}|${item.itemNumber}');
    final read = item.isAmbiguous ? 'multiple' : (item.markedChoice ?? 'blank');
    final row = Container(
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '${item.itemNumber}',
              style: TextStyle(color: foreground, fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              'Key ${item.correctChoice ?? "—"} · read $read',
              style: TextStyle(color: foreground, fontSize: 10, fontWeight: FontWeight.w800),
            ),
          ),
          if (wasCorrected) const Icon(Icons.edit, size: 12, color: Color(0xFF3B82F6)),
          if (item.isAmbiguous)
            const Icon(Icons.warning_amber_rounded, size: 12, color: Color(0xFF92400E))
          else if (item.isBlank)
            const Icon(Icons.remove_circle_outline, size: 12, color: Colors.white70),
        ],
      ),
    );
    final tap = onTapItem;
    if (tap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => tap(item),
      child: row,
    );
  }
}
