import 'package:cross_file/cross_file.dart' show XFile;
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rescan retry replaces the failed capture and clears stale errors', () {
    final state = AppState();
    addTearDown(state.dispose);
    state.rescanScanId = 'existing-scan';
    state.addCapturedPage(XFile('failed.jpg'));
    state.scanProcessingError = 'previous geometry failure';
    state.rectifiedImagePaths.add('previous-warp.jpg');
    state.addCapturedPage(XFile('retry.jpg'));
    expect(state.capturedPages.map((p) => p.path), ['retry.jpg']);
    expect(state.currentScannedPage, 1);
    expect(state.scanProcessingError, isNull);
    expect(state.rectifiedImagePaths, isEmpty);
    expect(state.rescanScanId, 'existing-scan');
  });

  test('normal batch capture still retains multiple sheets', () {
    final state = AppState();
    addTearDown(state.dispose);
    state.addCapturedPage(XFile('one.jpg'));
    state.addCapturedPage(XFile('two.jpg'));
    expect(state.capturedPages.map((p) => p.path), ['one.jpg', 'two.jpg']);
    expect(state.currentScannedPage, 2);
  });
}
