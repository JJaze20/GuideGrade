/// The fixed set of exams GuideGrade currently supports. Exam designs are
/// not finalized yet, so this is a hardcoded catalog rather than
/// Firestore-backed CRUD -- see omrTemplates for the matching sheet layouts.
class ExamCatalogEntry {
  final String examCode;
  final String title;
  final String pdfAsset;

  const ExamCatalogEntry({
    required this.examCode,
    required this.title,
    required this.pdfAsset,
  });
}

const List<ExamCatalogEntry> examCatalog = [
  ExamCatalogEntry(examCode: 'AT', title: 'Admission Test', pdfAsset: 'answer_sheets/AT.pdf'),
  ExamCatalogEntry(examCode: 'QTM', title: 'Quantitative Math Test', pdfAsset: 'answer_sheets/QTM.pdf'),
  ExamCatalogEntry(examCode: 'TAT', title: 'Teaching Aptitude Test', pdfAsset: 'answer_sheets/TAT.pdf'),
];
