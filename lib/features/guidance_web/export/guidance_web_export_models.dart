import '../../../core/omr/cluster_analysis.dart';
import 'guidance_web_certificate.dart';

/// Plain data for the exported PDF — everything already formatted as it will
/// be printed, so the PDF builder itself does no scoring or lookups.

class ExportBar {
  const ExportBar(this.label, this.count);
  final String label;
  final int count;
}

/// One category row in the printed "Category" list (D on top, A at the
/// bottom, as in the template).
class ExportCategoryBand {
  const ExportCategoryBand(this.letter, this.range, [this.percentLabel]);
  final String letter;
  final String range;
  final String? percentLabel;
}

/// One Admission Test subtest's batch average, as printed in the batch
/// summary: [average] right out of [total] items.
class ExportSubtestAverage {
  const ExportSubtestAverage(this.label, this.average, this.total);
  final String label;
  final double average;
  final int total;
}

/// Page 1: the batch's Batch Analytics.
class ExportBatchSection {
  const ExportBatchSection({
    required this.examLabel,
    required this.batchLabel,
    required this.batchDate,
    required this.stats,
    required this.scoreBars,
    required this.categoryBars,
    this.unavailableNote,
    this.subtestAverages,
    this.subtestExamineeCount = 0,
  });

  /// AT only: average per subtest, or null when the answer key or any
  /// analyzable examinee is missing -- the section is then left out.
  final List<ExportSubtestAverage>? subtestAverages;
  final int subtestExamineeCount;

  final String examLabel;
  final String batchLabel;

  /// The batch's date as printed, e.g. `September 24, 2026`.
  final String batchDate;

  /// (label, value) in template order: Total, Graded, Ungraded, Average,
  /// Highest, Lowest, Median.
  final List<(String, String)> stats;
  final List<ExportBar> scoreBars;
  final List<ExportBar> categoryBars;

  /// Set when the batch's statistics could not be computed (e.g. incomplete
  /// scan data); printed instead of fabricated numbers.
  final String? unavailableNote;
}

/// One printed row of the scaled-score table: raw score, scaled score and SAI
/// for one of Total / Verbal / Nonverbal, already formatted ('-' when not
/// given).
class ExportScoreRow {
  const ExportScoreRow({
    required this.label,
    required this.raw,
    required this.scaled,
    required this.sai,
  });
  final String label;
  final String raw;
  final String scaled;
  final String sai;
}

/// The Admission Test "Scaled Score and School Ability Index (SAI)" block of
/// an examinee page: the three rows plus the lines that say how they were
/// reached or why the SAI is missing.
class ExportScaledScores {
  const ExportScaledScores({
    required this.rows,
    this.basis,
    this.dates,
    this.note,
  });
  final List<ExportScoreRow> rows;

  /// "Age on the exam date: 18 years 8 months - Table 24, 6-8 months".
  final String? basis;

  /// "Born February 5, 2008 - Exam November 1, 2026".
  final String? dates;

  /// Why the SAI is not given, or the raw-score-0 remark.
  final String? note;
}

/// One page per examinee: Examinee Analytics.
class ExportExamineeSection {
  const ExportExamineeSection({
    required this.examLabel,
    required this.batchLabel,
    required this.examineeId,
    required this.firstName,
    required this.middleName,
    required this.lastName,
    required this.age,
    this.sex = '-',
    this.lastSchool = '-',
    this.examDate,
    this.scaledScores,
    required this.scanDate,
    required this.score,
    required this.percentage,
    required this.clusterRows,
    required this.categoryBands,
    required this.categoryLetter,
    this.certificate,
    this.clusterNote,
  });

  final String examLabel;
  final String batchLabel;
  final String examineeId;
  final String firstName;
  final String middleName;
  final String lastName;
  final String age;

  /// Sex and last school attended as entered on the Examinee Record, or '-'.
  final String sex;
  final String lastSchool;

  /// The day this Admission Test sitting was taken, or '-' when not entered;
  /// null for other exams (the row is then not printed).
  final String? examDate;

  /// Admission Test only; null for other exams or when nothing was graded.
  final ExportScaledScores? scaledScores;
  final String scanDate;
  final String score;
  final String percentage;

  /// Null for exams without cluster analysis: the section is omitted.
  final List<ClusterRow>? clusterRows;

  final String? clusterNote;

  /// D first, A last.
  final List<ExportCategoryBand> categoryBands;

  /// The examinee's letter, or null when unclassified / not graded.
  final String? categoryLetter;

  /// Printed on its own landscape page right after this examinee's analytics
  /// page; null when certificates are off or none is issued for this scan.
  final ExportCertificate? certificate;
}

class ExportDocument {
  const ExportDocument({this.batch, this.examinees = const []});

  final ExportBatchSection? batch;
  final List<ExportExamineeSection> examinees;

  bool get isEmpty => batch == null && examinees.isEmpty;
}
