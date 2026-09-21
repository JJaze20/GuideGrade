import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:cross_file/cross_file.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:path_provider/path_provider.dart';

import '../../../core/camera/camera_frame_adapter.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/omr/duplicate_scan_detector.dart';
import '../../../core/omr/exam_score.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/fiducial_coordinate_mapping.dart';
import '../../../core/omr/fiducial_search_tuning.dart';
import '../../../core/omr/omr_decoder.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../core/utils/omr_perf_log.dart';

class _AlignmentCheckRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final bool diagnosticsEnabled;
  const _AlignmentCheckRequest(this.imagePath, this.template,
      {this.diagnosticsEnabled = false});
}

AlignmentCheck _checkAlignment(_AlignmentCheckRequest request) {
  OmrDecoder.setDiagnosticsEnabled(request.diagnosticsEnabled);
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

// _NormalizeOrientationRequest / _normalizeCaptureOrientation /
// _deviceOrientationQuarterTurns removed with the CamerAwesome migration:
// their only caller was the `_isLandscapeExam` branch of _capture, which
// read the old `camera` plugin's CameraController.value.deviceOrientation.
// That branch has been unreachable since the scanner became portrait-locked
// for every exam (`_isLandscapeExam` is always false), and CamerAwesome has
// no equivalent API. OmrDecoder.normalizeCaptureOrientation itself is
// untouched.

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
  /// CamerAwesome's live camera state (photo mode) — captured from the
  /// builder callback each time it runs; null until the preview is up and
  /// again after [_tearDownCamera]. Replaces the old `CameraController`.
  CameraState? _camState;

  /// True once CamerAwesome has left its preparing state and delivered a
  /// preview (first builder callback) for the CURRENT [_cameraKey] mount —
  /// the equivalent of the old `controller.value.isInitialized`.
  bool _cameraReady = false;

  bool get _cameraIsReady => _cameraReady && _camState != null;

  /// Created once per mount (see [_setUpCamera]) and reused across rebuilds:
  /// a SensorConfig owns stream controllers, so building a fresh one inside
  /// build() would leak one per frame and never match the mounted session.
  SensorConfig? _sensorConfig;
  AnalysisConfig? _analysisConfig;

  /// Whether the CameraAwesomeBuilder is mounted. Set false on pause so the
  /// widget (and with it the native camera session) is disposed, true again
  /// on resume; each mount gets a fresh [_cameraKey] so a stale session can
  /// never be reused — same "always a completely fresh camera" policy the
  /// controller-based version had.
  bool _cameraMounted = false;
  int _cameraKey = 0;

  /// Raw dimensions and clockwise-rotation-to-upright of the most recent
  /// analysis frame, used only to place the diagnostic overlay (see
  /// [camera_frame_adapter.dart]) — never fed to the detector.
  Size? _analysisFrameSize;
  int _analysisRotationDeg = 0;

  /// When this mount started / when its first preview and first live-corner
  /// result arrived — perf logging only ([kOmrPerfDebug]).
  Stopwatch? _mountSw;
  bool _loggedFirstFrame = false;
  bool _loggedFirstIndicator = false;
  bool _loggedFrameGeometry = false;
  DateTime? _lastFrameArrival;
  int _arrivalSumMs = 0;
  int _arrivalCount = 0;

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
  /// capture readiness. All-confident results also pass the capture alignment
  /// check before they can enable either shutter path.
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

  /// Start of the current streak of verified live alignment checks.
  DateTime? _captureReadySince;
  DateTime? _lastVerifiedFrameAt;
  static const Duration _requiredStableDuration = Duration(milliseconds: 500);
  static const Duration _maximumReadyFrameAge = Duration(milliseconds: 2500);

  /// Time of the last live check that had all four corners confident, and how
  /// long a single dropped check is forgiven. Live checks take 250-1700 ms on a
  /// real phone and the detector flickers frame to frame on tiny corner squares,
  /// so without this ONE bad check reset the whole streak and the guide could
  /// hardly stay green long enough to capture. A genuine loss of the sheet still
  /// turns the guide red after this grace.
  DateTime? _lastAllConfidentAt;
  static const Duration _liveGreenGrace = Duration(milliseconds: 1000);

  /// Shared by the caption, capture buttons, and the shutter guard.
  bool get _readyToCapture {
    final since = _captureReadySince;
    final checkedAt = _lastVerifiedFrameAt;
    final stableSince = _autoCaptureStableSince;
    final now = DateTime.now();
    return _liveVerdict == AlignmentVerdict.green &&
        since != null && checkedAt != null && stableSince != null &&
        now.difference(since) >= _requiredStableDuration &&
        now.difference(stableSince) >= _requiredStableDuration &&
        now.difference(checkedAt) <= _maximumReadyFrameAge;
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
  /// usual corner-alignment status when active (see [_isLowLight]).
  String _viewfinderCaption() {
    if (_isLowLight) return 'Low light — tap the flash icon';
    final found = _liveCornersFound;
    if (found == null) return 'Fit the whole sheet in view — all 4 black corner squares fully inside the frame';
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
        return 'Corner $name uncertain — move back so it is fully in view';
      case AlignmentVerdict.red:
        final missing = [
          for (var i = 0; i < found.length; i++)
            if (found[i] == CornerConfidence.none) _cornerNames[i],
        ];
        if (missing.length == 4) {
          return 'Fit the whole sheet in view — all 4 black corner squares fully inside the frame';
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
    // All exams use the portrait camera UI. TAT's printed page is rotated
    // into canonical coordinates by measured fiducials after capture.
    _isLandscapeExam = false;
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initializeFuture = _setUpCamera();
  }

  /// Camera bring-up, CamerAwesome edition. The old version created and
  /// initialized a `CameraController` here (with a resolution-preset
  /// fallback loop, explicit focus/exposure modes and a manual image-stream
  /// start). CamerAwesome owns all of that inside [CameraAwesomeBuilder]
  /// (see [_buildCameraLayer]) — it starts, streams and disposes with the
  /// widget — so what remains here is the part that must happen BEFORE
  /// mounting it: the permission preflight, so a denial shows the same
  /// message and Retry button as before instead of a blank preview.
  ///
  /// Behaviour intentionally NOT carried over (no CamerAwesome equivalent;
  /// see the migration notes): the veryHigh -> high -> medium preset
  /// fallback for devices that can't bind a surface combination, and the
  /// explicit `FocusMode.auto`/`ExposureMode.auto` calls (CameraX runs
  /// continuous AF/AE by default; the initial center metering region is
  /// still applied once the preview is up — see [_onPreviewReady]).
  Future<void> _setUpCamera() async {
    // Captured once, checked after every subsequent `await` below — see
    // [_cameraGeneration]'s doc comment for why this matters.
    final myGen = _cameraGeneration;
    if (mounted) setState(() => _cameraError = null);
    try {
      final granted = await CamerawesomePlugin.checkAndRequestPermissions(
        false,
        checkMicrophonePermissions: false,
        checkCameraPermissions: true,
      );
      if (!mounted || _isCapturing || myGen != _cameraGeneration) return;
      if (granted == null || !granted.hasRequiredPermissions()) {
        setState(() {
          _cameraError =
              'Camera permission was denied. Enable it in your device settings to scan sheets.';
        });
        return;
      }
      _mountSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      _loggedFirstFrame = false;
      _loggedFirstIndicator = false;
      _loggedFrameGeometry = false;
      _lastFrameArrival = null;
      _arrivalSumMs = 0;
      _arrivalCount = 0;
      _sensorConfig?.dispose();
      _sensorConfig = SensorConfig.single(
        sensor: Sensor.position(SensorPosition.back),
        flashMode: FlashMode.none,
        aspectRatio: CameraAspectRatios.ratio_16_9,
      );
      _analysisConfig = AnalysisConfig(
        androidOptions: const AndroidAnalysisOptions.yuv420(width: 1920),
        maxFramesPerSecond: 1000 / _liveCheckInterval.inMilliseconds,
        autoStart: true,
      );
      setState(() {
        _cameraReady = false;
        _cameraKey++;
        _cameraMounted = true;
      });
    } catch (e) {
      debugPrint('[ExamScanning] camera setup failed: $e');
      if (mounted && myGen == _cameraGeneration) {
        setState(() => _cameraError = 'Could not start the camera ($e).');
      }
    }
  }

  /// Runs once per mount, the first time CamerAwesome's builder reports a
  /// live state (see [_buildCameraLayer]): records the camera state, marks
  /// the camera ready, and applies the same initial center focus/metering
  /// the controller-based version applied right after initialize (some
  /// camera HALs only actually start continuous AF/AE once a region is
  /// explicitly set — see [_focusOnPoint]).
  void _onPreviewReady(CameraState state, int mountKey) {
    if (!mounted || mountKey != _cameraKey || _cameraReady) return;
    setState(() {
      _camState = state;
      _cameraReady = true;
    });
    if (_mountSw != null && !_loggedFirstFrame) {
      _loggedFirstFrame = true;
      omrPerfLog('camera firstPreview=${_mountSw!.elapsedMilliseconds}ms');
    }
    unawaited(_focusOnPoint(state, const Offset(0.5, 0.5)));
  }

  /// Unmounts the camera and resets every piece of state a fresh session
  /// needs to start clean: the live corner guide, auto-capture's stability
  /// timer and arming, the frame-check throttle, torch/exposure state, and —
  /// as defensive cleanup, since an in-flight capture's own `try/finally`
  /// may never get a clean chance to run against a session being torn down
  /// out from under it — the capture-in-progress flag. (Shared by
  /// [didChangeAppLifecycleState]'s inactive/paused branch and resume.)
  ///
  /// Bumps [_cameraGeneration] first: results from a frame check still in
  /// flight (or a [_setUpCamera] still awaiting permissions) detect the
  /// change and are discarded instead of being applied to the next mount.
  /// Removing [CameraAwesomeBuilder] from the tree is what stops the analysis
  /// stream and releases the camera; there is no controller to await here.
  Future<void> _tearDownCamera() async {
    _cameraGeneration++;
    _camState = null;
    _cameraReady = false;
    _cameraMounted = false;
    _analysisFrameSize = null;
    _liveCornersFound = null;
            _lastAllConfidentAt = null;
    _liveCornerPositions = null;
    _liveDiagnostics = null;
    _liveRotation = FrameRotation.none;
    _captureReadySince = null;
    _autoCaptureStableSince = null;
    _autoCaptureArmed = true;
    _meanLuma = null;
    _lastFrameCheckAt = null;
    _frameCheckInFlight = false;
    _isCapturing = false;
    // Torch/exposure state doesn't survive disposing the camera session
    // (hardware-level, tied to it) -- reset so the UI (torch icon) matches
    // the fresh session the next _setUpCamera() will start, which always
    // begins with flash off.
    _torchOn = false;
    _exposureNudged = false;
    if (mounted) setState(() {});
  }

  /// Full interruption-recovery cycle for [AppLifecycleState.resumed]:
  /// unmounts whatever camera session exists and always starts a completely
  /// fresh one rather than trying to reuse or patch up whatever existed
  /// before.
  ///
  /// CamerAwesome's native teardown starts when the builder widget is
  /// disposed and cannot be awaited the way `CameraController.dispose()`
  /// was, so a short pause is left between unmounting the old session and
  /// mounting the new one to avoid binding the camera while it is still
  /// being released. The delay value is a starting point that needs
  /// on-device confirmation, not a measured requirement.
  Future<void> _resumeCamera() async {
    if (_cameraMounted) {
      await _tearDownCamera();
      await Future<void>.delayed(const Duration(milliseconds: 300));
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
    // Future"). Confirmed on-device in the controller-based version: this
    // crashed every resume while a scanner screen was open. A block body's
    // last statement is not a return value, so this actually returns void.
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
    // No controller to stop or dispose: the analysis stream and camera
    // session belong to CameraAwesomeBuilder, which releases both when this
    // State's widget subtree is removed (the generation bump above already
    // makes any in-flight frame result a no-op). By the time this State's
    // dispose runs, the builder subtree has already been disposed, so the
    // sensor config it used is safe to release.
    _camState = null;
    _sensorConfig?.dispose();
    _sensorConfig = null;
    super.dispose();
  }

  /// Throttled live check: at most once every 250ms, and never overlapping
  /// a check already in flight, so this stays cheap enough to run
  /// continuously while framing. Feeds the on-screen indicator, the
  /// display-only "Ready to scan" caption ([_captureReadySince]), and the
  /// auto-capture stability trigger below — never the manual capture gate,
  /// so neither shutter path can bypass a failed live check.
  ///
  /// A frame can still be in flight through [compute] when a lifecycle
  /// interruption tears down (or replaces) the camera controller — [myGen]
  /// snapshots [_cameraGeneration] at dispatch time so the result can be
  /// discarded rather than applied to a session it no longer belongs to,
  /// instead of blindly mutating state on however things look by the time
  /// the isolate call resolves.
  Future<void> _onCameraFrame(AnalysisImage image, int mountKey) async {
    // CamerAwesome acknowledges a frame to the native side only after the
    // Future returned here completes, and the native analyzer keeps only the
    // latest frame meanwhile (STRATEGY_KEEP_ONLY_LATEST) -- so returning
    // immediately (as every early exit below does) simply asks for the next
    // frame; nothing queues up. The detector job itself is dispatched
    // without awaiting, and [_frameCheckInFlight] keeps it to one at a time.
    final now = DateTime.now();
    if (kOmrPerfDebug && mountKey == _cameraKey) {
      // Frame-delivery cadence (time between frames reaching Dart), logged
      // alongside the detector's own execution time below so the two can be
      // compared -- see the liveFrame log line.
      final last = _lastFrameArrival;
      if (last != null) {
        _arrivalSumMs += now.difference(last).inMilliseconds;
        _arrivalCount++;
      }
      _lastFrameArrival = now;
    }
    if (!mounted || _isCapturing || _frameCheckInFlight || mountKey != _cameraKey) return;
    if (_camState == null) return;
    if (_lastFrameCheckAt != null &&
        now.difference(_lastFrameCheckAt!) <
            _liveCheckInterval) {
      return;
    }
    final appState = AppStateScope.of(context);
    final template = omrTemplates[appState.activeExamCode];
    if (template == null) return;

    // The detector's input contract is a raw luma plane + row stride in the
    // sensor's own orientation (it does its own rotation search). The
    // YUV_420_888 analysis format's first plane IS that; NV21 would carry
    // the same Y plane plus a chroma copy this screen never reads. Verified
    // per frame by [lumaFrameFromYPlane] (pixel stride, row stride, buffer
    // length) -- a frame that fails is skipped, never guessed at.
    final rawLuma = image.when<LumaFrame?>(
      yuv420: (yuv) {
        final y = yuv.planes.first;
        return lumaFrameFromYPlane(
          bytes: y.bytes,
          width: yuv.width,
          height: yuv.height,
          rowStride: y.bytesPerRow,
          // A missing stride is rejected (0), not assumed to be 1.
          pixelStride: y.bytesPerPixel ?? 0,
        );
      },
    );
    if (rawLuma == null) return;
    // Only the region the camera shows and photographs may be searched:
    // CameraX can deliver a larger buffer and describe the visible part by a
    // crop rectangle (see cropLumaFrame). Without this the live check found
    // corners outside the captured photo, went green, and every capture was
    // then rejected.
    final luma = cropLumaFrame(
      rawLuma,
      image.when<({double left, double top, double right, double bottom})?>(
        yuv420: (yuv) => (
          left: yuv.cropRect.left,
          top: yuv.cropRect.top,
          right: yuv.cropRect.right,
          bottom: yuv.cropRect.bottom,
        ),
      ),
    );
    _analysisFrameSize = Size(luma.width.toDouble(), luma.height.toDouble());
    _analysisRotationDeg = _rotationDegrees(image.rotation);
    if (kOmrPerfDebug && !_loggedFrameGeometry) {
      _loggedFrameGeometry = true;
      unawaited(_logFrameGeometry(image, rawLuma, luma));
    }

    final myGen = _cameraGeneration;
    _lastFrameCheckAt = now;
    _frameCheckInFlight = true;
    final liveFrameSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
    compute(
          _checkLiveCorners,
          _LiveCornersRequest(
            luma.bytes,
            luma.width,
            luma.height,
            luma.bytesPerRow,
            template,
            includeDiagnostics: _diagnosticsEnabled,
          ),
        )
        .then((result) {
          if (myGen == _cameraGeneration) _frameCheckInFlight = false;
          if (_mountSw != null && !_loggedFirstIndicator && myGen == _cameraGeneration) {
            _loggedFirstIndicator = true;
            omrPerfLog('camera firstIndicator=${_mountSw!.elapsedMilliseconds}ms');
          }
          // Logged only every 10th tick — a live-check timing line on every
          // preview tick would flood logcat and risk
          // perturbing the very timing being measured.
          if (liveFrameSw != null && (++_liveFrameLogCounter % 10 == 0)) {
            omrPerfLog(
              'liveFrame check=${liveFrameSw.elapsedMilliseconds}ms '
              'frameDelivery avg=${_arrivalCount == 0 ? 0 : (_arrivalSumMs / _arrivalCount).round()}ms '
              'n=$_arrivalCount',
            );
          }
          if (!mounted || _isCapturing || myGen != _cameraGeneration) return;
          final doneAt = DateTime.now();
          final goodNow = result.cornersFound.length == 4 &&
              result.cornersFound.every((c) => c == CornerConfidence.confident);
          if (goodNow) {
            _lastAllConfidentAt = doneAt;
          } else if (_liveVerdict == AlignmentVerdict.green &&
              _lastAllConfidentAt != null &&
              doneAt.difference(_lastAllConfidentAt!) < _liveGreenGrace) {
            return; // one dropped check: keep the current green state
          }
          setState(() {
            _liveCornersFound = result.cornersFound;
            _liveDiagnostics = result.diagnostics;
            _liveRotation = result.rotation;
            _meanLuma = result.meanLuma;
            final recoverable = result.cornersFound.length == 4 &&
                result.cornersFound.every((c) => c == CornerConfidence.confident);
            _lastVerifiedFrameAt = recoverable ? now : null;
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
              _readyToCapture &&
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
          if (!mounted || _isCapturing || myGen != _cameraGeneration) return;
          // A failed check gives no information about this frame — leaving
          // the previous check's colors/verdict on screen would misrepresent
          // a frame that was never actually evaluated as still found (or
          // still not found). Clear back to the same neutral "unknown"
          // state shown before the very first check ever completes, rather
          // than freezing on whatever the last successful check happened to
          // read.
          setState(() {
            _liveCornersFound = null;
            _lastAllConfidentAt = null;
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
  ///
  /// CamerAwesome exposes exposure as a 0..1 "brightness" that its native
  /// side maps linearly onto the device's exposure-compensation index range
  /// (`brightness * (upper - lower) + lower`), not as an EV offset. Camera
  /// index ranges are symmetric around 0 in practice, so 0.5 is no
  /// correction and 0.75 is half of the maximum positive index -- the same
  /// "half the device's max" nudge as before. The symmetry assumption is
  /// not verified per device; it is the first thing to check if exposure
  /// looks off in low light.
  Future<void> _maybeNudgeExposure(double meanLuma) async {
    final state = _camState;
    if (state == null || !_cameraIsReady) return;
    final isLowLight = meanLuma < _lowLightLumaThreshold && !_torchOn;
    if (!isLowLight) {
      if (_exposureNudged) {
        _exposureNudged = false;
        try {
          await state.sensorConfig.setBrightness(0.5);
        } catch (_) {
          // Not all devices/lenses support exposure offset control.
        }
      }
      return;
    }
    if (_exposureNudged) return;
    try {
      // A conservative fraction of the device's own max range -- enough to
      // help recover shadow detail without blowing out highlights once the
      // (already light-colored) sheet fills most of the frame.
      await state.sensorConfig.setBrightness(0.75);
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
  ///
  /// `FlashMode.always` is CamerAwesome's continuous-torch mode. Unlike the
  /// old torch-only mode it also sets the still-capture flash mode to ON
  /// (see its native `setFlashMode`), so whether a torch-lit capture adds a
  /// second flash burst is device behaviour that needs on-device
  /// confirmation, not assumed away.
  Future<void> _toggleTorch() async {
    final state = _camState;
    if (state == null || !_cameraIsReady) return;
    final next = !_torchOn;
    try {
      await state.sensorConfig.setFlashMode(next ? FlashMode.always : FlashMode.none);
      if (!mounted) return;
      setState(() => _torchOn = next);
    } catch (_) {
      // Not all devices/lenses support flash/torch control.
    }
  }

  /// One-time (per mount) record of the analysis frame's real geometry next
  /// to the preview's, so "the analysis stream matches the preview" is
  /// confirmed from device logs (`[OMR PERF] camera geometry ...`) instead
  /// of assumed: raw size and stride, reported rotation, crop rect, upright
  /// size vs the preview's pixel size, and whether their aspects and fields
  /// of view agree.
  Future<void> _logFrameGeometry(AnalysisImage image, LumaFrame rawLuma, LumaFrame luma) async {
    try {
      final preview = await _camState?.previewSize(0);
      final crop = image.when<({double left, double top, double right, double bottom})?>(
        yuv420: (yuv) => (
          left: yuv.cropRect.left,
          top: yuv.cropRect.top,
          right: yuv.cropRect.right,
          bottom: yuv.cropRect.bottom,
        ),
      );
      final upright = uprightSize(luma.width, luma.height, _analysisRotationDeg);
      omrPerfLog(
        'camera geometry raw=${rawLuma.width}x${rawLuma.height} stride=${rawLuma.bytesPerRow} analysed=${luma.width}x${luma.height} '
        'rotation=$_analysisRotationDeg crop=$crop '
        'upright=${upright.width}x${upright.height} '
        'preview=${preview?.width.round()}x${preview?.height.round()} '
        'sameAspect=${preview == null ? null : sameAspect(upright.width.toDouble(), upright.height.toDouble(), preview.width, preview.height)} '
        'fullFrameCrop=${cropIsFullFrame(rawLuma.width, rawLuma.height, crop)}',
      );
    } catch (e) {
      omrPerfLog('camera geometry log failed: $e');
    }
  }

  int _rotationDegrees(InputAnalysisImageRotation rotation) => switch (rotation) {
        InputAnalysisImageRotation.rotation0deg => 0,
        InputAnalysisImageRotation.rotation90deg => 90,
        InputAnalysisImageRotation.rotation180deg => 180,
        InputAnalysisImageRotation.rotation270deg => 270,
      };

  /// Upright (display-oriented) size of the latest analysis frame -- the
  /// source size the diagnostic overlay maps into the viewfinder with
  /// `BoxFit.cover`, valid because CamerAwesome's preview and analysis
  /// streams are both configured 16:9 (checked from real frames, not
  /// assumed: see the one-time `camera geometry` log in [_logFrameGeometry]).
  Size _diagnosticDisplaySize() {
    final raw = _analysisFrameSize!;
    final u = uprightSize(raw.width.round(), raw.height.round(), _analysisRotationDeg);
    return Size(u.width.toDouble(), u.height.toDouble());
  }

  /// Converts a detector fraction (in the orientation its winning search
  /// used) to a fraction of the upright display frame.
  (double, double) Function(double, double) _diagnosticFractionMapper() {
    final detector = switch (_liveRotation) {
      FrameRotation.none => DetectorRotation.none,
      FrameRotation.clockwise90 => DetectorRotation.clockwise90,
      FrameRotation.counterClockwise90 => DetectorRotation.counterClockwise90,
    };
    final rotation = _analysisRotationDeg;
    return (fx, fy) {
      final (rx, ry) = detectorFractionToRaw(fx, fy, detector);
      return rawFractionToUpright(rx, ry, rotation);
    };
  }

  /// Sets both the focus AND exposure point to the same [point] (a
  /// (0,0)-(1,1) fraction of the *displayed preview*, matching
  /// the old `CameraController.setFocusPoint`/`setExposurePoint` contract) —
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
  /// [_previewTapFor]) so staff can redirect it
  /// onto the actual sheet if it's hunting on the background/hand instead
  /// — this needs on-device confirmation either helps; digital sharpening
  /// cannot substitute for the camera actually focusing correctly, and
  /// this is not assumed to fully resolve TAT's reported focus struggles
  /// without that confirmation.
  ///
  /// CamerAwesome's single call meters AF + AE + AWB on the point (the old
  /// API set focus and exposure points separately); [point] here is still a
  /// (0,0)-(1,1) fraction of the displayed preview, converted to the pixel
  /// coordinates its native side expects.
  Future<void> _focusOnPoint(CameraState state, Offset point) async {
    try {
      final pixelSize = await state.previewSize(0);
      if (state is PhotoCameraState) {
        await state.focusOnPoint(
          flutterPosition: Offset(
            point.dx * pixelSize.width,
            point.dy * pixelSize.height,
          ),
          pixelPreviewSize: pixelSize,
          flutterPreviewSize: pixelSize,
        );
      }
    } catch (_) {
      // Not all devices/lenses support an explicit focus/metering point.
    }
  }

  /// Tap-to-focus for the live viewfinder, supplied to CamerAwesome as the
  /// preview's tap handler (it reports the tap in the preview widget's own
  /// coordinates together with that widget's size, so a preview cropped by
  /// `BoxFit.cover` still focuses on whatever the user actually tapped).
  /// `onTapPainter: null` keeps the viewfinder free of CamerAwesome's
  /// default focus ring -- the existing scanner never drew one.
  OnPreviewTap _previewTapFor(CameraState state) {
    return OnPreviewTap(
      onTapPainter: null,
      onTap: (position, flutterPreviewSize, pixelPreviewSize) {
        state.when(
          onPhotoMode: (photo) => photo.focusOnPoint(
            flutterPosition: position,
            pixelPreviewSize: pixelPreviewSize,
            flutterPreviewSize: flutterPreviewSize,
          ),
        );
      },
    );
  }

  /// Both shutter paths require fresh, stable, verified live alignment.
  /// The saved photo is checked again because motion can occur during exposure.
  Future<void> _capture(AppState appState, {required bool manual}) async {
    final camState = _camState;
    if (camState == null || !_cameraIsReady || _isCapturing || !_readyToCapture) {
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
      // CamerAwesome writes the JPEG straight to the path our SaveConfig
      // pathBuilder returns (see [_buildCameraLayer]) -- the same kind of
      // app-cache file the old takePicture() returned, untouched afterward:
      // no resize, no re-encode, EXIF left exactly as CameraX wrote it, so
      // OmrDecoder's own EXIF/orientation handling sees the same kind of
      // input as before. (The removed `_isLandscapeExam` device-orientation
      // normalization block lived here; that branch was unreachable.)
      if (camState is! PhotoCameraState) {
        throw StateError('The camera is not in photo mode.');
      }
      final captureRequest = await camState.takePhoto();
      final capturedPath = captureRequest.path;
      // takePhoto() reports a native failure through its media-capture
      // stream rather than by throwing, so confirm a real, non-empty file
      // exists before anything downstream trusts the path.
      if (capturedPath == null ||
          !File(capturedPath).existsSync() ||
          File(capturedPath).lengthSync() == 0) {
        throw StateError('The photo was not saved.');
      }
      final file = XFile(capturedPath);
      if (takePictureSw != null) takePictureMs = takePictureSw.elapsedMilliseconds;
      final template = omrTemplates[appState.activeExamCode];
      if (template != null) {
        final alignmentSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
        final check = await compute(
          _checkAlignment,
          _AlignmentCheckRequest(file.path, template,
              diagnosticsEnabled: _diagnosticsEnabled),
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
          setState(() {
            _captureReadySince = null;
            _lastVerifiedFrameAt = null;
            _autoCaptureStableSince = null;
            _liveCornersFound = null;
            _lastAllConfidentAt = null;
          });
          await _showMisalignedDialog(check.message);
          return;
        }
      }
      if (!mounted) return;
      final decoded = await appState.previewCapturedPage(file);
      if (!mounted) return;
      final scored = scoreOmrResult(
        decoded, appState.answerKeys[decoded.examCode],
      );
      final score = computeExamScoreForCode(scored);
      // Hold the shutter lock while the score is visible. Rearm automatic
      // capture only after the user removes or repositions this sheet.
      _autoCaptureArmed = false;
      await showDialog<void>(
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
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
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
      setState(() {
        _captureReadySince = null;
        _lastVerifiedFrameAt = null;
        _autoCaptureStableSince = null;
        _liveCornersFound = null;
            _lastAllConfidentAt = null;
      });
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
      if (appState.rescanScanId != null) {
        await _compileData(appState);
      }
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
    // Content-based "same physical sheet scanned twice" check — skipped
    // while rescanning: a rescan is *expected* to match the slot it's
    // replacing, and the wrong-sheet-in-this-slot mistake already has its
    // own dedicated guard in AppState.finishRescan (name-mismatch check).
    if (appState.rescanScanId == null) {
      final warnings = _duplicateScanWarnings(appState);
      if (warnings.isNotEmpty) {
        final proceed = await _showDuplicateScanDialog(warnings);
        if (!mounted) return;
        if (!proceed) return;
      }
    }
    if (appState.rescanScanId != null) {
      // Rescanning one existing sheet in an archived batch, not building a
      // normal multi-sheet session -- overwrite it in place and return to
      // wherever "Rescan" was tapped from, instead of Exam Results.
      final ok = await appState.finishRescan();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(appState.rescanSaveError ?? 'Could not save the rescan.')),
        );
        return;
      }
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacementNamed(AppRoutes.examResults);
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
    final cornerFractions = activeTemplate == null
        ? _defaultCornerFractions
        : activeTemplate.cornerMarkers.map((c) => (c.xFrac, c.yFrac)).toList();

    // The 4 corner marks aren't necessarily near the page's literal
    // (0,0)-(1,1) edges (a narrow bubble grid leaves them well inside the
    // page — see the comment on OmrDecoder.decode's dstCorners), so the
    // guide box's real-world aspect ratio has to come from the marks'
    // actual bounding box, not the full page's aspect ratio, or the guide
    // rectangle drawn on screen won't match the marks' true proportions.
    final pageWidthPt = activeTemplate?.pageWidthPt ?? 595.28;
    final pageHeightPt = activeTemplate?.pageHeightPt ?? 841.89;
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
              // TEMPORARY developer tool, debug-build-only and off by
              // default (see [_diagnosticsEnabled]) — never shown in a
              // release build, so this can't reach end users.
              if (kDebugMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    onTap: () => setState(() {
                      _diagnosticsEnabled = !_diagnosticsEnabled;
                      // Also gates AppState.processCapturedPages' own
                      // debug-image generation and verbose decode logging —
                      // see AppState.diagnosticsEnabled's doc comment. One
                      // toggle for both the live preview's diagnostic
                      // overlay and the post-capture troubleshooting output.
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
                onTap: _cameraIsReady ? _toggleTorch : null,
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
          if (_cameraIsReady) ...[
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
                _analysisFrameSize != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    // Detector fractions are measured in whichever
                    // orientation its winning search used; CamerAwesome
                    // reports the real rotation-to-upright of each analysis
                    // frame, so the mapping is computed from that
                    // (camera_frame_adapter.dart) instead of assuming the
                    // detector's frame already matches the preview.
                    painter: _DiagnosticOverlayPainter(
                      _liveDiagnostics!,
                      _diagnosticDisplaySize(),
                      mapFraction: _diagnosticFractionMapper(),
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
                      color: _isLowLight ? AppColors.warmRedOrange : const Color(0xFF6EE7B7),
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
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _cameraIsReady &&
                            !_isCapturing &&
                            _readyToCapture &&
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
                            !_isCapturing &&
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
                      _cameraIsReady &&
                          !_isCapturing &&
                          _readyToCapture &&
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
                            !_isCapturing &&
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
        if (snapshot.connectionState == ConnectionState.done &&
            !_cameraMounted &&
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
        if (!_cameraMounted) return _cameraSpinner;
        // KeyedSubtree, keyed per mount: a new key is a brand-new
        // CameraAwesomeBuilder State (and native session), never a reused
        // one -- the same "always a completely fresh camera" policy the
        // controller-based version had.
        return KeyedSubtree(
          key: ValueKey(_cameraKey),
          child: _buildCameraAwesome(_cameraKey),
        );
      },
    );
  }

  static const Widget _cameraSpinner = ColoredBox(
    color: Colors.black,
    child: Center(
      child: CircularProgressIndicator(color: AppColors.accentYellowGreen),
    ),
  );

  /// Where CamerAwesome writes each captured JPEG: the app cache directory
  /// (the same place the old plugin's takePicture() put its file), one
  /// unique name per capture so a retry can never overwrite a photo still
  /// being processed. Downstream code only ever needs the path.
  Future<CaptureRequest> _photoPathFor(List<Sensor> sensors) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/scan_${DateTime.now().microsecondsSinceEpoch}.jpg';
    return SingleCaptureRequest(path, sensors.first);
  }

  /// The camera, via CamerAwesome's custom-UI builder: it renders only the
  /// live preview (cover-fit, so the framing matches the old `FittedBox`
  /// + `BoxFit.cover` over the sensor preview), while EVERY control, guide,
  /// caption and colour stays this screen's own widgets, layered over it in
  /// [_buildViewfinder]. The builder callback draws nothing.
  ///
  /// Camera settings (all explicit, none left to a plugin default that
  /// differs from before):
  ///  * rear sensor, 16:9 -- the old veryHigh preset was 1080p 16:9;
  ///  * preview fit cover; portrait lock (also set by CamerAwesome itself);
  ///  * photo: CamerAwesome always takes the highest resolution CameraX
  ///    offers for the chosen aspect ratio (its native ImageCapture uses
  ///    HIGHEST_AVAILABLE_STRATEGY and exposes no size cap) -- a plugin
  ///    limitation, so captures are larger than the old ~2MP (see the
  ///    migration notes; capture-to-result latency is unmeasured);
  ///  * analysis: YUV_420_888 (first plane = the luma plane + row stride the
  ///    detector consumes, no NV21 chroma copy), target width 1920 (the old
  ///    stream was a 1080p-class frame; the detector downsizes to
  ///    [_liveCheckMaxDimension] itself), at most 4 frames/s -- the same
  ///    cadence [_liveCheckInterval] already enforced on the Dart side, now
  ///    also saving the native copy/transfer of frames that would have been
  ///    dropped. These two numbers are carried-over equivalents, NOT
  ///    measured optima.
  Widget _buildCameraAwesome(int mountKey) {
    return CameraAwesomeBuilder.custom(
      sensorConfig: _sensorConfig!,
      saveConfig: SaveConfig.photo(pathBuilder: _photoPathFor),
      previewFit: CameraPreviewFit.cover,
      progressIndicator: _cameraSpinner,
      imageAnalysisConfig: _analysisConfig,
      onImageForAnalysis: (image) => _onCameraFrame(image, mountKey),
      onPreviewTapBuilder: _previewTapFor,
      builder: (state, preview) {
        if (!_cameraReady) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _onPreviewReady(state, mountKey),
          );
        } else if (mountKey == _cameraKey) {
          _camState = state;
        }
        return const SizedBox.shrink();
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
  const _DiagnosticOverlayPainter(
    this.diagnostics,
    this.sourceSize, {
    this.mapFraction,
  });

  final List<CornerDiagnostic> diagnostics;
  final Size sourceSize;

  /// Optional detector-fraction -> display-fraction conversion applied
  /// before the `BoxFit.cover` mapping (see
  /// `_ExamScanningScreenState._diagnosticFractionMapper`); null keeps the
  /// old direct mapping.
  final (double, double) Function(double, double)? mapFraction;

  static const _cornerNames = ['TL', 'TR', 'BL', 'BR'];

  Offset _map(double fx, double fy, Size destSize) {
    final (mx, my) = mapFraction?.call(fx, fy) ?? (fx, fy);
    return fractionToWidgetOffset(
      fx: mx,
      fy: my,
      sourceSize: sourceSize,
      destSize: destSize,
    );
  }

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
