import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/omr/omr_scorer.dart';

/// Full-screen viewer for one originally-captured OMR sheet photo, so staff
/// can manually verify a scan (marked bubbles, unclear/ambiguous marks)
/// against what the decoder actually read. View-only -- never writes back
/// to the image file.
///
/// The answer key for this sheet's exam is shown alongside the image (see
/// [_AnswerKeyPanel]) so staff can compare the printed key against the
/// visible marks without leaving this screen -- blank and flagged
/// (ambiguous) items are highlighted since those are exactly the ones most
/// likely to need a manual look.
class ScannedImageViewerScreen extends StatelessWidget {
  final String imagePath;
  final String title;
  final List<ScoredItem> scoredItems;

  const ScannedImageViewerScreen({
    super.key,
    required this.imagePath,
    required this.title,
    required this.scoredItems,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(title),
      ),
      body: SafeArea(
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 6,
                child: Center(
                  child: Image.file(File(imagePath)),
                ),
              ),
            ),
            if (scoredItems.isNotEmpty)
              SizedBox(
                width: 148,
                child: _AnswerKeyPanel(items: scoredItems),
              ),
          ],
        ),
      ),
    );
  }
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

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(left: BorderSide(color: Color(0xFF1F2937))),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        children: [
          const Text(
            'ANSWER KEY',
            style: TextStyle(color: Colors.white70, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6),
          ),
          const SizedBox(height: 10),
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
      ),
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
