import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/omr_templates.dart';

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
class ScannedImageViewerScreen extends StatelessWidget {
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

  const ScannedImageViewerScreen({
    super.key,
    this.imagePath,
    this.imageBytes,
    required this.title,
    required this.scoredItems,
    this.rectifiedImagePath,
    this.rectifiedImageBytes,
    this.template,
  }) : assert(
          imagePath != null || imageBytes != null,
          'ScannedImageViewerScreen needs either imagePath or imageBytes.',
        );

  bool get _hasOverlay =>
      (rectifiedImagePath != null || rectifiedImageBytes != null) &&
      template != null &&
      scoredItems.any((i) => i.correctChoice != null);

  Widget _mainImage() => imageBytes != null ? Image.memory(imageBytes!) : Image.file(File(imagePath!));

  Widget _rectifiedImage() =>
      rectifiedImageBytes != null ? Image.memory(rectifiedImageBytes!) : Image.file(File(rectifiedImagePath!));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(title),
        actions: [
          if (scoredItems.isNotEmpty)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.fact_check_outlined),
                tooltip: 'Answer key',
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: scoredItems.isNotEmpty
          ? Drawer(
              backgroundColor: const Color(0xFF111827),
              width: 220,
              child: SafeArea(child: _AnswerKeyPanel(items: scoredItems)),
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            if (_hasOverlay) const _GradedOverlayLegend(),
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
                              child: CustomPaint(
                                painter: _GradedOverlayPainter(
                                  items: scoredItems,
                                  template: template!,
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
  const _GradedOverlayLegend();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF111827),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: const [
          _LegendDot(color: Color(0xFF16A34A), label: 'Correct'),
          _LegendDot(color: Color(0xFFDC2626), label: 'Wrong'),
          _LegendDot(color: Color(0xFFEAB308), label: 'Correct answer'),
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

  const _GradedOverlayPainter({required this.items, required this.template});

  static const _correctColor = Color(0xFF16A34A);
  static const _wrongColor = Color(0xFFDC2626);
  static const _ambiguousColor = Color(0xFFEAB308);
  static const _keyColor = Color(0xFFEAB308);

  @override
  void paint(Canvas canvas, Size size) {
    if (template.pageWidthPt <= 0 || template.pageHeightPt <= 0) return;
    final pxPerPtX = size.width / template.pageWidthPt;
    final pxPerPtY = size.height / template.pageHeightPt;
    final ringRx = template.bubbleRadiusPt * 1.8 * pxPerPtX;
    final ringRy = template.bubbleRadiusYPt * 1.8 * pxPerPtY;
    final strokeWidth = (ringRx < ringRy ? ringRx : ringRy) * 0.3;
    final badgeRadius = (ringRx < ringRy ? ringRx : ringRy) * 0.6;

    final byNumber = <String, Map<int, List<BubblePos>>>{
      for (final section in template.sections) section.name: section.items,
    };

    Offset centerOf(BubblePos b) => Offset(b.xFrac * size.width, b.yFrac * size.height);

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
      final center = Offset(
        leftmost.xFrac * size.width - (template.bubbleRadiusPt + 9) * pxPerPtX,
        leftmost.yFrac * size.height,
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
    }
  }

  @override
  bool shouldRepaint(covariant _GradedOverlayPainter oldDelegate) =>
      oldDelegate.items != items || oldDelegate.template != template;
}

/// Scrollable answer-key list, grouped by section, one row per item.
class _AnswerKeyPanel extends StatelessWidget {
  final List<ScoredItem> items;

  const _AnswerKeyPanel({required this.items});

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

    return Container(
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
              item.correctChoice ?? '—',
              style: TextStyle(color: foreground, fontSize: 10, fontWeight: FontWeight.w800),
            ),
          ),
          if (item.isAmbiguous)
            const Icon(Icons.warning_amber_rounded, size: 12, color: Color(0xFF92400E))
          else if (item.isBlank)
            const Icon(Icons.remove_circle_outline, size: 12, color: Colors.white70),
        ],
      ),
    );
  }
}
