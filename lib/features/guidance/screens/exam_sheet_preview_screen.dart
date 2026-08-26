import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';

/// Preview -> Print / Export PDF for one exam's official answer sheet.
///
/// Loads the pre-generated sheet from [ExamCatalogEntry.pdfAsset] (bundled
/// via pubspec.yaml's `answer_sheets/` asset entry) and hands it to
/// [PdfPreview], which provides pinch-zoom, a print action, and a
/// share/export-PDF action without any custom viewer code.
class ExamSheetPreviewScreen extends StatelessWidget {
  final ExamCatalogEntry entry;

  const ExamSheetPreviewScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text(entry.title, style: AppTextStyles.heading(size: 13)),
      ),
      body: PdfPreview(
        build: (format) async {
          final bytes = await rootBundle.load(entry.pdfAsset);
          return bytes.buffer.asUint8List();
        },
        pdfFileName: '${entry.examCode}.pdf',
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
      ),
    );
  }
}
