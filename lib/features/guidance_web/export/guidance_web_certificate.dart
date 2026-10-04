import '../../../core/omr/admission_category.dart';
import '../../../core/omr/qtm_category.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../core/omr/tat_category.dart';
import '../../../core/omr/tat_result.dart';
import 'guidance_web_certificate_data.dart';

/// Category certificates: which certificate an examinee gets, from their exam
/// type and recorded score, and its printable content. Pure — no Flutter, no
/// network — so it can be tested and reused by the PDF builder.

/// One line in a certificate's course list: a course, or a sub-heading such as
/// `C.2 (30%):` that groups the courses beneath it.
class CertEntry {
  const CertEntry(this.text, {this.isHeading = false});
  final String text;
  final bool isHeading;
}

class CertificateCategory {
  const CertificateCategory({required this.range, required this.columns});

  /// e.g. `(85% – 89%)`, printed after `TEST RESULT: CATEGORY C`.
  final String range;

  /// The course list as the council's template lays it out, column by column.
  final List<List<CertEntry>> columns;
}

class CertificateSpec {
  const CertificateSpec({
    required this.intro,
    required this.verb,
    required this.categories,
  });

  /// "You have successfully passed the … of the Notre Dame of Marbel
  /// University."
  final String intro;

  /// `take the` (AT, QTM) or `teach` (TAT) in "you are qualified to … ANY of
  /// the following courses".
  final String verb;
  final Map<String, CertificateCategory> categories;
}

/// A certificate ready to print for one examinee.
class ExportCertificate {
  const ExportCertificate({
    required this.examCode,
    required this.intro,
    required this.verb,
    required this.letter,
    required this.rangeLabel,
    required this.name,
    required this.columns,
  });

  final String examCode;
  final String intro;
  final String verb;

  /// `A` – `D`.
  final String letter;
  final String rangeLabel;

  /// Printed as given ("LAST, FIRST M." upper-cased by [buildCertificate]).
  /// Empty for a scan with no name: the PDF then prints a blank line to write
  /// the name on.
  final String name;
  final List<List<CertEntry>> columns;
}

String? _letterFor(String examCode, int raw) => switch (examCode) {
  'AT' => admissionCategory(raw)?.name.toUpperCase(),
  'QTM' => qtmCategory(raw)?.name.toUpperCase(),
  'TAT' => tatCategory(raw)?.name.toUpperCase(),
  _ => null,
};

/// Whether the courses under a `C.2` / `D.2` heading apply to [raw]:
///  * QTM `C.2 (30%)` (Computer Science) needs 18+, `D.2 (25%)` needs 15+;
///  * TAT `C.2 (30%)` needs 48+ (30% of 160).
/// These are the existing QTM / TAT eligibility rules, never new cutoffs.
bool _groupApplies(String examCode, String heading, int raw) {
  final isC2 = heading.startsWith('C.2');
  if (examCode == 'QTM') {
    final e = qtmEligibility(raw);
    if (isC2) return e == QtmEligibility.allCoursesIncludingBscs;
    return e == QtmEligibility.allCoursesIncludingBscs ||
        e == QtmEligibility.allCoursesExceptBscs;
  }
  if (examCode == 'TAT') {
    return tatEligibility(raw) == TatEligibility.meetsRequirement;
  }
  return true;
}

List<List<CertEntry>> _filterColumns(
  String examCode,
  List<List<CertEntry>> columns,
  int raw,
) {
  final out = <List<CertEntry>>[];
  for (final col in columns) {
    final kept = <CertEntry>[];
    var skipping = false;
    for (final e in col) {
      if (e.isHeading) {
        skipping = !_groupApplies(examCode, e.text, raw);
        if (!skipping) kept.add(e);
      } else if (!skipping) {
        kept.add(e);
      }
    }
    if (kept.isNotEmpty) out.add(kept);
  }
  return out;
}

/// The certificate for a scan, or null when none is issued:
///  * not graded, or
///  * the recorded score falls in an unclassified gap (QTM 46–47,
///    TAT 122–127) — the templates define no certificate for it.
///
/// A scan with no name (untagged, or a tag with blank names) still gets its
/// certificate; [ExportCertificate.name] is then empty and a blank line is
/// printed for the name to be written in.
///
/// Courses under `C.2` / `D.2` headings are printed only when the score meets
/// that threshold ([_groupApplies]); other courses are always printed.
ExportCertificate? buildCertificate({
  required String examCode,
  required int? rawScore,
  required String? status,
  required String? name,
}) {
  final trimmed = name?.trim() ?? '';
  final printedName = trimmed == 'Unnamed' ? '' : trimmed;
  if (rawScore == null || status != 'Graded') return null;
  final spec = certificateSpecs[examCode];
  if (spec == null) return null;
  final letter = _letterFor(examCode, rawScore);
  if (letter == null) return null;
  final category = spec.categories[letter];
  if (category == null) return null;
  return ExportCertificate(
    examCode: examCode,
    intro: spec.intro,
    verb: spec.verb,
    letter: letter,
    rangeLabel: category.range,
    name: printedName.toUpperCase(),
    columns: _filterColumns(examCode, category.columns, rawScore),
  );
}
