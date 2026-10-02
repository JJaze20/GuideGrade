import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';

/// Preview -> Print PDF for one exam's documents.
///
/// Two documents exist per exam and are genuinely different things: the
/// [ExamCatalogEntry.pdfAsset] OMR bubble sheet examinees mark and staff
/// scan, and the [ExamCatalogEntry.questionnairePdfAsset] question booklet
/// examinees actually read. A bottom nav bar switches which one is loaded
/// into the same [PdfPreview] (pinch-zoom, free from that widget with no
/// custom viewer code needed for either document). Falls back to showing
/// only the answer sheet, nav bar hidden, for an exam with no questionnaire
/// on file yet ([ExamCatalogEntry.questionnairePdfAsset] null).
///
/// [PdfPreview]'s own built-in action row is turned off entirely
/// (`allowSharing`/`allowPrinting: false` -- sharing isn't offered at all,
/// there's no case for handing a confidential exam paper off to another
/// app) in favor of a single print action placed in the app bar's top-right
/// corner instead, calling [Printing.layoutPdf] directly against whichever
/// document is currently selected.
class ExamSheetPreviewScreen extends StatefulWidget {
  final ExamCatalogEntry entry;

  const ExamSheetPreviewScreen({super.key, required this.entry});

  @override
  State<ExamSheetPreviewScreen> createState() => _ExamSheetPreviewScreenState();
}

enum _ExamDocument { answerSheet, questionnaire }

class _ExamSheetPreviewScreenState extends State<ExamSheetPreviewScreen> {
  _ExamDocument _selected = _ExamDocument.answerSheet;

  Future<Uint8List> _loadBytes(String asset, PdfPageFormat format) async {
    final bytes = await rootBundle.load(asset);
    return bytes.buffer.asUint8List();
  }

  Future<void> _print(String asset, String fileName) async {
    try {
      await Printing.layoutPdf(
        onLayout: (format) => _loadBytes(asset, format),
        name: fileName,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not print: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final hasQuestionnaire = entry.questionnairePdfAsset != null;
    final asset = _selected == _ExamDocument.questionnaire && hasQuestionnaire
        ? entry.questionnairePdfAsset!
        : entry.pdfAsset;
    final fileName = '${entry.examCode}_${_selected.name}.pdf';

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text(entry.title, style: AppTextStyles.heading(size: 13)),
        actions: [
          IconButton(
            onPressed: () => _print(asset, fileName),
            icon: const FaIcon(FontAwesomeIcons.print, size: 18, color: AppColors.primaryGreen),
            tooltip: 'Print',
          ),
        ],
      ),
      body: PdfPreview(
        // Keyed per document so switching tabs is treated as a brand new
        // PdfPreview instance -- guarantees `build` re-runs against the
        // newly selected asset rather than however PdfPreview would
        // otherwise decide whether its old, already-loaded bytes are still
        // valid.
        key: ValueKey(asset),
        build: (format) => _loadBytes(asset, format),
        pdfFileName: fileName,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        // Both off -- sharing is never offered (see the class doc comment)
        // and print now lives as its own action in the app bar's top-right
        // corner instead of PdfPreview's own built-in action row.
        allowSharing: false,
        allowPrinting: false,
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
