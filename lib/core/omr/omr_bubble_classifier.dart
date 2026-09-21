import 'dart:math' as math;

/// One bubble's measurements, as the decoder already computes them.
class BubbleScores {
  final String choice;
  final double ring;
  final double whole;
  final double center;
  final double score;

  const BubbleScores({
    required this.choice,
    required this.ring,
    required this.whole,
    required this.center,
    required this.score,
  });
}

/// What the model concluded about one item.
class BubbleVerdict {
  final String? markedChoice;
  final bool isAmbiguous;

  const BubbleVerdict(this.markedChoice, this.isAmbiguous);
}

/// Logistic regression over per-bubble features, replacing the hand-tuned
/// fill/gap thresholds with a fitted decision.
///
/// Measurement is untouched -- the same ring/whole/centre/score numbers go in.
/// Only the marked/ambiguous/blank verdict changes, which is the part the
/// thresholds were guessing at.
///
/// EVERY FEATURE IS RELATIVE, to the item or to the sheet. None is absolute.
/// Measured across real captures, a BLANK bubble's fill ranged 0.18 to 0.46
/// depending on exposure and print -- one sheet's blanks read higher than
/// another's marks -- so a model given absolute values would learn the
/// training captures' lighting and collapse on a new camera.
///
/// The weights below were fitted in the PHP bench (guidegrade-omr-bench) on
/// the feature subset this decoder can supply: it has no per-bubble darkness
/// sampler, so the three darkness features the bench also offers are excluded
/// rather than fed as zeros. On the curled-sheet benchmark this subset scored
/// 99.81% against 98.65% for the thresholds, with no silent errors -- the same
/// as the full-feature model.
class OmrBubbleClassifier {
  /// Flip to false to fall back to the threshold decision.
  static const bool enabled = true;

  /// Order matters: these line up with [_featureVector].
  static const List<double> _weights = <double>[
    1.3497170060, // scoreRelItem
    2.0845441083, // scoreRelBest
    1.0167256504, // scoreRelSheet
    1.0698163241, // ringRelItem
    2.0110768935, // centerRelItem
    -1.0439037672, // choiceCount
  ];

  static const double _bias = 0.29792150167138;

  /// Probability above which a bubble counts as marked.
  static const double markThreshold = 0.5;

  /// Two choices within this probability of each other are a double mark.
  static const double ambiguousMargin = 0.15;

  static double _sigmoid(double z) {
    final clamped = z < -60.0 ? -60.0 : (z > 60.0 ? 60.0 : z);
    return 1.0 / (1.0 + math.exp(-clamped));
  }

  /// Median bubble score across the whole sheet.
  ///
  /// Most bubbles on any sheet are unmarked, so the median is a robust stand-in
  /// for "what blank looks like on this particular capture" -- which is what
  /// makes `scoreRelSheet` exposure-independent.
  static double sheetMedianScore(List<List<BubbleScores>> sheet) {
    final all = <double>[];
    for (final item in sheet) {
      for (final bubble in item) {
        all.add(bubble.score);
      }
    }
    if (all.isEmpty) return 0.0;
    all.sort();
    return all[all.length ~/ 2];
  }

  static List<double> _featureVector(
    int index,
    List<BubbleScores> choices,
    double minScore,
    double minRing,
    double minCenter,
    double medianScore,
  ) {
    final bubble = choices[index];

    // Strongest of the OTHER choices, which is what this bubble competes with.
    // Excluded by position, not by identity: two choices on one item can hold
    // numerically identical measurements, and comparing instances would then
    // drop the wrong one.
    var bestOther = 0.0;
    var sawOther = false;
    for (var i = 0; i < choices.length; i++) {
      if (i == index) continue;
      if (!sawOther || choices[i].score > bestOther) {
        bestOther = choices[i].score;
        sawOther = true;
      }
    }

    return <double>[
      bubble.score - minScore,
      bubble.score - bestOther,
      bubble.score - medianScore,
      bubble.ring - minRing,
      bubble.center - minCenter,
      choices.length / 4.0,
    ];
  }

  static double _predict(List<double> features) {
    var z = _bias;
    final n = features.length < _weights.length ? features.length : _weights.length;
    for (var i = 0; i < n; i++) {
      z += _weights[i] * features[i];
    }
    return _sigmoid(z);
  }

  /// Decides one item from its bubbles' measurements.
  static BubbleVerdict classify(
    List<BubbleScores> choices,
    double medianScore,
  ) {
    if (choices.isEmpty) return const BubbleVerdict(null, false);

    var minScore = choices[0].score;
    var minRing = choices[0].ring;
    var minCenter = choices[0].center;
    for (final bubble in choices) {
      if (bubble.score < minScore) minScore = bubble.score;
      if (bubble.ring < minRing) minRing = bubble.ring;
      if (bubble.center < minCenter) minCenter = bubble.center;
    }

    var bestProb = -1.0;
    var runnerProb = -1.0;
    String? bestChoice;

    for (var i = 0; i < choices.length; i++) {
      final p = _predict(_featureVector(
        i,
        choices,
        minScore,
        minRing,
        minCenter,
        medianScore,
      ));
      if (p > bestProb) {
        runnerProb = bestProb;
        bestProb = p;
        bestChoice = choices[i].choice;
      } else if (p > runnerProb) {
        runnerProb = p;
      }
    }

    if (runnerProb < 0.0) runnerProb = 0.0;

    final hasSomething = bestProb >= markThreshold;
    final isAmbiguous = hasSomething && (bestProb - runnerProb) < ambiguousMargin;

    return BubbleVerdict(
      hasSomething && !isAmbiguous ? bestChoice : null,
      isAmbiguous,
    );
  }
}
