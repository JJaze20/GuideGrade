import 'dart:convert';
import 'dart:typed_data';

import '../../models/answer_correction.dart';
import '../../models/omr_scan_result.dart';
import '../services/deepseek_vision_service.dart';

/// Breaks the ties the deterministic decoder deliberately left open, using a
/// vision model ("Force Scan" mode).
///
/// This COMPLEMENTS the OMR read; it never replaces it. The decoder stays the
/// reader of record, and three rules keep it that way:
///
///  * the model is only ever asked about items the decoder itself flagged --
///    two bubbles too close to call, and (opt-in) an item that read as blank.
///    It is never asked about an item that was read confidently, so it can
///    never silently overwrite a resolved answer;
///  * its answer comes back as an ordinary [CorrectedAnswer], so it enters the
///    scan's append-only correction history exactly like a counselor's manual
///    correction: the machine-detected value is preserved beside it, the change
///    is attributable and reversible, and the unchanged exam-specific scoring
///    rules re-grade it. Nothing about the decode itself is edited;
///  * a verdict for any item the model was not asked about is discarded --
///    a model answering about questions nobody posed is not evidence.
///
/// [buildPrompt] and [parseVerdicts] are pure and static on purpose: the whole
/// contract with the model is testable without a network call or a key.
class OmrVisionAdjudicator {
  OmrVisionAdjudicator({DeepSeekVisionService? service})
      : _service = service ?? DeepSeekVisionService();

  final DeepSeekVisionService _service;

  /// False when no API key was supplied at build time. Callers should hide the
  /// feature entirely rather than offer a button that can only fail.
  bool get isAvailable => _service.isConfigured;

  /// Headroom for the reply. The answer itself is a short JSON object, but a
  /// reasoning model spends tokens before it emits one.
  static const int _maxTokens = 1024;

  /// Asks the model about every unresolved item on one decoded sheet and
  /// returns only the verdicts it can actually use.
  ///
  /// The returned map is keyed by [AnswerCorrection.keyFor], so a caller can
  /// look each verdict up by walking the sheet's own items -- numbers repeat
  /// across TAT's sections, which is why the section is part of the key.
  ///
  /// Empty when the sheet has nothing unresolved, which is the common case and
  /// costs nothing. Throws [DeepSeekVisionException] when the request itself
  /// fails; a reply that cannot be parsed is not an error, just no verdicts.
  Future<Map<String, CorrectedAnswer>> adjudicate({
    required OmrScanResult result,
    required Uint8List imageBytes,
    bool includeBlanks = false,
  }) async {
    final flagged = unresolvedItems(result, includeBlanks: includeBlanks);
    if (flagged.isEmpty) return const <String, CorrectedAnswer>{};

    final reply = await _service.askAboutImage(
      imageBytes: imageBytes,
      prompt: buildPrompt(flagged),
      maxTokens: _maxTokens,
    );
    return parseVerdicts(reply, asked: flagged);
  }

  /// The items worth asking about, in sheet order.
  ///
  /// Ambiguous items always qualify: two bubbles too close to call is exactly
  /// the reading the decoder is saying it could not finish. Blanks qualify
  /// only when the caller asks, because a genuinely unanswered question and a
  /// bubble the decoder missed look identical to it -- on a sheet that passed
  /// the blank-rate check they are almost always genuinely unanswered, and
  /// asking about all of them would spend money to be told "nothing there".
  static List<OmrItemResult> unresolvedItems(
    OmrScanResult result, {
    bool includeBlanks = false,
  }) =>
      [
        for (final item in result.items)
          if (item.isAmbiguous || (includeBlanks && item.isBlank)) item,
      ];

  /// The prompt for one sheet. Lists only the flagged items, so the model's
  /// job is bounded to the questions actually in doubt.
  static String buildPrompt(List<OmrItemResult> flagged) {
    final lines = [
      for (final item in flagged)
        '- section "${item.sectionName}", item ${item.itemNumber}'
            ' (${item.isAmbiguous ? 'two bubbles too close to call' : 'nothing read'})',
    ];
    return [
      'A scanner has photographed one answer sheet from a multiple-choice exam.',
      'Most answers were read automatically. The items listed below could not be',
      'resolved, so look at the image and decide each one.',
      '',
      'Reply with ONLY a JSON object, with no explanation and no markdown, in',
      'exactly this shape:',
      '',
      '{"items":[{"section":"TEST I","item":12,"choice":"B"}]}',
      '',
      'Rules:',
      '- Return one entry for every item listed below, and no others.',
      '- "choice" is the single letter of the one bubble that is filled in,',
      '  uppercased -- for example "A", "B", "C", "D", "E".',
      '- If no bubble for that item is filled in, use "choice": null.',
      '- If two or more bubbles really are filled in, use "choice": "MULTIPLE".',
      '- Do not guess. If the image does not let you tell, use null.',
      '',
      'Items to resolve:',
      ...lines,
    ].join('\n');
  }

  /// Reads the model's reply into verdicts, dropping anything unusable.
  ///
  /// Deliberately forgiving about the reply's packaging (models wrap JSON in
  /// markdown fences or bracket it with prose even when told not to) and
  /// deliberately strict about its content: an entry for an item that was not
  /// asked about, a duplicate, an unreadable choice, or a shape that is not the
  /// agreed one all yield nothing rather than a guess. A partial reading is
  /// fine -- whatever does parse is used.
  static Map<String, CorrectedAnswer> parseVerdicts(
    String reply, {
    required List<OmrItemResult> asked,
  }) {
    final askedKeys = <String>{
      for (final item in asked)
        AnswerCorrection.keyFor(item.sectionName, item.itemNumber),
    };

    final decoded = _extractJsonObject(reply);
    if (decoded == null) return const <String, CorrectedAnswer>{};
    final items = decoded['items'];
    if (items is! List) return const <String, CorrectedAnswer>{};

    final verdicts = <String, CorrectedAnswer>{};
    for (final entry in items) {
      if (entry is! Map) continue;
      final section = entry['section'];
      final number = entry['item'];
      if (section is! String || number is! int) continue;
      final key = AnswerCorrection.keyFor(section, number);
      // Volunteered answers about items nobody asked about, and repeats, are
      // both discarded -- the second occurrence has no better claim than the
      // first, and keeping either would make the result depend on ordering.
      if (!askedKeys.contains(key) || verdicts.containsKey(key)) continue;
      final value = _parseChoice(entry['choice']);
      if (value != null) verdicts[key] = value;
    }
    return verdicts;
  }

  /// One item's choice, or null when the reply does not say anything usable.
  ///
  /// A missing/null choice and the words the model might use for it all mean
  /// the same thing: nothing is marked. Only a single letter or digit is taken
  /// as a choice, because that is all an option bubble can be -- anything
  /// longer is the model editorialising, which is not a verdict.
  static CorrectedAnswer? _parseChoice(Object? raw) {
    if (raw == null) return const CorrectedAnswer.blank();
    if (raw is! String) return null;
    final token = raw.trim().toUpperCase();
    if (token.isEmpty ||
        token == 'NULL' ||
        token == 'NONE' ||
        token == 'BLANK') {
      return const CorrectedAnswer.blank();
    }
    if (token == 'MULTIPLE' || token == 'MULTI') {
      return const CorrectedAnswer.multiple();
    }
    if (token.length == 1 && RegExp(r'^[A-Z0-9]$').hasMatch(token)) {
      return CorrectedAnswer.choice(token);
    }
    return null;
  }

  /// The first JSON object in [reply], or null when there is not one.
  static Map<String, dynamic>? _extractJsonObject(String reply) {
    var text = reply.trim();
    final fence = RegExp(r'```(?:json)?', caseSensitive: false).firstMatch(text);
    if (fence != null) {
      text = text.substring(fence.end);
      final close = text.indexOf('```');
      if (close >= 0) text = text.substring(0, close);
      text = text.trim();
    }
    final start = text.indexOf('{');
    final stop = text.lastIndexOf('}');
    if (start < 0 || stop <= start) return null;
    final Object? parsed;
    try {
      parsed = jsonDecode(text.substring(start, stop + 1));
    } catch (_) {
      return null;
    }
    return parsed is Map<String, dynamic> ? parsed : null;
  }
}
