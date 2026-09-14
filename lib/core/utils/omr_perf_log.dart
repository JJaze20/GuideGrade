import 'package:flutter/foundation.dart';

/// TEMPORARY diagnostic switch for scan-pipeline latency instrumentation,
/// main-isolate side — mirrors `omr_decoder_native.dart`'s `_kPerfDebug`/
/// `_perfLog` (kept separate there: that file runs inside `compute()`-
/// spawned isolates and must use synchronous `print`, not `debugPrint`,
/// for isolate-teardown safety — a constraint that doesn't apply here,
/// since every call site in this file logs only after control has already
/// returned to the main isolate).
///
/// Purely observational — no threshold, filter, or decision anywhere reads
/// these numbers. Remove once real on-device timings have been collected
/// and acted on.
const bool kOmrPerfDebug = true;

/// Logs [line] prefixed `[OMR PERF]`, matching the isolate-side format
/// exactly so both halves of a scan's timing show up under the same grep.
void omrPerfLog(String line) {
  if (kOmrPerfDebug) debugPrint('[OMR PERF] $line');
}
