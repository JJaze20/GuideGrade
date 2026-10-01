import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;

import '../../../core/constants/app_colors.dart';
import '../../../core/omr/duplicate_scan_detector.dart';
import '../../../core/omr/fiducial_coordinate_mapping.dart';
import '../../../core/omr/fiducial_search_tuning.dart';
import '../../../core/omr/exam_score.dart';
import '../../../core/omr/omr_decoder.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/omr/rescan_comparison.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/omr/scan_quality_gate.dart';
import '../widgets/scan_quality_dialog.dart';
import '../../../core/state/app_state.dart';
import '../../../core/state/rescan_candidate.dart';
import '../../../core/utils/omr_perf_log.dart';
import '../../../models/local_batch.dart';
import 'rescan_comparison_screen.dart';

class _AlignmentCheckRequest {
  final String imagePath;
  final OmrExamTemplate template;
  const _AlignmentCheckRequest(this.imagePath, this.template);
}

AlignmentCheck _checkAlignment(_AlignmentCheckRequest request) {
  return const OmrDecoder().locateCorners(request.imagePath, request.template);
}

class _RejectedCaptureDebugVizRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final String debugDir;
  const _RejectedCaptureDebugVizRequest(this.imagePath, this.template, this.debugDir);
}

/// Dumps the same kind of annotated debug images
/// [AppState.processCapturedPages] writes for a SUCCESSFUL capture (see
/// `OmrDecoder.saveDebugVisualization`'s doc comment, including its own
/// `sheet{n}_FAILED.jpg` fallback when corner detection itself throws), but
/// for a capture the post-capture gate just REJECTED — which otherwise
/// leaves no trace anywhere, since a rejected photo never reaches
/// [AppState.processCapturedPages] at all. Written to a `rejected/`
/// subfolder of the same "omr_debug" directory so these can never collide
/// with (or be overwritten by) a later successful capture's own debug
/// files at the same page slot. Best-effort only: any failure here is
/// swallowed by the caller, since this exists purely for diagnosis and
/// must never affect the actual scanning flow.
void _saveRejectedCaptureDebugViz(_RejectedCaptureDebugVizRequest request) {
  final dir = Directory('${request.debugDir}/rejected');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  // A fresh, distinguishable slot per rejection (not tied to a page index,
  // since a rejected photo was never assigned one) -- old ones are left in
  // place rather than overwritten, so a string of retries during one
  // session can all still be inspected afterward.
  final pageIndex = DateTime.now().millisecondsSinceEpoch;
  const OmrDecoder().saveDebugVisualization(
    request.imagePath,
    request.template,
    dir.path,
    pageIndex,
  );
}

class _NormalizeOrientationRequest {
  final String imagePath;
  final int quarterTurnsClockwise;
  const _NormalizeOrientationRequest(this.imagePath, this.quarterTurnsClockwise);
}

void _normalizeCaptureOrientation(_NormalizeOrientationRequest request) {
  const OmrDecoder().normalizeCaptureOrientation(
    request.imagePath,
    request.quarterTurnsClockwise,
  );
}

/// How many 90°-clockwise turns the `camera` plugin's own preview widget
/// applies to the raw sensor texture to display it upright for a given
/// [DeviceOrientation] — copied verbatim from `CameraPreview`'s own
/// private `_getQuarterTurns` (package:camera/src/camera_preview.dart) so
/// [_ExamScanningScreenState._capture] can apply the exact same correction
/// to the captured JPEG's raw pixels (see
/// `OmrDecoder.normalizeCaptureOrientation`'s doc comment for why this
/// must come from real device orientation, not guessed from image
/// content). Keep in sync if the `camera` package ever changes this
/// mapping.
const _deviceOrientationQuarterTurns = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeRight: 1,
  DeviceOrientation.portraitDown: 2,
  DeviceOrientation.landscapeLeft: 3,
};

class _LiveCornersRequest {
  final Uint8List lumaBytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final OmrExamTemplate template;

  /// Whether to also build the (otherwise-skipped) per-corner diagnostic
  /// detail for the temporary opt-in overlay — see
  /// [_ExamScanningScreenState._diagnosticsEnabled]. False on every normal
  /// frame check, so enabling diagnostics never changes what a regular
  /// (non-debugging) session actually does.
  final bool includeDiagnostics;
  const _LiveCornersRequest(
    this.lumaBytes,
    this.width,
    this.height,
    this.bytesPerRow,
    this.template, {
    this.includeDiagnostics = false,
  });
}

/// Corner-detection result plus a coarse mean-brightness read of the same
/// frame — piggybacked onto this exact call (same luma bytes, same throttled
/// throttle, same isolate hop as the corner check) so the live low-light
/// hint costs nothing extra. Strided sampling (every 8th pixel in both
/// directions, ~1/64th of the frame) keeps this cheap enough for that
/// cadence; a live hint only needs a stable exposure estimate, not every
/// pixel.
///
/// Each corner's [CornerConfidence] tier comes straight from the decoder's
/// squareness-scored search (see omr_decoder_native.dart) — none/low/
/// confident, per corner, independently — so the four on-screen viewfinders
/// can each show their own state instead of only an aggregate "X/4" count.
///
/// [cornerPositions] carries each found corner's centroid as a (x/width,
/// y/height) fraction of this frame (null where nothing was found) — the
/// per-frame position data the auto-capture stability check diffs between
/// consecutive frames (see [_ExamScanningScreenState._onCameraFrame]).
///
/// [diagnostics] and [rotation] are null/[FrameRotation.none] whenever
/// [_LiveCornersRequest.includeDiagnostics] was false — the normal case;
/// see [_ExamScanningScreenState._diagnosticsEnabled].
({
  List<CornerConfidence> cornersFound,
  List<(double, double)?> cornerPositions,
  List<CornerDiagnostic>? diagnostics,
  FrameRotation rotation,
  double meanLuma,
}) _checkLiveCorners(_LiveCornersRequest request) {
  final result = const OmrDecoder().checkCornersFromLuma(
    request.lumaBytes,
    request.width,
    request.height,
    request.bytesPerRow,
    request.template,
    includeDiagnostics: request.includeDiagnostics,
  );
  const stride = 8;
  var sum = 0;
  var count = 0;
  for (var y = 0; y < request.height; y += stride) {
    final rowStart = y * request.bytesPerRow;
    for (var x = 0; x < request.width; x += stride) {
      sum += request.lumaBytes[rowStart + x];
      count++;
    }
  }
  return (
    cornersFound: result.confidence,
    cornerPositions: result.positions,
    diagnostics: result.diagnostics,
    rotation: result.rotation,
    meanLuma: count == 0 ? 255.0 : sum / count,
  );
}

/// OMR Scanner Loop — mirrors SCREENS.EXAM_SCANNING.
/// Shows a live camera feed inside a capture viewfinder with a live
/// per-corner alignment overlay, and lets the user photograph each answer
/// sheet ("Scan Next" captures + advances) before compiling the batch
/// ("Compile Data").
class ExamScanningScreen extends StatefulWidget {
  const ExamScanningScreen({super.key});

  @override
  State<ExamScanningScreen> createState() => _ExamScanningScreenState();
}

class _ExamScanningScreenState extends State<ExamScanningScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  Future<void>? _initializeFuture;
  String? _cameraError;
  bool _isCapturing = false;

  /// Bumped at the start of every camera setup or teardown ([_setUpCamera],
  /// [_tearDownCamera]) — each of those captures its own generation number
  /// before its first `await` and re-checks it after every subsequent
  /// `await` before mutating any shared field. This is what prevents a
  /// stale operation's late-arriving continuation from corrupting state
  /// set up by a *newer* one — the concrete failure this guards against: a
  /// quick inactive→resumed blip (confirmed reproducible by taking a
  /// screenshot while scanning) can fire [didChangeAppLifecycleState] twice
  /// in close succession, so the old (inactive) call's `await
  /// controller.dispose()` can still be pending when the new (resumed)
  /// call's [_setUpCamera] has already created and assigned a working
  /// replacement controller. Without this guard, the stale call's
  /// continuation would go on to unconditionally null out (and thereby
  /// leak, since nothing else holds a reference to it any more) that
  /// brand-new working controller — permanently occupying the camera
  /// hardware with an orphaned, never-disposed session that even a fresh
  /// "Retry" tap can't recover from, since the OS never released it.
  int _cameraGeneration = 0;

  /// Whether the active exam's sheet is a landscape page (currently just
  /// TAT — see OmrExamTemplate.pageWidthPt/pageHeightPt). Set once in
  /// [didChangeDependencies] from the exam active when this screen opened,
  /// not re-read afterward: the active exam can't change without leaving
  /// this screen.
  ///
  /// Unlocks real landscape device rotation for this screen only (see
  /// didChangeDependencies/dispose) — a landscape sheet is naturally
  /// photographed by turning the phone sideways, same as any wide subject.
  /// [build] also uses this to lay the screen out full-screen-camera with
  /// a compact right-edge control dock instead of the full-width
  /// viewfinder + large bottom panel every other (portrait-page) exam
  /// gets.
  bool _isLandscapeExam = false;

  /// Captured once in [didChangeDependencies] (guarded by [_didSetUp], same
  /// as [_isLandscapeExam]) so [dispose] has a safe reference — looking up
  /// an InheritedWidget via `AppStateScope.of(context)` from within
  /// `dispose()` is not something to rely on.
  late final AppState _appState;

  /// Live, per-corner feedback: null until the first frame check completes,
  /// then each of the 4 corner marks' (in [OmrExamTemplate.cornerMarkers]
  /// order) [CornerConfidence] in the most recently checked frame — this is
  /// what the four on-screen viewfinders each color themselves from, and
  /// what [_autoCaptureStableSince]/[_autoCaptureArmed] key off for the
  /// auto-capture trigger. Purely advisory for MANUAL capture: it operates
  /// on a downscaled preview frame ([_liveCheckMaxDimension]), so a corner
  /// reading [CornerConfidence.none] here is not proof the real,
  /// full-resolution photo will fail — that question is answered only by
  /// the authoritative [_checkAlignment]/`locateCorners` call inside
  /// [_capture], against the actual captured file, regardless of what this
  /// live signal showed.
  List<CornerConfidence>? _liveCornersFound;
  DateTime? _lastFrameCheckAt;
  bool _frameCheckInFlight = false;

  /// TEMPORARY, opt-in, off by default: shows a diagnostic overlay of the
  /// actual per-corner search boxes/detected positions/rejection reasons
  /// the decoder is working with, distinct from the four always-visible
  /// fixed aiming guides drawn by [_PageGuidePainter] (see
  /// [_DiagnosticOverlayPainter]) — for investigating cases where the
  /// fixed guides look aligned but the live indicator never reaches green.
  /// Only reachable in a debug build (see the top bar's bug-icon toggle in
  /// [_buildTopBar]) — this is a developer tool, not a user-facing
  /// feature, and defaults to false even there.
  bool _diagnosticsEnabled = false;

  /// Whether to keep this session's per-stage decode images so they can be
  /// reviewed afterwards from Scan Results ("How it was read").
  ///
  /// Unlike [_diagnosticsEnabled] this is available in a release build: the
  /// people who need to see how a sheet was read are running one. It costs
  /// one extra decode per page and nothing else -- deliberately NOT the
  /// verbose per-contour logging, which is what made dim-light scanning
  /// crawl and stays behind [_diagnosticsEnabled].
  ///
  /// Mirrors [AppState.debugImagesEnabled], enabled during scanner development
  /// so the "How it was read" viewer has diagnostic images available.
  bool _debugImagesEnabled = true;

  /// Populated only while [_diagnosticsEnabled] is true (see
  /// [_LiveCornersRequest.includeDiagnostics]); null otherwise, same as
  /// before diagnostics existed.
  List<CornerDiagnostic>? _liveDiagnostics;

  /// Which orientation the most recent live check's winning attempt used —
  /// see [FrameRotation]'s doc comment and
  /// `fiducial_coordinate_mapping.dart`'s own doc comment for the
  /// (on-device-unverified) assumption this feeds into the overlay's
  /// coordinate mapping.
  FrameRotation _liveRotation = FrameRotation.none;

  /// TEMPORARY. Counts live-frame checks so [_onCameraFrame] can log timing
  /// only every 10th one (see [omrPerfLog]) instead of on every tick.
  int _liveFrameLogCounter = 0;

  /// Most recent live mean-luma read (0-255, coarse), from the same throttled
  /// frame check as [_liveCornersFound] — see [_checkLiveCorners]. Null until
  /// the first check completes. Drives the low-light hint and the exposure
  /// nudge below; advisory only, same as the rest of the live guide.
  double? _meanLuma;

  /// Below this mean-luma reading, the scene counts as "low light" for the
  /// hint/exposure-nudge below. Not tuned against real low-light captures
  /// yet (see the low-light accuracy plan) — a reasonable starting point
  /// pending on-device validation, not a final calibrated threshold.
  static const double _lowLightLumaThreshold = 70;

  /// Whether the user has manually turned the torch on for this session.
  /// Manual only — see _toggleTorch's doc comment for why this isn't
  /// automatic.
  bool _torchOn = false;

  /// Whether [_maybeNudgeExposure] has already pushed the exposure offset
  /// up for the current low-light stretch, so it isn't re-issued on every
  /// single throttled frame check — only on entering/leaving low light.
  bool _exposureNudged = false;

  /// When the live read most recently became "recoverable" (every corner at
  /// least [CornerConfidence.low] — no corner missing outright), set the
  /// moment that first held and cleared the instant any corner drops back
  /// to [CornerConfidence.none]. Feeds only [_readyToCapture]/the "Ready to
  /// scan" caption text (display, see [_viewfinderCaption]) — it does NOT
  /// gate the manual capture button or [_capture] any more. Manual capture
  /// is gated solely on the camera being initialized, no capture already in
  /// flight, and the batch's scan limit; the live detector operates on a
  /// downscaled preview frame and one corner briefly reading `none` there
  /// was found to make real, valid captures on an actual full-resolution
  /// photo impossible to ever attempt. Auto-capture uses its own separate,
  /// stricter state ([_autoCaptureStableSince]/[_autoCaptureArmed]) and
  /// never reads this field.
  DateTime? _captureReadySince;

  /// How long the live read must stay recoverable before the "Ready to
  /// scan" caption (see [_viewfinderCaption]) reports it — display timing
  /// only, matching [_captureReadySince]'s scope.
  static const Duration _requiredStableDuration = Duration(milliseconds: 500);

  /// Display-only: whether the live read currently looks stably good enough
  /// to report "Ready to scan" in the caption (see [_viewfinderCaption]).
  /// Not a capture gate — see [_captureReadySince]'s doc comment for why
  /// manual capture never depends on this, and see the auto-capture trigger
  /// in [_onCameraFrame] for the separate, stricter gate that actually
  /// governs automatic capture.
  bool get _readyToCapture {
    final since = _captureReadySince;
    return since != null &&
        DateTime.now().difference(since) >= _requiredStableDuration;
  }

  /// Most recently processed frame's per-corner positions (see
  /// [_checkLiveCorners]'s [cornerPositions]) — diffed against each new
  /// frame's positions to detect real motion, independent of confidence.
  List<(double, double)?>? _liveCornerPositions;

  /// When the current motionless streak of all-4-[CornerConfidence.confident]
  /// began, or null while not currently all-confident or while still
  /// settling from movement. Distinct from [_captureReadySince], which only
  /// tracks how long the read has stayed *recoverable* (GREEN-or-YELLOW) —
  /// auto-capture is stricter: full GREEN, and the four marker positions
  /// themselves must have stopped moving, not just stayed found.
  DateTime? _autoCaptureStableSince;

  /// False immediately after an auto-capture fires; only flips back true
  /// once the live verdict actually leaves GREEN (the sheet was pulled
  /// away, repositioned, or occluded) — so a still-in-frame sheet that
  /// remains steady right after being captured can't immediately trigger a
  /// second, duplicate auto-capture the instant [_isCapturing] clears.
  bool _autoCaptureArmed = true;

  /// Per-corner movement threshold between consecutive live checks, as a
  /// fraction of the frame's own dimension (device/resolution-independent —
  /// see [_checkLiveCorners]'s normalized positions). Any single corner
  /// moving more than this resets the stability clock; a real, sustained
  /// drift can never silently accumulate into "stable".
  static const double _autoCaptureMovementThresholdFrac = 0.008;

  /// Minimum interval between preview checks; in-flight checks never overlap.
  static const Duration _liveCheckInterval = Duration(milliseconds: 250);

  /// Require a second steady, all-green frame before automatic capture.
  static const Duration _autoCaptureStableDuration =
      Duration(milliseconds: 250);

  /// Whether the live-checked scene currently reads as low light and the
  /// torch isn't already on — the one condition where the caption below
  /// prioritizes the flash hint over corner-alignment feedback, since
  /// fixing the lighting matters more at that point than which corner
  /// still needs adjusting.
  bool get _isLowLight =>
      _meanLuma != null && _meanLuma! < _lowLightLumaThreshold && !_torchOn;

  /// When the live read most recently stopped being all-four-confident, or
  /// null while it currently is. Drives [_showCaptureAnyway] only.
  DateTime? _nonGreenSince;

  /// How long the corners may refuse to lock before the caption stops giving
  /// advice and tells the user they can simply shoot.
  static const Duration _captureAnywayAfter = Duration(seconds: 6);

  /// Whether to tell the user they can capture without waiting for green.
  ///
  /// Manual capture has never actually been gated on the live read — see
  /// [_captureReadySince]'s doc comment, and [_capture], which requires only
  /// an initialized camera, no capture in flight, and the batch's scan
  /// limit. But the viewfinder shows red corners and advice-shaped captions,
  /// so in a dim room people wait for a green that is not coming. This says
  /// the quiet part out loud once waiting has clearly stopped helping.
  ///
  /// Safe to act on: [_capture] re-runs the authoritative full-resolution
  /// alignment check on the photo itself, so a capture taken on a
  /// non-green preview is still verified before it can become a result.
  bool get _showCaptureAnyway =>
      _nonGreenSince != null &&
      DateTime.now().difference(_nonGreenSince!) >= _captureAnywayAfter;

  /// Overall live traffic-light read, from the four independent per-corner
  /// tiers: RED if any corner is missing outright, GREEN only once all four
  /// are confidently locked, YELLOW for anything recoverable in between
  /// (matches the four viewfinders' own coloring — see [_PageGuidePainter]).
  /// Null until the first live check completes.
  AlignmentVerdict? get _liveVerdict {
    final found = _liveCornersFound;
    if (found == null) return null;
    if (found.any((c) => c == CornerConfidence.none)) return AlignmentVerdict.red;
    if (found.every((c) => c == CornerConfidence.confident)) {
      return AlignmentVerdict.green;
    }
    return AlignmentVerdict.yellow;
  }

  static const _cornerNames = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];

  /// Viewfinder caption text — the low-light hint takes priority over the
  /// usual corner-alignment status when active (see [_isLowLight]), and the
  /// stuck hint (see [_showCaptureAnyway]) takes priority over both once the
  /// corners have refused to lock for long enough that advice alone clearly
  /// isn't working.
  String _viewfinderCaption() {
    // Ordered below the lighting hint on purpose: for the first few seconds
    // "add light" is the more useful instruction, and only once that has
    // visibly failed is it worth telling them to shoot regardless.
    if (_showCaptureAnyway) {
      return 'Corners not locked — tap the shutter anyway, '
          'alignment is rechecked after capture';
    }
    if (_isLowLight) return 'Low light — flash may help, or just tap the shutter';
    final found = _liveCornersFound;
    if (found == null) return 'Align the 4 black corner squares inside the guides';
    switch (_liveVerdict!) {
      case AlignmentVerdict.green:
        return _readyToCapture
            ? (_appState.activeExamCode == 'TAT'
                ? 'Corners found — full alignment checked after capture'
                : 'Ready to scan')
            : 'Hold steady…';
      case AlignmentVerdict.yellow:
        final worst = found.indexWhere((c) => c != CornerConfidence.confident);
        final name = worst >= 0 ? _cornerNames[worst] : 'one corner';
        return 'Corner $name uncertain — adjust if possible, or capture to continue';
      case AlignmentVerdict.red:
        final missing = [
          for (var i = 0; i < found.length; i++)
            if (found[i] == CornerConfidence.none) _cornerNames[i],
        ];
        if (missing.length == 4) {
          return 'Align the 4 black corner squares inside the guides';
        }
        return 'Missing: ${missing.join(', ')}';
    }
  }

  /// Neutral until the first live check completes; otherwise mirrors
  /// [_liveVerdict] (green/amber/red) — the same tri-state the four
  /// viewfinders each show individually, given as one at-a-glance cue too.
  Color get _scanWindowBorderColor {
    switch (_liveVerdict) {
      case null:
        return AppColors.accentYellowGreen;
      case AlignmentVerdict.green:
        return AppColors.primaryGreen;
      case AlignmentVerdict.yellow:
        return const Color(0xFFF59E0B);
      case AlignmentVerdict.red:
        return AppColors.warmRedOrange;
    }
  }

  /// Guards the [didChangeDependencies] setup below to run exactly once —
  /// that callback fires again on every inherited-widget change (e.g.
  /// every AppState.notifyListeners()), not just the first time, and
  /// re-triggering camera setup or the orientation lock on every one of
  /// those would restart the camera stream constantly instead of once.
  bool _didSetUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didSetUp) return;
    _didSetUp = true;
    // AppStateScope.of(context) establishes a rebuild subscription (via
    // dependOnInheritedWidgetOfExactType), which Flutter only allows from
    // build()/didChangeDependencies() onward — calling it in initState()
    // itself throws, since the widget isn't fully attached to the tree
    // yet at that point.
    _appState = AppStateScope.of(context);
    _debugImagesEnabled = _appState.debugImagesEnabled;
    // All exams use the portrait camera UI. TAT's printed page is rotated
    // into canonical coordinates by measured fiducials after capture.
    _isLandscapeExam = false;
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initializeFuture = _setUpCamera();
  }

  /// Disposes a controller that [_setUpCamera] created but that turned out
  /// to be superseded (a newer generation took over, or the widget was
  /// unmounted) before it could be adopted as [_cameraController]. Logging
  /// + swallowing here, never rethrowing: this is best-effort release of a
  /// resource nobody references any more, not something a caller needs to
  /// react to. Never skip this — an un-disposed, unreferenced controller
  /// permanently occupies the camera hardware (see [_cameraGeneration]'s
  /// doc comment for the exact failure this prevents).
  Future<void> _disposeOrphanedController(CameraController controller) async {
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } on CameraException catch (e) {
      debugPrint(
        '[ExamScanning] stopImageStream (orphaned controller) failed: ${e.code} ${e.description}',
      );
    } catch (_) {}
    try {
      await controller.dispose();
    } on CameraException catch (e) {
      debugPrint(
        '[ExamScanning] dispose (orphaned controller) failed: ${e.code} ${e.description}',
      );
    } catch (_) {}
  }

  Future<void> _setUpCamera() async {
    // Captured once, checked after every subsequent `await` below — see
    // [_cameraGeneration]'s doc comment for why this matters.
    final myGen = _cameraGeneration;
    if (mounted) setState(() => _cameraError = null);
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (!mounted || myGen != _cameraGeneration) return;
      if (cameras.isEmpty) {
        setState(() => _cameraError = 'No camera was found on this device.');
        return;
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // veryHigh (1080p, ~2MP) over the previous `high` (720p, ~0.92MP) —
      // a page with 72 small bubble rows needs real resolution to read
      // reliably; 720p was giving the decoder noticeably fewer pixels
      // per bubble than the phone's actual camera is capable of. Some
      // devices' camera2 hardware level can't bind a preview+capture
      // surface combination at that size though (CameraX throws
      // "IllegalArgumentException: No supported surface combination" —
      // confirmed on a real device), so step down through lower presets
      // rather than failing the whole scan screen outright.
      const presets = [
        ResolutionPreset.veryHigh,
        ResolutionPreset.high,
        ResolutionPreset.medium,
      ];
      Object? initError;
      for (final preset in presets) {
        final candidate = CameraController(
          backCamera,
          preset,
          enableAudio: false,
        );
        try {
          await candidate.initialize();
          controller = candidate;
          initError = null;
          break;
        } catch (e) {
          initError = e;
          await _disposeOrphanedController(candidate);
        }
        if (!mounted || myGen != _cameraGeneration) return;
      }
      if (controller == null) {
        // Every preset failed — rethrow the last (most representative)
        // error so the existing CameraException/catch-all handlers below
        // format and surface it the same way as before this fallback loop.
        throw initError!;
      }
      if (!mounted || myGen != _cameraGeneration) {
        // Superseded (a newer generation's setup or a teardown started)
        // while this controller was mid-initialize — never adopt it, and
        // never leave it undisposed. This exact interleaving, previously
        // unguarded, is what let a screenshot's quick inactive→resumed
        // blip permanently occupy the camera.
        await _disposeOrphanedController(controller);
        return;
      }
      // No capture-orientation lock — the device stays portrait the whole
      // time (see didChangeDependencies), so there's no landscapeLeft-vs-
      // landscapeRight ambiguity to resolve here in the first place.
      // OmrDecoder's own rotation retry (see _orientAndFindCorners) already
      // handles a landscape sheet appearing rotated within a portrait
      // capture, regardless of which way it's rotated.
      setState(() => _cameraController = controller);
      try {
        // Not guaranteed by default — explicitly keep the camera actively
        // refocusing/re-exposing on whatever's in frame (the sheet, once
        // the user positions it), rather than whatever the platform
        // happened to lock onto during initialization.
        await controller.setFocusMode(FocusMode.auto);
        await controller.setExposureMode(ExposureMode.auto);
        // Some camera HALs only actually (re)start continuous AF/AE once a
        // region is explicitly set — `setFocusMode(auto)` alone can leave
        // them locked onto whatever they focused on during initialization
        // (often the background behind where the sheet will be placed,
        // since nothing is in frame yet at that point). Centering this
        // targets wherever the on-screen guide already tells the user to
        // place the sheet, for both portrait and landscape (TAT) layouts —
        // this needs on-device confirmation, not assumed to fix focus by
        // itself; see [_focusOnPoint]'s doc comment for the follow-up
        // tap-to-focus this shares with.
        await _focusOnPoint(controller, const Offset(0.5, 0.5));
      } on CameraException catch (e) {
        debugPrint(
          '[ExamScanning] focus/exposure mode setup failed: ${e.code} ${e.description}',
        );
      } catch (_) {
        // Not all devices/lenses support explicit focus/exposure mode
        // control; capture still works with whatever the platform default is.
      }
      if (!mounted || myGen != _cameraGeneration) {
        // Superseded while configuring focus/exposure. Already adopted as
        // _cameraController above, but only ours to dispose here if a
        // later generation hasn't already moved it aside/torn it down.
        if (identical(_cameraController, controller)) {
          await _disposeOrphanedController(controller);
        }
        return;
      }
      try {
        await controller.startImageStream(_onCameraFrame);
      } on CameraException catch (e) {
        debugPrint(
          '[ExamScanning] startImageStream failed: ${e.code} ${e.description}',
        );
      } catch (_) {
        // Live guide feedback is advisory only; if streaming isn't
        // supported on this device, capture + the post-capture check
        // still work fine without it.
      }
    } on CameraException catch (e) {
      debugPrint(
        '[ExamScanning] camera setup failed: ${e.code} ${e.description}',
      );
      if (mounted && myGen == _cameraGeneration) {
        setState(() {
          _cameraError =
              e.code == 'CameraAccessDenied' ||
                  e.code == 'CameraAccessDeniedWithoutPrompt'
              ? 'Camera permission was denied. Enable it in your device settings to scan sheets.'
              : 'Could not start the camera (${e.description ?? e.code}).';
        });
      }
      if (controller != null && !identical(_cameraController, controller)) {
        await _disposeOrphanedController(controller);
      }
    } catch (e) {
      debugPrint('[ExamScanning] camera setup failed: $e');
      if (mounted && myGen == _cameraGeneration) {
        setState(() => _cameraError = 'Could not start the camera ($e).');
      }
      if (controller != null && !identical(_cameraController, controller)) {
        await _disposeOrphanedController(controller);
      }
    }
  }

  /// Stops the image stream and disposes [_cameraController] (shared by
  /// [didChangeAppLifecycleState]'s inactive/paused branch and [dispose]),
  /// then resets every piece of state a fresh session needs to start
  /// clean: the live corner guide, auto-capture's stability timer and
  /// arming, the frame-check throttle, torch/exposure state, and — as
  /// defensive cleanup, since an in-flight capture's own `try/finally` may
  /// never get a clean chance to run against a controller being torn down
  /// out from under it — the capture-in-progress flag.
  ///
  /// Bumps [_cameraGeneration] first (see its doc comment): a [_setUpCamera]
  /// call still in flight when this runs detects the change and disposes
  /// whatever controller it was building instead of adopting it, and this
  /// method's own dispose of [_cameraController] can never race a
  /// still-adopting [_setUpCamera] call for the same reason.
  Future<void> _tearDownCamera() async {
    _cameraGeneration++;
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } on CameraException catch (e) {
        debugPrint(
          '[ExamScanning] stopImageStream failed: ${e.code} ${e.description}',
        );
      } catch (_) {}
      try {
        await controller.dispose();
      } on CameraException catch (e) {
        debugPrint(
          '[ExamScanning] controller dispose failed: ${e.code} ${e.description}',
        );
      } catch (_) {}
    }
    _liveCornersFound = null;
    _liveCornerPositions = null;
    _liveDiagnostics = null;
    _liveRotation = FrameRotation.none;
    _captureReadySince = null;
    _autoCaptureStableSince = null;
    _autoCaptureArmed = true;
    _nonGreenSince = null;
    _meanLuma = null;
    _lastFrameCheckAt = null;
    _frameCheckInFlight = false;
    _isCapturing = false;
    // Torch/exposure state doesn't survive disposing the controller
    // (hardware-level, tied to the camera session) -- reset so the UI
    // (torch icon) matches the fresh controller the next _setUpCamera()
    // call will create, which always starts with flash off.
    _torchOn = false;
    _exposureNudged = false;
    if (mounted) setState(() {});
  }

  /// Full interruption-recovery cycle for [AppLifecycleState.resumed]:
  /// tears down whatever camera session exists (there may still be one if
  /// the OS never actually paused this app — a very brief interruption can
  /// resume before [AppLifecycleState.inactive]'s own teardown finishes, in
  /// which case [_tearDownCamera]'s generation bump makes that in-flight
  /// call a no-op for adoption purposes) and always initializes a
  /// completely fresh [CameraController] rather than trying to reuse or
  /// patch up whatever existed before.
  Future<void> _resumeCamera() async {
    if (_cameraController != null) {
      await _tearDownCamera();
    }
    if (!mounted) return;
    if (_isLandscapeExam) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    // A block body, not `setState(() => _initializeFuture = future)` --
    // even split into two statements like this, an arrow-function
    // *assignment* still evaluates to (and so returns) the assigned value,
    // i.e. `future` itself, which Flutter's setState rejects at runtime
    // ("setState() ... was called with a closure ... that returned a
    // Future") exactly as if `_setUpCamera()` had been called directly
    // inside the closure. Confirmed on-device: this crashed every resume
    // while a scanner screen was open, which is what "camera won't start"
    // actually was -- the exception aborted _resumeCamera partway through,
    // after _tearDownCamera had already nulled out _cameraController, so
    // no replacement controller ever got hooked up. A block body's last
    // statement is not a return value, so this actually returns void.
    final future = _setUpCamera();
    setState(() {
      _initializeFuture = future;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Covers a screenshot gesture, an incoming call/notification shade, a
      // brief app-switcher glance, or the app actually backgrounding — all
      // of these can interrupt an active camera session, and on at least
      // one confirmed case (taking a screenshot mid-scan) the OS-level
      // camera resource itself can become unusable if the controller isn't
      // released here. Unconditional (not gated on whether a controller
      // currently exists) and safe to call redundantly — [_tearDownCamera]
      // no-ops past the null-controller check either way.
      unawaited(_tearDownCamera());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_resumeCamera());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Marks any _setUpCamera call still in flight as stale — see
    // [_cameraGeneration]'s doc comment — so it disposes whatever
    // controller it was building instead of trying to call setState (or
    // worse, adopt a controller) on an unmounted State.
    _cameraGeneration++;
    // Restore the app-wide portrait lock (see main.dart) that
    // didChangeDependencies loosened for this one landscape-page exam --
    // every other screen is still built for a tall portrait frame, so
    // this must not leak past this screen's own lifetime.
    if (_isLandscapeExam) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      // The AppLockGate suppression set up alongside the orientation
      // unlock stays on for a little longer than this method call --
      // restoring portrait here is itself an orientation change, and on
      // this device that alone can trigger the same kind of spurious
      // resume the suppression exists to guard against. Confirmed
      // on-device: clearing it synchronously, right here, left that exact
      // resume unprotected and showed a lock prompt immediately after
      // leaving the TAT scanner -- clearing it a couple seconds later
      // instead (well after any such resume would have already landed)
      // covers the exit the same way entry already was, while still
      // letting a genuine, later return from background re-lock normally.
      Future.delayed(const Duration(seconds: 2), () {
        _appState.suppressAppLock = false;
      });
    }
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null && controller.value.isStreamingImages) {
      controller.stopImageStream();
    }
    controller?.dispose();
    super.dispose();
  }

  /// Throttled live check: at most once every 250ms, and never overlapping
  /// a check already in flight, so this stays cheap enough to run
  /// continuously while framing. Feeds the on-screen indicator, the
  /// display-only "Ready to scan" caption ([_captureReadySince]), and the
  /// auto-capture stability trigger below — never the manual capture gate,
  /// which no longer depends on the live detector at all.
  ///
  /// A frame can still be in flight through [compute] when a lifecycle
  /// interruption tears down (or replaces) the camera controller — [myGen]
  /// snapshots [_cameraGeneration] at dispatch time so the result can be
  /// discarded rather than applied to a session it no longer belongs to,
  /// instead of blindly mutating state on however things look by the time
  /// the isolate call resolves.
  void _onCameraFrame(CameraImage image) {
    if (!mounted || _frameCheckInFlight) return;
    final now = DateTime.now();
    if (_lastFrameCheckAt != null &&
        now.difference(_lastFrameCheckAt!) <
            _liveCheckInterval) {
      return;
    }
    final appState = AppStateScope.of(context);
    final template = omrTemplates[appState.activeExamCode];
    if (template == null) return;

    final myGen = _cameraGeneration;
    _lastFrameCheckAt = now;
    _frameCheckInFlight = true;
    final plane = image.planes.first;
    final liveFrameSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
    compute(
          _checkLiveCorners,
          _LiveCornersRequest(
            plane.bytes,
            image.width,
            image.height,
            plane.bytesPerRow,
            template,
            includeDiagnostics: _diagnosticsEnabled,
          ),
        )
        .then((result) {
          if (myGen == _cameraGeneration) _frameCheckInFlight = false;
          // Logged only every 10th tick — a live-check timing line on every
          // preview tick would flood logcat and risk
          // perturbing the very timing being measured.
          if (liveFrameSw != null && (++_liveFrameLogCounter % 10 == 0)) {
            omrPerfLog('liveFrame check=${liveFrameSw.elapsedMilliseconds}ms');
          }
          if (!mounted || myGen != _cameraGeneration) return;
          setState(() {
            _liveCornersFound = result.cornersFound;
            _liveDiagnostics = result.diagnostics;
            _liveRotation = result.rotation;
            _meanLuma = result.meanLuma;
            final recoverable =
                !result.cornersFound.any((c) => c == CornerConfidence.none);
            if (recoverable) {
              _captureReadySince ??= now;
            } else {
              _captureReadySince = null;
            }

            // Auto-capture stability tracking: stricter than
            // [_captureReadySince] above — requires all 4 corners fully
            // CONFIDENT (not just recoverable) AND their positions to have
            // stopped moving between checks, not merely stayed found.
            final allConfident = result.cornersFound
                .every((c) => c == CornerConfidence.confident);
            // Reuses the flag above rather than recomputing: how long the
            // corners have refused to lock is what [_showCaptureAnyway] needs.
            if (allConfident) {
              _nonGreenSince = null;
            } else {
              _nonGreenSince ??= now;
            }
            if (!allConfident) {
              _autoCaptureStableSince = null;
              // Leaving GREEN re-arms auto-capture — the sheet was moved,
              // replaced, or occluded, so the next full-stability streak is
              // allowed to trigger a fresh capture.
              if (!_autoCaptureArmed) _autoCaptureArmed = true;
            } else {
              final prev = _liveCornerPositions;
              // No prior all-confident frame to compare against counts as
              // "just arrived" — start the clock fresh rather than assuming
              // stability from a single frame.
              var moved = prev == null;
              if (prev != null) {
                for (var i = 0; i < result.cornerPositions.length; i++) {
                  final p = prev[i];
                  final c = result.cornerPositions[i];
                  if (p == null || c == null) {
                    moved = true;
                    break;
                  }
                  final dx = c.$1 - p.$1;
                  final dy = c.$2 - p.$2;
                  if (math.sqrt(dx * dx + dy * dy) >
                      _autoCaptureMovementThresholdFrac) {
                    moved = true;
                    break;
                  }
                }
              }
              if (moved || _autoCaptureStableSince == null) {
                _autoCaptureStableSince = now;
              }
            }
            _liveCornerPositions = result.cornerPositions;
          });
          unawaited(_maybeNudgeExposure(result.meanLuma));

          // Auto-capture trigger: armed, not already mid-capture, currently
          // GREEN, held motionlessly stable for the required duration, and
          // the batch isn't already at its scan limit. Disarm immediately
          // (before the capture's own async gap) so a second frame landing
          // before [_capture] sets [_isCapturing] can't double-fire.
          final stableSince = _autoCaptureStableSince;
          if (_autoCaptureArmed &&
              !_isCapturing &&
              _liveVerdict == AlignmentVerdict.green &&
              stableSince != null &&
              now.difference(stableSince) >= _autoCaptureStableDuration &&
              appState.scanLimitBlockMessage == null) {
            _autoCaptureArmed = false;
            if (kOmrPerfDebug) {
              omrPerfLog(
                'stabilityWait=${now.difference(stableSince).inMilliseconds}ms',
              );
            }
            unawaited(_capture(appState, manual: false));
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (myGen == _cameraGeneration) _frameCheckInFlight = false;
          debugPrint('[ExamScanning] live corner check failed: $error');
          if (!mounted || myGen != _cameraGeneration) return;
          // A failed check gives no information about this frame — leaving
          // the previous check's colors/verdict on screen would misrepresent
          // a frame that was never actually evaluated as still found (or
          // still not found). Clear back to the same neutral "unknown"
          // state shown before the very first check ever completes, rather
          // than freezing on whatever the last successful check happened to
          // read.
          setState(() {
            _liveCornersFound = null;
            _liveCornerPositions = null;
            _liveDiagnostics = null;
            _captureReadySince = null;
            _autoCaptureStableSince = null;
            _meanLuma = null;
          });
        });
  }

  /// Secondary low-light lever alongside the manual torch toggle: nudges
  /// the camera's exposure offset up while the scene reads dark, resets it
  /// back to normal once it doesn't. Skipped entirely while the torch is on
  /// (already plenty of light at that point — stacking an exposure boost on
  /// top risks overexposing/blowing out the sheet instead of helping) and
  /// only re-issued on actually crossing the low-light threshold (via
  /// [_exposureNudged]), not on every throttled frame check.
  Future<void> _maybeNudgeExposure(double meanLuma) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final isLowLight = meanLuma < _lowLightLumaThreshold && !_torchOn;
    if (!isLowLight) {
      if (_exposureNudged) {
        _exposureNudged = false;
        try {
          await controller.setExposureOffset(0);
        } catch (_) {
          // Not all devices/lenses support exposure offset control.
        }
      }
      return;
    }
    if (_exposureNudged) return;
    try {
      final maxOffset = await controller.getMaxExposureOffset();
      // A conservative fraction of the device's own max range -- enough to
      // help recover shadow detail without blowing out highlights once the
      // (already light-colored) sheet fills most of the frame.
      await controller.setExposureOffset(maxOffset * 0.5);
      _exposureNudged = true;
    } catch (_) {
      // Not all devices/lenses support exposure offset control; capture
      // still works with whatever the platform default is.
    }
  }

  /// Manual torch toggle — deliberately not automatic. Auto-enabling flash
  /// the moment the scene reads dark would surprise the user, drain battery
  /// without their say-so, and risk glare on glossy/laminated paper with no
  /// accuracy upside over a one-tap toggle they control themselves. The live
  /// low-light hint (see [_buildViewfinder]) tells them when it's worth
  /// tapping; this is what actually flips it.
  Future<void> _toggleTorch() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final next = !_torchOn;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (!mounted) return;
      setState(() => _torchOn = next);
    } catch (_) {
      // Not all devices/lenses support flash/torch control.
    }
  }

  /// Sets both the focus AND exposure point to the same [point] (a
  /// (0,0)-(1,1) fraction of the *displayed preview*, matching
  /// `CameraController.setFocusPoint`/`setExposurePoint`'s own contract) —
  /// paired because a re-exposed image can shift what looks sharp, and
  /// because a device that supports one but not the other should still get
  /// whichever it can (each call is independently guarded, never let one
  /// throwing skip the other). Silently a no-op on a device/lens that
  /// supports neither; capture still works, just without this hint.
  ///
  /// Called once with the frame center at camera setup (see
  /// [_setUpCamera]) so continuous AF/AE actually has a region to start
  /// from instead of whatever it happened to lock onto before the sheet
  /// was in frame, and again on every tap-to-focus (see
  /// [_buildCameraLayer]'s `GestureDetector`) so staff can redirect it
  /// onto the actual sheet if it's hunting on the background/hand instead
  /// — this needs on-device confirmation either helps; digital sharpening
  /// cannot substitute for the camera actually focusing correctly, and
  /// this is not assumed to fully resolve TAT's reported focus struggles
  /// without that confirmation.
  Future<void> _focusOnPoint(CameraController controller, Offset point) async {
    try {
      await controller.setFocusPoint(point);
    } catch (_) {
      // Not all devices/lenses support an explicit focus point.
    }
    try {
      await controller.setExposurePoint(point);
    } catch (_) {
      // Not all devices/lenses support an explicit exposure point.
    }
  }

  /// Handles a tap-to-focus gesture on the live viewfinder — maps the
  /// tap's widget-local position through the exact same `BoxFit.cover` fit
  /// [_buildCameraLayer] displays the preview with (see
  /// `fiducial_coordinate_mapping.dart`'s `widgetOffsetToFraction`) so the
  /// resulting focus point lands on whatever the user actually tapped,
  /// not a widget-pixel position naively treated as already being that
  /// fraction. [previewSize] is the same logical (already
  /// orientation-swapped for portrait vs. landscape/TAT) size
  /// [_buildCameraLayer] itself computes as the preview's displayed
  /// source size for its own `BoxFit.cover`.
  void _onViewfinderTap(TapUpDetails details, Size boxSize, Size previewSize) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final fraction = widgetOffsetToFraction(
      position: details.localPosition,
      sourceSize: previewSize,
      destSize: boxSize,
    );
    unawaited(_focusOnPoint(controller, fraction));
  }

  /// [manual] distinguishes the two ways this can be triggered, since they
  /// have deliberately different gates:
  ///  * `manual: true` — the "Scan Next"/"Capture" button. The low-resolution
  ///    live detector is advisory only here: it never blocks a manual
  ///    capture, because it operates on a downscaled preview frame
  ///    ([_liveCheckMaxDimension]) and a single corner reading `none` there
  ///    is not proof the real, full-resolution photo will fail — that
  ///    question is answered by the authoritative [_checkAlignment]/
  ///    `locateCorners` call below, on the actual captured file, same as
  ///    always. Gated only on the camera being ready, no capture already
  ///    in flight, and the batch's own scan-count cap.
  ///  * `manual: false` — the auto-capture path. Its own strict gate (all 4
  ///    [CornerConfidence.confident], motion-stability held for
  ///    [_autoCaptureStableDuration]) is already verified atomically at the
  ///    trigger site in [_onCameraFrame], immediately before this call —
  ///    nothing further to re-derive here.
  ///
  /// Neither path skips or loosens the full-resolution alignment/warp check
  /// below, and there is no "use anyway" bypass on a failure — a photo that
  /// fails it is always discarded, exactly as before.
  Future<void> _capture(AppState appState, {required bool manual}) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }
    // Same defensive re-check for the batch's scan-count cap: the button is
    // already disabled once this is non-null (see build()), but this is
    // what actually stops a capture from happening — not just its visual
    // state. The durable, unbypassable enforcement is still
    // BatchRepository.addScan's own check at save time; this only avoids
    // wasting a photo the batch could never accept.
    final limitMessage = appState.scanLimitBlockMessage;
    if (limitMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(limitMessage)));
      return;
    }

    setState(() => _isCapturing = true);
    final captureSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
    var takePictureMs = 0;
    var alignmentMs = 0;
    try {
      final takePictureSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      final file = await controller.takePicture();
      if (takePictureSw != null) takePictureMs = takePictureSw.elapsedMilliseconds;
      // Landscape-page templates (TAT) only: physically rotate the raw
      // capture to upright using the device's ACTUAL orientation at the
      // moment of capture, before anything else ever reads this file --
      // see [OmrDecoder.normalizeCaptureOrientation]'s doc comment for why
      // this can't be left to the decoder's own content-based rotation
      // search (a printed corner square looks identical under any 90°
      // rotation, so that search can "succeed" on the wrong one).
      if (_isLandscapeExam) {
        final quarterTurns =
            _deviceOrientationQuarterTurns[controller.value.deviceOrientation] ?? 0;
        // TEMPORARY diagnostic (2026-09-14): testing the hypothesis that
        // CameraController.value.deviceOrientation never updates from its
        // hardcoded portraitUp default for this screen -- the underlying
        // platform stream (onDeviceOrientationChanged) only fires on an
        // actual ORIENTATION CHANGE, but TAT locks the device to landscape
        // (see didChangeDependencies) BEFORE the camera controller is even
        // created, so there may be no "change" left for it to ever report,
        // silently leaving quarterTurns at 0 (skipping normalization
        // entirely) even though the phone is physically landscape.
        debugPrint(
          '[ExamScanning] TAT capture orientation: '
          'deviceOrientation=${controller.value.deviceOrientation} quarterTurns=$quarterTurns',
        );
        if (quarterTurns != 0) {
          await compute(
            _normalizeCaptureOrientation,
            _NormalizeOrientationRequest(file.path, quarterTurns),
          );
        }
      }
      final template = omrTemplates[appState.activeExamCode];
      if (template != null) {
        final alignmentSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
        final check = await compute(
          _checkAlignment,
          _AlignmentCheckRequest(file.path, template),
        );
        if (alignmentSw != null) alignmentMs = alignmentSw.elapsedMilliseconds;
        if (!check.aligned) {
          if (kOmrPerfDebug) {
            omrPerfLog(
              'capture rejected exam=${template.examCode} '
              'warpRejected=${check.warpRejected} '
              'errors=${check.reprojectionErrorPx} reason=${check.message}',
            );
          }
          // Best-effort diagnostic dump so a rejection actually leaves
          // something to inspect afterward -- a rejected photo is never
          // added to the batch, so without this it vanishes with nothing
          // but the dialog's own message. Fire-and-forget: must never
          // delay the dialog or affect the scanning flow on failure.
          unawaited(() async {
            final debugDir = await appState.prepareDebugImagesDir();
            if (debugDir == null) return;
            try {
              await compute(
                _saveRejectedCaptureDebugViz,
                _RejectedCaptureDebugVizRequest(file.path, template, debugDir),
              );
            } catch (_) {}
          }());
          // The live check above is advisory-strength (a lower-effort
          // preview frame); this one runs the real decoder's corner search
          // against the actual captured photo and is authoritative. No
          // bypass — a photo that fails this is always discarded, never
          // added to the batch, so an unconfirmed page geometry can never
          // reach perspective correction, bubble sampling, or scoring.
          if (!mounted) return;
          await _showMisalignedDialog(check.message);
          return;
        }
      }
      if (!mounted) return;
      final decoded = await appState.previewCapturedPage(file);
      if (!mounted) return;
      if (appState.rescanScanId != null) {
        // A rescan never saves straight from the camera: the photo has passed
        // the alignment and decoding checks, so hand it to a person to
        // compare against the original sheet before anything is replaced.
        _autoCaptureArmed = false;
        await _reviewRescanCandidate(appState);
        return;
      }
      final scored = scoreOmrResult(
        decoded, appState.answerKeys[decoded.examCode],
      );
      final score = computeExamScoreForCode(scored);
      // Hold the shutter lock while the score is visible. Rearm automatic
      // capture only after the user removes or repositions this sheet.
      _autoCaptureArmed = false;
      final endSession = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text('Sheet ${appState.currentScannedPage}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  score != null && score.isGraded
                      ? '${score.rawScore} / ${score.isTat ? 160 : score.totalItems}'
                      : 'No answer key available',
                  style: Theme.of(context).textTheme.headlineLarge,
                  textAlign: TextAlign.center,
                ),
                if (score != null && score.isGraded && score.totalGraded < score.totalItems)
                  const Text('Partial answer key'),
                if (scored.items.any((item) => item.isAmbiguous))
                  const Text('Preliminary score — some answers need review.'),
              ],
            ),
            actions: [
              if (appState.rescanScanId == null)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('End Session'),
                ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(appState.rescanScanId != null
                    ? 'Save Rescan'
                    : appState.scanLimitBlockMessage != null
                        ? 'Continue' : 'Next Sheet'),
              ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (captureSw != null) {
        omrPerfLog(
          'capture pageIndex=${appState.currentScannedPage} takePicture=${takePictureMs}ms '
          'alignment=${alignmentMs}ms total=${captureSw.elapsedMilliseconds}ms',
        );
      }
      // A rescan replaces exactly one sheet — there's nothing to wait for
      // after a successful capture (no "add more pages, then compile" step
      // like a normal multi-sheet session), so go straight to processing
      // and saving instead of leaving the user to find and tap a second
      // "Save Rescan" button. _compileData already handles the full
      // decode → finishRescan → pop-back-to-archive sequence and all its
      // own error/mounted handling.
      if (appState.rescanScanId != null || endSession == true) {
        await _compileData(appState);
      }
    } on CameraException catch (e) {
      debugPrint('[ExamScanning] capture failed: ${e.code} ${e.description}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: ${e.description ?? e.code}')),
      );
    } catch (e) {
      debugPrint('[ExamScanning] capture failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    } finally {
      // Unconditional, not gated on `mounted`: this flag also guards
      // re-entry at the very top of this method (before any `await`), so
      // it must always be cleared even if the widget was disposed mid-
      // capture — otherwise a lingering `true` here serves no purpose (the
      // State object is gone) but the `setState` guard below still needs
      // the `mounted` check to avoid calling setState on a disposed State.
      _isCapturing = false;
      if (mounted) setState(() {});
    }
  }

  /// Informational only — always ends with the photo discarded. There is
  /// no "use anyway" option: a page whose 4 corners weren't confirmed on
  /// the actual captured photo is always rejected, per the hard
  /// all-4-corners requirement.
  Future<void> _showMisalignedDialog(String? message) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Page not fully detected'),
        content: Text(
          message ??
              'Page not fully detected. Please align the sheet and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Future<void> _compileData(AppState appState) async {
    // A rescan is never saved from here: it always goes through the
    // comparison panel, which is the only path that can replace a sheet.
    if (appState.rescanScanId != null) {
      await _reviewRescanCandidate(appState);
      return;
    }
    await appState.processCapturedPages();
    if (!mounted) return;
    if (appState.scanProcessingError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not process the scan: ${appState.scanProcessingError}',
          ),
        ),
      );
      return;
    }
    // Content-based "same physical sheet scanned twice" check (not used for
    // a rescan, which is handled above and expected to match its own slot).
    final warnings = _duplicateScanWarnings(appState);
    if (warnings.isNotEmpty) {
      final proceed = await _showDuplicateScanDialog(warnings);
      if (!mounted) return;
      if (!proceed) return;
    }

    // Quality gate: the conditions that have to hold for a read to be
    // trusted. Last before the results screen on purpose -- the sheets are
    // decoded by now, so this can report what actually went wrong rather
    // than guessing from the preview, and the captures are still in hand so
    // "Scan Again" costs one retake instead of a trip back through the
    // archive. Advisory: see ScanQualityGate for why a hard block would be
    // worse than the problem.
    final failedQuality = ScanQualityGate.inspectSession(appState.scannedResults);
    if (failedQuality.isNotEmpty) {
      final acceptAnyway = await showScanQualityDialog(context, failedQuality);
      if (!mounted) return;
      if (!acceptAnyway) return;
    }

    Navigator.of(context).pushReplacementNamed(AppRoutes.examResults);
  }

  /// Compare-before-replace for a rescan: shows the stored sheet next to the
  /// new photo and only replaces the original if a person confirms it is the
  /// same physical sheet. Nothing is saved before that; Cancel, back and
  /// dismissal discard the candidate and leave the original untouched, and
  /// Retake photo discards it and returns to capture.
  ///
  /// The candidate was already decoded when it was captured, so the panel and
  /// the eventual save reuse that result — nothing is decoded again here.
  /// This is a human verification safeguard, not proof of identity.
  Future<void> _reviewRescanCandidate(AppState appState) async {
    final batch = appState.scanBatch;
    final scanId = appState.rescanScanId;
    if (batch == null || scanId == null || appState.capturedPages.isEmpty) return;
    final repo = appState.batchRepository;

    // Reading the name crops takes a moment; show that instead of a frozen
    // camera screen.
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
    ));

    LocalScan? original;
    RescanCandidate? candidate;
    ImageProvider? originalSheet;
    ImageProvider? originalLast;
    ImageProvider? originalFirst;
    ImageProvider? originalMiddle;
    try {
      // The stored sheet AS IT IS NOW — this exact record is what a later save
      // is checked against, so a change made while comparing is caught.
      final fresh = await repo.getBatchById(batch.id);
      original = fresh?.scans.where((s) => s.id == scanId).firstOrNull;
      candidate = await appState.prepareRescanCandidate();
      if (original != null) {
        var bytes = await repo.resolveScanImage(batch.id, original);
        if (bytes == null) {
          // A cloud-restored sheet whose photo hasn't been downloaded yet.
          await appState.cloudRestoreService?.restoreImageIfMissing(
            batchId: batch.id,
            scan: original,
            rectified: false,
          );
          bytes = await repo.resolveScanImage(batch.id, original);
        }
        if (bytes != null) originalSheet = ResizeImage(MemoryImage(bytes), width: 1400, allowUpscaling: false);
        Future<ImageProvider?> crop(Future<Uint8List?> Function() load) async {
          final b = await load();
          return b == null ? null : MemoryImage(b);
        }

        originalLast = await crop(() => repo.resolveScanNameCropLast(batch.id, original!));
        originalFirst = await crop(() => repo.resolveScanNameCropFirst(batch.id, original!));
        originalMiddle = await crop(() => repo.resolveScanNameCropMiddle(batch.id, original!));
      }
    } catch (e) {
      debugPrint('[ExamScanning] rescan comparison prep failed: $e');
    } finally {
      if (mounted) rootNavigator.pop();
    }
    if (!mounted) return;

    if (original == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The original sheet no longer exists. Nothing was replaced.')),
      );
      appState.cancelRescan();
      Navigator.of(context).pop();
      return;
    }
    if (candidate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not prepare the new photo for comparison. Please retake it.')),
      );
      appState.discardRescanCandidate();
      return;
    }

    ImageProvider? file(String? path) => path == null ? null : FileImage(File(path));
    final stored = original;
    final cand = candidate;
    final data = RescanComparisonData(
      comparison: RescanComparison.build(
        original: stored,
        candidate: cand.decoded,
        answerKey: appState.answerKeys[batch.examCode],
      ),
      originalExaminee: stored.examinee,
      originalCapturedAt: stored.capturedAt,
      originalSheet: originalSheet,
      originalCropLast: originalLast,
      originalCropFirst: originalFirst,
      originalCropMiddle: originalMiddle,
      candidateSheet: ResizeImage(FileImage(File(cand.photoPath)), width: 1400, allowUpscaling: false),
      candidateCropLast: file(cand.nameCropLastPath),
      candidateCropFirst: file(cand.nameCropFirstPath),
      candidateCropMiddle: file(cand.nameCropMiddlePath),
      ocrLastName: cand.ocrLastName,
      ocrFirstName: cand.ocrFirstName,
      ocrMiddleName: cand.ocrMiddleName,
      ocrSuggestionWillBeSaved: rescanWillFillNamesFromOcr(
        existing: stored.examinee,
        ocrLastName: cand.ocrLastName,
        ocrFirstName: cand.ocrFirstName,
        ocrMiddleName: cand.ocrMiddleName,
      ),
    );

    final decision = await Navigator.of(context).push<RescanDecision>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RescanComparisonScreen(
          data: data,
          onConfirm: () async {
            // Reuses the decode the capture already produced (no second decode).
            await appState.processCapturedPages();
            if (appState.scanProcessingError != null) {
              return RescanConfirmOutcome.failed(
                'Could not process the scan: ${appState.scanProcessingError}',
              );
            }
            // Only reachable once the reviewer ticked the verification box.
            final ok = await appState.finishRescan(expectedOriginal: stored, identityVerified: true);
            if (ok) return const RescanConfirmOutcome.saved();
            return RescanConfirmOutcome.failed(
              appState.rescanSaveError ?? 'Could not save the rescan.',
              canRetry: !appState.rescanOriginalChanged,
            );
          },
        ),
      ),
    );
    if (!mounted) return;
    switch (decision) {
      case RescanDecision.saved:
        Navigator.of(context).pop(); // back to wherever Rescan was tapped
      case RescanDecision.retake:
        appState.discardRescanCandidate(); // stay on the camera
      case RescanDecision.cancelled:
      case null:
        appState.cancelRescan();
        Navigator.of(context).pop();
    }
  }

  /// Human-readable warnings for every pair of decoded sheets that look
  /// like the same physical sheet scanned twice — both within this
  /// session's own captures, and against sheets already saved to
  /// [AppState.scanBatch] from an earlier session. Empty when nothing
  /// looks duplicated. See duplicate_scan_detector.dart for the matching
  /// rule.
  List<String> _duplicateScanWarnings(AppState appState) {
    final results = appState.scannedResults;
    final warnings = <String>[];
    for (final match in findDuplicateScanPairs(results)) {
      warnings.add(
        'Sheet ${match.indexA + 1} looks like the same sheet as Sheet ${match.indexB + 1} you just scanned.',
      );
    }
    final batch = appState.scanBatch;
    if (batch != null) {
      for (var i = 0; i < results.length; i++) {
        for (final scan in batch.scans) {
          if (!looksLikeDuplicateScan(results[i], scan.decoded)) continue;
          final examinee = scan.examinee;
          final label = (examinee != null && !examinee.isEmpty)
              ? examinee.displayName
              : 'an already-saved sheet';
          warnings.add('Sheet ${i + 1} looks like a duplicate of $label already saved to this batch.');
        }
      }
    }
    return warnings;
  }

  /// Advisory only — staff can always continue. Never blocks the save the
  /// way [_showMisalignedDialog] blocks a bad photo, since a false positive
  /// here is possible (a short exam, or two students who genuinely answered
  /// identically) and there's no way to discard just one already-captured
  /// sheet from this screen.
  Future<bool> _showDuplicateScanDialog(List<String> warnings) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Possible duplicate sheet'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('These scans look like the same physical sheet was scanned more than once:'),
              const SizedBox(height: 8),
              ...warnings.map((w) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('•  $w'),
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Review First'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue Anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Bottom-panel status line, above the Scan Next / Compile Data buttons.
  String _statusText(AppState appState) {
    // Checked first (ahead of the capturedPages.isEmpty case below) since
    // capacity can run out mid-session, with pages already captured —
    // "batch full" is the more useful thing to say at that point than a
    // sheet count, and Compile Data (saving what's captured so far) is
    // still exactly the right next step, just not another capture.
    if (appState.scanLimitBlockMessage != null) {
      return 'BATCH FULL — COMPILE DATA TO SAVE WHAT YOU HAVE';
    }
    if (appState.capturedPages.isEmpty) return 'ALIGN SHEET AND CAPTURE';
    if (appState.rescanScanId != null) {
      // Capturing again while rescanning is a retake, not an additional
      // sheet -- only the most recent photo gets saved (see
      // AppState.finishRescan), so the count shown for a normal session
      // would be misleading here.
      return 'READY — LATEST PHOTO WILL BE SAVED';
    }
    final n = appState.capturedPages.length;
    return '$n SHEET${n == 1 ? '' : 'S'} CAPTURED';
  }

  String _compileButtonLabel(AppState appState) =>
      appState.rescanScanId != null ? 'Save Rescan' : 'Compile Data';

  static const _defaultCornerFractions = [
    (0.05, 0.05),
    (0.95, 0.05),
    (0.05, 0.95),
    (0.95, 0.95),
  ];

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final activeTemplate = omrTemplates[appState.activeExamCode];
    // Only the old landscape TAT sheet (TAT-redesign-v*) was printed sideways;
    // the current portrait TAT and AT/QTM use their corner marks as printed.
    final rotatedSheet = activeTemplate != null &&
        activeTemplate.pageWidthPt > activeTemplate.pageHeightPt;
    final cornerFractions = activeTemplate == null
        ? _defaultCornerFractions
        : rotatedSheet
            ? [for (final i in [2, 0, 3, 1])
                (1 - activeTemplate.cornerMarkers[i].yFrac,
                 activeTemplate.cornerMarkers[i].xFrac)]
            : activeTemplate.cornerMarkers.map((c) => (c.xFrac, c.yFrac)).toList();

    // The 4 corner marks aren't necessarily near the page's literal
    // (0,0)-(1,1) edges (a narrow bubble grid leaves them well inside the
    // page — see the comment on OmrDecoder.decode's dstCorners), so the
    // guide box's real-world aspect ratio has to come from the marks'
    // actual bounding box, not the full page's aspect ratio, or the guide
    // rectangle drawn on screen won't match the marks' true proportions.
    final pageWidthPt = (rotatedSheet ? activeTemplate.pageHeightPt : activeTemplate?.pageWidthPt) ?? 595.28;
    final pageHeightPt = (rotatedSheet ? activeTemplate.pageWidthPt : activeTemplate?.pageHeightPt) ?? 841.89;
    final markerXs = [for (final c in cornerFractions) c.$1];
    final markerYs = [for (final c in cornerFractions) c.$2];
    final markerAspectRatio =
        ((markerXs.reduce(math.max) - markerXs.reduce(math.min)) *
            pageWidthPt) /
        ((markerYs.reduce(math.max) - markerYs.reduce(math.min)) *
            pageHeightPt);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final topBar = _buildTopBar(appState);
            final viewfinder = _buildViewfinder(
              cornerFractions,
              markerAspectRatio,
            );
            final bottomPanel = _buildBottomPanel(appState);

            // Landscape-page exam (TAT): the device is actually rotated to
            // landscape for this screen (see didChangeDependencies), so
            // the camera feed itself is genuinely landscape — no widget
            // rotation trick needed (an earlier version tried RotatedBox
            // for this on a still-portrait device instead; that fought the
            // camera's hardware texture and rendered black).
            //
            // The control dock gets its own reserved column via Row, not
            // a Positioned overlay on top of the full-screen camera — an
            // earlier version overlaid it, and since the guide box (see
            // _PageGuidePainter) already sizes itself close to filling the
            // whole viewfinder, any corner the dock overlaid ended up
            // covering part of the guide box or its corner brackets
            // instead of sitting in genuinely empty space. Giving it a
            // dedicated width the camera/guide area never renders into
            // guarantees no overlap regardless of the guide box's size.
            if (_isLandscapeExam) {
              return Column(
                children: [
                  topBar,
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: viewfinder),
                        SizedBox(
                          width: 190,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
                            child: Center(
                              child: _buildCompactControls(appState),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            return Column(
              children: [
                topBar,
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: viewfinder,
                  ),
                ),
                bottomPanel,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar(AppState appState) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 16),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (appState.scanBatchCode != null)
                Text(
                  '${appState.scanBatchCode} · ${appState.activeExamCode}',
                  style: const TextStyle(
                    color: Color(0xFF6EE7B7),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              Text(
                'Sheet Document #${appState.currentScannedPage + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Available in release, unlike the bug icon below: staff need
              // to be able to capture how a sheet was read without a special
              // build. Enabled by default during scanner development.
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => setState(() {
                    _debugImagesEnabled = !_debugImagesEnabled;
                    _appState.debugImagesEnabled = _debugImagesEnabled;
                  }),
                  child: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _debugImagesEnabled
                          ? AppColors.accentYellowGreen
                          : Colors.black.withOpacity(0.4),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.layers_outlined,
                      color: _debugImagesEnabled ? Colors.black : Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
              // TEMPORARY developer tool, debug-build-only and off by
              // default (see [_diagnosticsEnabled]) — never shown in a
              // release build, so this can't reach end users.
              if (kDebugMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    onTap: () => setState(() {
                      _diagnosticsEnabled = !_diagnosticsEnabled;
                      _appState.diagnosticsEnabled = _diagnosticsEnabled;
                    }),
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _diagnosticsEnabled
                            ? AppColors.accentYellowGreen
                            : Colors.black.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.bug_report_outlined,
                        color: _diagnosticsEnabled ? Colors.black : Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              InkWell(
                onTap: _cameraController?.value.isInitialized == true ? _toggleTorch : null,
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _torchOn
                        ? AppColors.accentYellowGreen
                        : Colors.black.withOpacity(0.4),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _torchOn ? Icons.flash_on : Icons.flash_off,
                    color: _torchOn ? Colors.black : Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildViewfinder(
    List<(double, double)> cornerFractions,
    double markerAspectRatio,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        children: [
          Positioned.fill(child: _buildCameraLayer()),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _scanWindowBorderColor.withOpacity(0.85),
                  width: 3,
                ),
              ),
            ),
          ),
          if (_cameraController?.value.isInitialized == true) ...[
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _PageGuidePainter(
                    cornerFractions,
                    markerAspectRatio,
                    _liveCornersFound,
                  ),
                ),
              ),
            ),
            if (_diagnosticsEnabled &&
                _liveDiagnostics != null &&
                _cameraController!.value.previewSize != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _DiagnosticOverlayPainter(
                      _liveDiagnostics!,
                      searchedFrameSize(
                        _cameraController!.value.previewSize!,
                        rotated90: _liveRotation != FrameRotation.none,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 14,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppColors.accentYellowGreen.withOpacity(0.2),
                    ),
                  ),
                  child: Text(
                    _viewfinderCaption(),
                    style: TextStyle(
                      // Amber for the capture-anyway hint: it is an
                      // invitation to act, and the low-light red reads as a
                      // prohibition.
                      color: _showCaptureAnyway
                          ? const Color(0xFFF59E0B)
                          : (_isLowLight
                              ? AppColors.warmRedOrange
                              : const Color(0xFF6EE7B7)),
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomPanel(AppState appState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black,
            Colors.black.withOpacity(0.95),
            Colors.transparent,
          ],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withOpacity(0.9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.slate800),
        ),
        child: Column(
          children: [
            Text(
              _statusText(appState),
              style: const TextStyle(
                color: Color(0xFF34D399),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            if (appState.activeExamCode == 'TAT') ...[
              const SizedBox(height: 4),
              const Text(
                'Hold the sheet upright: name fields at the top, title on the '
                'right edge. Keep the small squares above each test visible.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _cameraController?.value.isInitialized == true &&
                            !_isCapturing &&
                            appState.scanLimitBlockMessage == null
                        ? () => _capture(appState, manual: true)
                        : null,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.slate800,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.slate800.withOpacity(
                        0.4,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isCapturing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            // A rescan replaces one specific sheet — there is
                            // no "next" sheet to scan, so the button says
                            // what it actually does here instead.
                            appState.rescanScanId != null ? 'Capture' : 'Scan Next',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        appState.capturedPages.isNotEmpty &&
                            !appState.isProcessingScans &&
                            !appState.isSavingRescan
                        ? () => _compileData(appState)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      disabledBackgroundColor: AppColors.primaryGreen
                          .withOpacity(0.35),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: appState.isProcessingScans || appState.isSavingRescan
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _compileButtonLabel(appState),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Compact stand-in for [_buildBottomPanel], used only in the landscape
  /// (TAT) layout — same status text and Scan Next / Compile Data buttons,
  /// but sized to sit directly under the right-side preview panel rather
  /// than as a large dark gradient bar spanning the full screen width.
  Widget _buildCompactControls(AppState appState) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.slate800),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _statusText(appState),
            style: const TextStyle(
              color: Color(0xFF34D399),
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed:
                      _cameraController?.value.isInitialized == true &&
                          !_isCapturing &&
                          appState.scanLimitBlockMessage == null
                      ? () => _capture(appState, manual: true)
                      : null,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AppColors.slate800,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.slate800.withOpacity(
                      0.4,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: _isCapturing
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          appState.rescanScanId != null ? 'Capture' : 'Scan Next',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      appState.capturedPages.isNotEmpty &&
                          !appState.isProcessingScans &&
                          !appState.isSavingRescan
                      ? () => _compileData(appState)
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    disabledBackgroundColor: AppColors.primaryGreen.withOpacity(
                      0.35,
                    ),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: appState.isProcessingScans || appState.isSavingRescan
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _compileButtonLabel(appState),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCameraLayer() {
    if (_cameraError != null) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white54,
              size: 32,
            ),
            const SizedBox(height: 12),
            Text(
              _cameraError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () =>
                  setState(() => _initializeFuture = _setUpCamera()),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return FutureBuilder<void>(
      future: _initializeFuture,
      builder: (context, snapshot) {
        final controller = _cameraController;
        if (snapshot.connectionState == ConnectionState.done &&
            controller == null &&
            _cameraError == null) {
          return Container(
            color: Colors.black,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.videocam_off_outlined,
                  color: Colors.white54,
                  size: 32,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Could not start the camera.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () =>
                      setState(() => _initializeFuture = _setUpCamera()),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                  ),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        if (controller == null || !controller.value.isInitialized) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(
              child: CircularProgressIndicator(
                color: AppColors.accentYellowGreen,
              ),
            ),
          );
        }
        // previewSize is reported in the sensor's own landscape-native
        // terms regardless of the app's current UI orientation, so it only
        // needs swapping to display upright when the UI itself is
        // portrait. A landscape-page exam (TAT) unlocks real landscape
        // device rotation (see didChangeDependencies), so once the device
        // is actually landscape, the sensor's native terms already match
        // the UI and swapping them would rotate the preview 90° wrong --
        // confirmed against a real capture, where forcing the swap (or
        // wrapping the whole widget in a RotatedBox as an earlier version
        // tried) produced a black/broken preview instead of a rotated one.
        final previewWidth = _isLandscapeExam
            ? controller.value.previewSize!.width
            : controller.value.previewSize!.height;
        final previewHeight = _isLandscapeExam
            ? controller.value.previewSize!.height
            : controller.value.previewSize!.width;
        final previewSize = Size(previewWidth, previewHeight);
        return LayoutBuilder(
          builder: (context, constraints) {
            final boxSize = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) =>
                  _onViewfinderTap(details, boxSize, previewSize),
              child: SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: previewWidth,
                    height: previewHeight,
                    child: CameraPreview(controller),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Draws the overall sheet-alignment frame (a dimmed spotlight sized to the
/// real proportions of the rectangle spanned by the sheet's 4 fiducial
/// marks — see [markerAspectRatio] — plus a visible outline on it, for
/// general "the sheet goes here" positioning) **and**, separately, four
/// ZipGrade-style fiducial viewfinder boxes, one per printed black corner
/// square. The four boxes are the primary guide for *precise* fiducial
/// placement — always visible, before any detection happens, each colored
/// independently from its own [cornersFound] tier (gray/red/amber/green) —
/// so a "3/4 corner marks locked" status is immediately traceable to
/// exactly which corner is the problem, not just a count.
///
/// The boxes are a visual guide and a live-search prior only — see
/// omr_decoder_native.dart's Stage-1/Stage-2 search — never a hard crop:
/// the full-resolution post-capture pass (and, on a Stage-1 miss, the live
/// search itself) always falls through to searching the whole photo
/// quadrant, so a sheet photographed at an angle with a marker outside its
/// box still gets found and still validates.
class _PageGuidePainter extends CustomPainter {
  const _PageGuidePainter(
    this.cornerFractions,
    this.markerAspectRatio,
    this.cornersFound,
  );

  /// The active exam template's corner-marker fractional (xFrac, yFrac)
  /// positions, in [top-left, top-right, bottom-left, bottom-right] order.
  final List<(double, double)> cornerFractions;

  /// Real-world width/height of the rectangle spanned by the 4 marks
  /// (computed by the caller from the marks' own bounding box in page
  /// points, not the full page's aspect ratio).
  final double markerAspectRatio;

  /// Live per-corner detection state, same order as [cornerFractions].
  /// Null until the first live check completes, in which case every
  /// viewfinder draws neutral (still visible — it's the placement guide).
  final List<CornerConfidence>? cornersFound;

  static const double _insetFraction = 0.06;

  /// Viewfinder box size, as a fraction of the overall guide rectangle's
  /// shorter side, clamped to a sensible on-screen pixel range so it reads
  /// clearly on both a small phone and a tablet. Shared with the
  /// detector's Stage-1 search-box sizing (`fiducial_search_tuning.dart`)
  /// so the box a user aims for and the actual search prior it represents
  /// can never drift apart — tune there, not here.
  static const double _boxSizeFraction = kFiducialViewfinderBoxSizeFraction;
  static const double _boxMinSize = kFiducialViewfinderBoxMinSize;
  static const double _boxMaxSize = kFiducialViewfinderBoxMaxSize;
  static const double _boxStrokeWidth = 3;
  static const double _boxCornerRadius = 12;

  static const Color _neutralColor = Colors.white;
  static const Color _lowColor = Color(0xFFF59E0B); // amber

  @override
  void paint(Canvas canvas, Size size) {
    final maxWidth = size.width * (1 - _insetFraction * 2);
    final maxHeight = size.height * (1 - _insetFraction * 2);
    double guideWidth = maxWidth;
    double guideHeight = guideWidth / markerAspectRatio;
    if (guideHeight > maxHeight) {
      guideHeight = maxHeight;
      guideWidth = guideHeight * markerAspectRatio;
    }
    final guideRect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: guideWidth,
      height: guideHeight,
    );

    final dimPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(guideRect),
    );
    canvas.drawPath(dimPath, Paint()..color = Colors.black.withOpacity(0.55));

    // A visible outline on the overall target rectangle — general "the
    // sheet goes here" positioning. Not a replacement for the four
    // fiducial viewfinders below; both are shown together.
    canvas.drawRect(
      guideRect,
      Paint()
        ..color = Colors.white.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Four fiducial viewfinders, positioned by normalizing each marker's
    // page fraction against the 4 markers' own bounding box — the same
    // normalization that gives markerAspectRatio its value (see the
    // caller in build()) — so a box lands exactly on that marker's real
    // expected position within guideRect for any exam's layout, tolerant
    // of the sheet being rotated/keystoned since this is only ever a
    // *prior*, not a crop (see the class doc comment).
    final minX = cornerFractions.map((c) => c.$1).reduce(math.min);
    final maxX = cornerFractions.map((c) => c.$1).reduce(math.max);
    final minY = cornerFractions.map((c) => c.$2).reduce(math.min);
    final maxY = cornerFractions.map((c) => c.$2).reduce(math.max);
    final boxSize = (guideRect.shortestSide * _boxSizeFraction)
        .clamp(_boxMinSize, _boxMaxSize)
        .toDouble();

    for (var i = 0; i < cornerFractions.length; i++) {
      final (xFrac, yFrac) = cornerFractions[i];
      final localX = maxX > minX ? (xFrac - minX) / (maxX - minX) : 0.5;
      final localY = maxY > minY ? (yFrac - minY) / (maxY - minY) : 0.5;
      final point =
          guideRect.topLeft +
          Offset(localX * guideRect.width, localY * guideRect.height);
      final tier = cornersFound != null && i < cornersFound!.length
          ? cornersFound![i]
          : null;
      final color = switch (tier) {
        null => _neutralColor,
        CornerConfidence.none => AppColors.warmRedOrange,
        CornerConfidence.low => _lowColor,
        CornerConfidence.confident => AppColors.primaryGreen,
      };
      _drawViewfinderBox(canvas, point, boxSize, color, tier, _cornerLabels[i]);
    }
  }

  // Bottom-right intentionally left unlabeled (per user request) -- it
  // still gets its own viewfinder box/color/crosshair, just no text.
  static const _cornerLabels = ['TL', 'TR', 'BL', ''];

  /// Draws one rounded-square fiducial viewfinder centered on [point] —
  /// a light fill "zone" wash plus a stroked border in [color], always
  /// visible so it can guide placement before any marker has been found.
  /// Visual only — none of this reads or affects detection/capture timing:
  ///  * a center crosshair, for a precise aim point rather than just a
  ///    region to land somewhere inside;
  ///  * a [label] (TL/TR/BL/BR) so it's obvious at a glance which physical
  ///    corner a box refers to;
  ///  * once [tier] is [CornerConfidence.confident], a soft static glow
  ///    (blurred duplicate stroke) plus a bolder main stroke and a denser
  ///    fill wash, so a locked corner visibly "pops" rather than only
  ///    differing by color.
  void _drawViewfinderBox(
    Canvas canvas,
    Offset point,
    double boxSize,
    Color color,
    CornerConfidence? tier,
    String label,
  ) {
    final confident = tier == CornerConfidence.confident;
    final rect = Rect.fromCenter(center: point, width: boxSize, height: boxSize);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(_boxCornerRadius));

    if (confident) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _boxStrokeWidth + 4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    canvas.drawRRect(
      rrect,
      Paint()..color = color.withOpacity(confident ? 0.20 : 0.12),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color.withOpacity(0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = confident ? _boxStrokeWidth + 1 : _boxStrokeWidth,
    );

    const crosshairArm = 7.0;
    final crosshairPaint = Paint()
      ..color = color.withOpacity(0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawLine(
      point - const Offset(crosshairArm, 0),
      point + const Offset(crosshairArm, 0),
      crosshairPaint,
    );
    canvas.drawLine(
      point - const Offset(0, crosshairArm),
      point + const Offset(0, crosshairArm),
      crosshairPaint,
    );

    if (label.isEmpty) return;
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color.withOpacity(0.95),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(rect.left, rect.top - textPainter.height - 2),
    );
  }

  @override
  bool shouldRepaint(covariant _PageGuidePainter oldDelegate) =>
      !listEquals(cornerFractions, oldDelegate.cornerFractions) ||
      markerAspectRatio != oldDelegate.markerAspectRatio ||
      !listEquals(cornersFound, oldDelegate.cornersFound);
}

/// TEMPORARY, opt-in diagnostic overlay (see
/// [_ExamScanningScreenState._diagnosticsEnabled]) — draws what the decoder
/// actually searched and found for each corner in the most recent live
/// frame, deliberately distinct from [_PageGuidePainter]'s four
/// always-visible fixed aiming guides:
///
///  * a dashed box for each corner's actual Stage-1 search region (as
///    opposed to [_PageGuidePainter]'s fixed box, which is sized/placed
///    from the template alone and never moves even if the search region
///    itself shifts with a re-estimated page boundary — see
///    `_quadrantsFor`'s doc comment);
///  * a small dot at the actual detected centroid, when one was found —
///    this can land away from the fixed guide box, which is exactly the
///    "fixed guide vs. real search region" mismatch this overlay exists to
///    surface;
///  * an "x" at the expected anchor point the search was scored against;
///  * a short rejection-category label (shape/position/contrast/no
///    candidate) for any corner not already [CornerConfidence.confident].
///
/// Coordinate mapping: every [CornerDiagnostic] field is a fraction of the
/// live search's own winning-orientation frame. This paints them by
/// treating that fraction directly as a fraction of [sourceSize] (the
/// camera's logical preview size, oriented to match — see
/// `fiducial_coordinate_mapping.dart`'s own doc comment for the
/// on-device-unverified assumption this rests on) displayed with
/// `BoxFit.cover` inside this painter's own [size] — the same fit
/// `ExamScanningScreen._buildCameraLayer` uses for the live preview itself
/// (see [coverFit]/[fractionToWidgetOffset]).
class _DiagnosticOverlayPainter extends CustomPainter {
  const _DiagnosticOverlayPainter(this.diagnostics, this.sourceSize);

  final List<CornerDiagnostic> diagnostics;
  final Size sourceSize;

  static const _cornerNames = ['TL', 'TR', 'BL', 'BR'];

  Offset _map(double fx, double fy, Size destSize) => fractionToWidgetOffset(
        fx: fx,
        fy: fy,
        sourceSize: sourceSize,
        destSize: destSize,
      );

  String _categoryLabel(CornerRejectionCategory c) => switch (c) {
        CornerRejectionCategory.confident => 'ok',
        CornerRejectionCategory.shape => 'shape',
        CornerRejectionCategory.position => 'position',
        CornerRejectionCategory.contrast => 'contrast',
        CornerRejectionCategory.noCandidate => 'no candidate',
      };

  Color _categoryColor(CornerRejectionCategory c) => switch (c) {
        CornerRejectionCategory.confident => Colors.greenAccent,
        CornerRejectionCategory.noCandidate => Colors.redAccent,
        _ => Colors.amberAccent,
      };

  @override
  void paint(Canvas canvas, Size size) {
    // A small always-on-top caption naming the assumption this overlay's
    // mapping rests on (see this class's own doc comment) — the first
    // thing to question if the dots below look rotated/mirrored relative
    // to the fixed aim guides they're drawn alongside.
    final caption = TextPainter(
      text: const TextSpan(
        text: 'DIAGNOSTICS — search regions & actual detections '
            '(unverified rotation mapping)',
        style: TextStyle(
          color: Colors.cyanAccent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          backgroundColor: Colors.black54,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    caption.paint(canvas, Offset(8, size.height - caption.height - 8));

    for (var i = 0; i < diagnostics.length; i++) {
      final d = diagnostics[i];
      final color = _categoryColor(d.rejection);

      // Actual search box (dashed), distinct from the fixed aim guide.
      final topLeft = _map(d.searchBoxFrac.x0, d.searchBoxFrac.y0, size);
      final bottomRight = _map(d.searchBoxFrac.x1, d.searchBoxFrac.y1, size);
      _drawDashedRect(
        canvas,
        Rect.fromPoints(topLeft, bottomRight),
        Paint()
          ..color = color.withOpacity(0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      // Expected anchor ("x").
      final anchor = _map(d.anchorFrac.$1, d.anchorFrac.$2, size);
      const arm = 5.0;
      final anchorPaint = Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawLine(anchor - const Offset(arm, arm), anchor + const Offset(arm, arm), anchorPaint);
      canvas.drawLine(anchor - const Offset(arm, -arm), anchor + const Offset(arm, -arm), anchorPaint);

      // Actual detected centroid, when there is one.
      final centroidFrac = d.centroidFrac;
      Offset labelAnchor = anchor;
      if (centroidFrac != null) {
        final centroid = _map(centroidFrac.$1, centroidFrac.$2, size);
        canvas.drawCircle(centroid, 5, Paint()..color = color);
        canvas.drawCircle(
          centroid,
          5,
          Paint()
            ..color = Colors.black87
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        labelAnchor = centroid;
      }

      final label = '${_cornerNames[i]} ${_categoryLabel(d.rejection)} '
          'sq=${d.squareness.toStringAsFixed(2)} pos=${d.positionScore.toStringAsFixed(2)}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, labelAnchor + const Offset(8, 8));
    }
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint) {
    const dashLength = 5.0;
    const gapLength = 4.0;
    void dashedLine(Offset from, Offset to) {
      final total = (to - from).distance;
      if (total == 0) return;
      final direction = (to - from) / total;
      var drawn = 0.0;
      while (drawn < total) {
        final segmentEnd = math.min(drawn + dashLength, total);
        canvas.drawLine(
          from + direction * drawn,
          from + direction * segmentEnd,
          paint,
        );
        drawn = segmentEnd + gapLength;
      }
    }

    dashedLine(rect.topLeft, rect.topRight);
    dashedLine(rect.topRight, rect.bottomRight);
    dashedLine(rect.bottomRight, rect.bottomLeft);
    dashedLine(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(covariant _DiagnosticOverlayPainter oldDelegate) =>
      !identical(diagnostics, oldDelegate.diagnostics) ||
      sourceSize != oldDelegate.sourceSize;
}
