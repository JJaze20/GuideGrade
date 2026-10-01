import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/scan_quality_gate.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

OmrItemResult _item(int n, {String? marked, bool ambiguous = false}) =>
    OmrItemResult(
      sectionName: 'Test I',
      itemNumber: n,
      markedChoice: marked,
      isAmbiguous: ambiguous,
    );

OmrScanResult _sheet(List<OmrItemResult> items, {String? meshVerdict}) =>
    OmrScanResult(
      examCode: 'TAT',
      items: items,
      meshVerdict: meshVerdict,
    );

/// A clean sheet: every item answered, geometry fine.
OmrScanResult _goodSheet({int n = 20, String? meshVerdict = 'meshApplied'}) =>
    _sheet(
      [for (var i = 1; i <= n; i++) _item(i, marked: 'A')],
      meshVerdict: meshVerdict,
    );

void main() {
  group('ScanQualityGate', () {
    test('a clean sheet passes every check', () {
      final report = ScanQualityGate.inspect(_goodSheet(), 1);
      expect(report.passed, isTrue);
      expect(report.failures, isEmpty);
      expect(report.sheetNumber, 1);
    });

    test('planar geometry passes — no correction needed is not a fault', () {
      final report =
          ScanQualityGate.inspect(_goodSheet(meshVerdict: 'planar'), 1);
      expect(report.passed, isTrue);
    });

    test('a scan with no recorded verdict is not failed for it', () {
      // Older scans predate meshVerdict. Treating "unknown" as a failure
      // would flag every archived sheet.
      final report = ScanQualityGate.inspect(_goodSheet(meshVerdict: null), 1);
      expect(report.passed, isTrue);
    });

    test('likelyMisregistered fails the geometry check', () {
      final report = ScanQualityGate.inspect(
          _goodSheet(meshVerdict: 'likelyMisregistered'), 1);
      expect(report.passed, isFalse);
      expect(report.failures.single.label, 'Sheet geometry');
      expect(report.failures.single.detail, isNotEmpty);
    });

    test('tooSevere fails the geometry check', () {
      final report =
          ScanQualityGate.inspect(_goodSheet(meshVerdict: 'tooSevere'), 1);
      expect(report.passed, isFalse);
      expect(report.failures.single.label, 'Sheet geometry');
    });

    test('a single ambiguous item fails the sheet', () {
      final items = [
        for (var i = 1; i <= 20; i++) _item(i, marked: 'A'),
      ]..[4] = _item(5, ambiguous: true);
      final report =
          ScanQualityGate.inspect(_sheet(items, meshVerdict: 'planar'), 1);
      expect(report.passed, isFalse);
      expect(report.failures.single.label, 'Every answer read clearly');
    });

    test('mostly-blank sheet fails — a lost region, not a shy examinee', () {
      final items = [
        for (var i = 1; i <= 20; i++) _item(i, marked: i <= 5 ? 'A' : null),
      ];
      final report =
          ScanQualityGate.inspect(_sheet(items, meshVerdict: 'planar'), 1);
      expect(report.passed, isFalse);
      expect(report.failures.single.label, 'Whole sheet was read');
    });

    test('a half-blank sheet still passes — examinees do skip questions', () {
      final items = [
        for (var i = 1; i <= 20; i++) _item(i, marked: i <= 10 ? 'A' : null),
      ];
      final report =
          ScanQualityGate.inspect(_sheet(items, meshVerdict: 'planar'), 1);
      expect(report.passed, isTrue);
    });

    test('an empty sheet does not divide by zero', () {
      final report = ScanQualityGate.inspect(
          _sheet(const [], meshVerdict: 'planar'), 1);
      expect(report.passed, isTrue);
    });

    test('all failures are reported together, not just the first', () {
      final items = [
        for (var i = 1; i <= 20; i++)
          _item(i, marked: i <= 3 ? 'A' : null, ambiguous: i == 2),
      ];
      final report = ScanQualityGate.inspect(
          _sheet(items, meshVerdict: 'tooSevere'), 1);
      expect(report.failures.length, 3);
    });

    test('passing checks are kept on the report, not discarded', () {
      // The dialog shows the whole checklist, so a report has to carry the
      // rows that passed as well as the ones that did not.
      final report =
          ScanQualityGate.inspect(_goodSheet(meshVerdict: 'tooSevere'), 1);
      expect(report.checks.length, 3);
      expect(report.checks.where((c) => c.passed).length, 2);
    });
  });

  group('ScanQualityGate.inspectSession', () {
    test('returns only the failing sheets, numbered from 1', () {
      final results = [
        _goodSheet(),
        _goodSheet(meshVerdict: 'tooSevere'),
        _goodSheet(),
      ];
      final failed = ScanQualityGate.inspectSession(results);
      expect(failed.length, 1);
      expect(failed.single.sheetNumber, 2);
    });

    test('a clean session returns nothing, so the gate never shows', () {
      final failed =
          ScanQualityGate.inspectSession([_goodSheet(), _goodSheet()]);
      expect(failed, isEmpty);
    });

    test('an empty session is not an error', () {
      expect(ScanQualityGate.inspectSession(const []), isEmpty);
    });
  });
}
