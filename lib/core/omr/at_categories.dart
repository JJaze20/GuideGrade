import '../../models/answer_key.dart';
import 'omr_scorer.dart';

/// The four Admission Test (OLSAT) subtests an item can belong to, and the
/// raw score per subtest for one scanned sheet. Pure, no I/O.
///
/// The categories are interleaved through items 1-72 (not contiguous
/// ranges), so each item's category comes from the answer key
/// ([AnswerKey.itemCategories]), falling back to [officialAtCategories] --
/// the OLSAT Levels E/F/G Forms 3/4 hand-scoring overlay keys -- for any
/// item the key has not recorded.
enum AtCategory {
  vc('VC', 'Verbal Comprehension'),
  vr('VR', 'Verbal Reasoning'),
  fr('FR', 'Figural Reasoning'),
  qr('QR', 'Quantitative Reasoning');

  const AtCategory(this.code, this.label);

  final String code;
  final String label;

  bool get isVerbal => this == vc || this == vr;

  static AtCategory? fromCode(String? code) {
    for (final c in values) {
      if (c.code == code) return c;
    }
    return null;
  }
}

/// Official item -> subtest mapping (OLSAT 7th ed., Levels E/F/G, Forms
/// 3/4): VC 12, VR 24, FR 18, QR 18 items.
const Map<int, AtCategory> officialAtCategories = {
  1: AtCategory.vc, 2: AtCategory.vr, 3: AtCategory.qr, 4: AtCategory.fr,
  5: AtCategory.vr, 6: AtCategory.vc, 7: AtCategory.qr, 8: AtCategory.fr,
  9: AtCategory.qr, 10: AtCategory.vc, 11: AtCategory.vr, 12: AtCategory.fr,
  13: AtCategory.vr, 14: AtCategory.vr, 15: AtCategory.vc, 16: AtCategory.qr,
  17: AtCategory.qr, 18: AtCategory.vc, 19: AtCategory.fr, 20: AtCategory.vr,
  21: AtCategory.vr, 22: AtCategory.fr, 23: AtCategory.qr, 24: AtCategory.vr,
  25: AtCategory.vr, 26: AtCategory.qr, 27: AtCategory.vc, 28: AtCategory.vc,
  29: AtCategory.fr, 30: AtCategory.qr, 31: AtCategory.fr, 32: AtCategory.fr,
  33: AtCategory.vr, 34: AtCategory.vr, 35: AtCategory.vc, 36: AtCategory.qr,
  37: AtCategory.vr, 38: AtCategory.vr, 39: AtCategory.qr, 40: AtCategory.vr,
  41: AtCategory.fr, 42: AtCategory.qr, 43: AtCategory.fr, 44: AtCategory.qr,
  45: AtCategory.vr, 46: AtCategory.vr, 47: AtCategory.qr, 48: AtCategory.fr,
  49: AtCategory.qr, 50: AtCategory.vr, 51: AtCategory.qr, 52: AtCategory.vr,
  53: AtCategory.vr, 54: AtCategory.fr, 55: AtCategory.vc, 56: AtCategory.fr,
  57: AtCategory.vc, 58: AtCategory.vr, 59: AtCategory.fr, 60: AtCategory.qr,
  61: AtCategory.vr, 62: AtCategory.vc, 63: AtCategory.fr, 64: AtCategory.qr,
  65: AtCategory.vr, 66: AtCategory.fr, 67: AtCategory.vr, 68: AtCategory.fr,
  69: AtCategory.qr, 70: AtCategory.fr, 71: AtCategory.vr, 72: AtCategory.vc,
};

/// The category of one AT item: the answer key's own entry when it has
/// one, otherwise the official mapping.
AtCategory? atCategoryFor(AnswerKey? key, String sectionName, int itemNumber) =>
    AtCategory.fromCode(key?.categoryFor(sectionName, itemNumber)) ??
    officialAtCategories[itemNumber];

class AtCategoryScore {
  final AtCategory category;
  final int right;
  final int total;
  const AtCategoryScore(this.category, this.right, this.total);
}

/// Raw scores per subtest, plus the Verbal (VC + VR) and Non-Verbal
/// (FR + QR) subtotals written under them on the paper answer document.
class AtCategoryScores {
  final Map<AtCategory, AtCategoryScore> byCategory;
  const AtCategoryScores(this.byCategory);

  AtCategoryScore scoreOf(AtCategory c) => byCategory[c] ?? AtCategoryScore(c, 0, 0);

  int _sum(bool Function(AtCategory) test, int Function(AtCategoryScore) f) =>
      byCategory.values.where((s) => test(s.category)).fold(0, (a, s) => a + f(s));

  int get verbalRight => _sum((c) => c.isVerbal, (s) => s.right);
  int get verbalTotal => _sum((c) => c.isVerbal, (s) => s.total);
  int get nonVerbalRight => _sum((c) => !c.isVerbal, (s) => s.right);
  int get nonVerbalTotal => _sum((c) => !c.isVerbal, (s) => s.total);
  int get totalRight => verbalRight + nonVerbalRight;
  int get totalItems => verbalTotal + nonVerbalTotal;
}

/// Per-subtest raw scores for one AT sheet's [items], or null when nothing
/// is graded (no answer key). Only graded items (an answer-key choice
/// exists) count toward a category's total.
AtCategoryScores? computeAtCategoryScores(List<ScoredItem> items, AnswerKey? key) {
  final right = {for (final c in AtCategory.values) c: 0};
  final total = {for (final c in AtCategory.values) c: 0};
  var graded = 0;
  for (final item in items) {
    if (item.correctChoice == null) continue;
    final c = atCategoryFor(key, item.sectionName, item.itemNumber);
    if (c == null) continue;
    graded++;
    total[c] = total[c]! + 1;
    if (item.isCorrect == true) right[c] = right[c]! + 1;
  }
  if (graded == 0) return null;
  return AtCategoryScores({
    for (final c in AtCategory.values) c: AtCategoryScore(c, right[c]!, total[c]!),
  });
}
