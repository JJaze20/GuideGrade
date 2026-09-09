import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';

/// Preview -> Print / Export PDF for one exam's documents.
///
/// Two documents exist per exam and are genuinely different things: the
/// [ExamCatalogEntry.pdfAsset] OMR bubble sheet examinees mark and staff
/// scan, and the [ExamCatalogEntry.questionnairePdfAsset] question booklet
/// examinees actually read. A bottom nav bar switches which one is loaded
/// into the same [PdfPreview] (pinch-zoom, print, share/export -- all free
/// from that widget, no custom viewer code needed for either document).
/// Falls back to showing only the answer sheet, nav bar hidden, for an exam
/// with no questionnaire on file yet ([ExamCatalogEntry.questionnairePdfAsset]
/// null).
class ExamSheetPreviewScreen extends StatefulWidget {
  final ExamCatalogEntry entry;

  const ExamSheetPreviewScreen({super.key, required this.entry});

  @override
  State<ExamSheetPreviewScreen> createState() => _ExamSheetPreviewScreenState();
}

enum _ExamDocument { answerSheet, questionnaire }

class _ExamSheetPreviewScreenState extends State<ExamSheetPreviewScreen> {
  _ExamDocument _selected = _ExamDocument.answerSheet;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final hasQuestionnaire = entry.questionnairePdfAsset != null;
    final asset = _selected == _ExamDocument.questionnaire && hasQuestionnaire
        ? entry.questionnairePdfAsset!
        : entry.pdfAsset;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text(entry.title, style: AppTextStyles.heading(size: 13)),
      ),
      body: PdfPreview(
        // Keyed per document so switching tabs is treated as a brand new
        // PdfPreview instance -- guarantees `build` re-runs against the
        // newly selected asset rather than however PdfPreview would
        // otherwise decide whether its old, already-loaded bytes are still
        // valid.
        key: ValueKey(asset),
        build: (format) async {
          final bytes = await rootBundle.load(asset);
          return bytes.buffer.asUint8List();
        },
        pdfFileName: '${entry.examCode}_${_selected.name}.pdf',
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
      ),
      bottomNavigationBar: hasQuestionnaire
          ? NavigationBar(
              selectedIndex: _ExamDocument.values.indexOf(_selected),
              onDestinationSelected: (i) => setState(() => _selected = _ExamDocument.values[i]),
              destinations: const [
                NavigationDestination(
                  icon: FaIcon(FontAwesomeIcons.tableCells, size: 18),
                  label: 'Answer Sheet',
                ),
                NavigationDestination(
                  icon: FaIcon(FontAwesomeIcons.bookOpen, size: 18),
                  label: 'Questionnaire',
                ),
              ],
            )
          : null,
    );
  }
}
