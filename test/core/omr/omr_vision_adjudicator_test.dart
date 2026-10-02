import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_vision_adjudicator.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

OmrItemResult _item(int n, {String? marked, bool ambiguous = false}) =>
    OmrItemResult(
      sectionName: 'Test I',
      itemNumber: n,
      markedChoice: marked,
      isAmbiguous: ambiguous,
    );

OmrScanResult _sheet(List<OmrItemResult> items) =>
    OmrScanResult(examCode: 'TAT', items: items);

/// The key a verdict for item [n] is filed under.
String _key(int n) => AnswerCorrection.keyFor('Test I', n);

void main() {
  group('OmrVisionAdjudicator.unresolvedItems', () {
    test('picks up ambiguous items and ignores confident ones', () {
      final flagged = OmrVisionAdjudicator.unresolvedItems(_sheet([
        _item(1, marked: 'A'),
        _item(2, ambiguous: true),
        _item(3, marked: 'B'),
      ]));
      expect(flagged.map((i) => i.itemNumber), [2]);
    });

    test('leaves blanks alone unless they are asked for', () {
      // A blank is indistinguishable from a missed bubble to the decoder, so
      // asking about all of them by default would spend money to be told
      // "nothing there" on every skipped question.
      final sheet = _sheet([_item(1), _item(2, marked: 'A')]);
      expect(OmrVisionAdjudicator.unresolvedItems(sheet), isEmpty);
      expect(
        OmrVisionAdjudicator.unresolvedItems(sheet, includeBlanks: true)
            .map((i) => i.itemNumber),
        [1],
      );
    });

    test('a clean sheet has nothing to resolve', () {
      final sheet = _sheet([
        for (var i = 1; i <= 20; i++) _item(i, marked: 'A'),
      ]);
      expect(OmrVisionAdjudicator.unresolvedItems(sheet), isEmpty);
    });
  });

  group('OmrVisionAdjudicator.buildPrompt', () {
    test('names every flagged item and asks for JSON only', () {
      final prompt = OmrVisionAdjudicator.buildPrompt([
        _item(12, ambiguous: true),
        _item(19),
      ]);
      expect(prompt, contains('item 12'));
      expect(prompt, contains('item 19'));
      expect(prompt, contains('"section":"TEST I","item":12,"choice":"B"'));
      expect(prompt, contains('no markdown'));
    });

    test('does not mention items that were read cleanly', () {
      final prompt = OmrVisionAdjudicator.buildPrompt([_item(7, ambiguous: true)]);
      expect(prompt, contains('item 7'));
      expect(prompt, isNot(contains('item 8')));
    });
  });

  group('OmrVisionAdjudicator.parseVerdicts', () {
    final asked = [_item(12, ambiguous: true), _item(19)];

    test('reads a plain JSON reply', () {
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        '{"items":[{"section":"TEST I","item":12,"choice":"b"}]}',
        asked: asked,
      );
      expect(verdicts[_key(12)], const CorrectedAnswer.choice('B'));
    });

    test('reads a reply wrapped in a markdown fence', () {
      // Models add fences even when told not to; refusing the answer over
      // packaging would make the feature fail for a reason nobody can see.
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        'Here is the result:\n```json\n'
        '{"items":[{"section":"TEST I","item":12,"choice":"C"}]}\n'
        '```\n',
        asked: asked,
      );
      expect(verdicts[_key(12)], const CorrectedAnswer.choice('C'));
    });

    test('a null choice means nothing is marked', () {
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        '{"items":[{"section":"TEST I","item":12,"choice":null}]}',
        asked: asked,
      );
      expect(verdicts[_key(12)], const CorrectedAnswer.blank());
    });

    test('MULTIPLE means two bubbles really are filled', () {
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        '{"items":[{"section":"TEST I","item":12,"choice":"MULTIPLE"}]}',
        asked: asked,
      );
      expect(verdicts[_key(12)], const CorrectedAnswer.multiple());
    });

    test('drops a verdict for an item nobody asked about', () {
      // The sheet's own items are the only ones that exist; a model answering
      // about question 99 has invented it, and that is not evidence.
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        '{"items":[{"section":"TEST I","item":99,"choice":"A"},'
        '{"section":"TEST I","item":12,"choice":"B"}]}',
        asked: asked,
      );
      expect(verdicts.keys, [_key(12)]);
    });

    test('keeps the first of a repeated verdict', () {
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        '{"items":[{"section":"TEST I","item":12,"choice":"B"},'
        '{"section":"TEST I","item":12,"choice":"D"}]}',
        asked: asked,
      );
      expect(verdicts[_key(12)], const CorrectedAnswer.choice('B'));
    });

    test('drops a choice that is not a single option token', () {
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        '{"items":[{"section":"TEST I","item":12,"choice":"probably B"}]}',
        asked: asked,
      );
      expect(verdicts, isEmpty);
    });

    test('a reply that is not JSON yields nothing rather than a guess', () {
      for (final reply in [
        '',
        'I cannot tell from this image.',
        '{"items": "none"}',
        '{"items":[{"section":"TEST I","item":"12","choice":"B"}]}',
      ]) {
        expect(
          OmrVisionAdjudicator.parseVerdicts(reply, asked: asked),
          isEmpty,
          reason: 'reply: $reply',
        );
      }
    });

    test('keeps what parses when only part of the reply is usable', () {
      final verdicts = OmrVisionAdjudicator.parseVerdicts(
        '{"items":[{"section":"TEST I","item":12,"choice":"B"},'
        '{"section":"TEST I","item":19,"choice":"whatever"}]}',
        asked: asked,
      );
      expect(verdicts.keys, [_key(12)]);
    });
  });

  group('OmrVisionAdjudicator.adjudicate', () {
    test('a sheet with nothing unresolved never reaches the model', () async {
      // No key is configured in tests, so this also proves the early return
      // happens before any request is attempted: otherwise it would throw.
      final verdicts = await OmrVisionAdjudicator().adjudicate(
        result: _sheet([_item(1, marked: 'A')]),
        imageBytes: Uint8List(0),
      );
      expect(verdicts, isEmpty);
    });
  });
}
