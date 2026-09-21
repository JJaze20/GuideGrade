import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import 'answer_correction_sheet.dart';

/// Wires the answer-correction editor to [AppState] for one saved scan: each
/// save/reset goes through [AppState.correctScanAnswer]/[AppState.resetScanAnswer]
/// (which records the correction, recalculates the score with the exam's
/// unchanged scoring rules and queues the sync) and hands back the scan as it
/// then stands.
ScanEditing scanEditingFor(AppState appState, String batchId, LocalScan scan) {
  return ScanEditing(
    scan: scan,
    answerKey: appState.answerKeys[scan.decoded.examCode],
    onCorrect: (section, item, value, reason, requestId) async => (await appState.correctScanAnswer(
      batchId: batchId,
      scanId: scan.id,
      sectionName: section,
      itemNumber: item,
      value: value,
      reason: reason,
      requestId: requestId,
    ))
        .scan,
    onReset: (section, item, requestId) async => (await appState.resetScanAnswer(
      batchId: batchId,
      scanId: scan.id,
      sectionName: section,
      itemNumber: item,
      requestId: requestId,
    ))
        .scan,
  );
}
