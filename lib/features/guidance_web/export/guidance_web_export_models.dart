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
  });

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
    required this.scanDate,
    required this.score,
    required this.percentage,
    required this.clusterRows,
    required this.categoryBands,
    required this.categoryLetter,
    this.certificate,
  });

  final String examLabel;
  final String batchLabel;
  final String examineeId;
  final String firstName;
  final String middleName;
  final String lastName;
  final String age;
  final String scanDate;
  final String score;
  final String percentage;

  /// Null for exams without cluster analysis (TAT): the section is omitted.
  final List<ClusterRow>? clusterRows;

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
