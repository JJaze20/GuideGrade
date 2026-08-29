import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;

import '../../../core/constants/app_colors.dart';
import '../../../core/omr/omr_decoder.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';

class _AlignmentCheckRequest {
  final String imagePath;
  final OmrExamTemplate template;
  const _AlignmentCheckRequest(this.imagePath, this.template);
}

AlignmentCheck _checkAlignment(_AlignmentCheckRequest request) {
  return const OmrDecoder().locateCorners(request.imagePath, request.template);
}

class _LiveCornersRequest {
  final Uint8List lumaBytes;
  final int width;
  final int height;
  final int bytesPerRow;
  const _LiveCornersRequest(
    this.lumaBytes,
    this.width,
    this.height,
    this.bytesPerRow,
  );
}

List<bool> _checkLiveCorners(_LiveCornersRequest request) {
  return const OmrDecoder().checkCornersFromLuma(
    request.lumaBytes,
    request.width,
    request.height,
    request.bytesPerRow,
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

  /// Live, per-corner feedback: null until the first frame check completes,
  /// then whether each of the 4 corner marks (in
  /// [OmrExamTemplate.cornerMarkers] order) was found in the most recently
  /// checked frame. This now also gates capture (see [_readyToCapture]) —
  /// it isn't purely advisory any more — but the post-capture check in
  /// [_capture] remains the authoritative gate, since it runs against the
  /// actual full-resolution captured photo rather than these lower-effort
  /// preview frames, and a page can still fail it even after this live
  /// signal read all 4 as found.
  List<bool>? _liveCornersFound;
  DateTime? _lastFrameCheckAt;
  bool _frameCheckInFlight = false;

  /// When all 4 corners most recently read as found, continuously — set the
  /// moment they first do, cleared the instant any check comes back with
  /// fewer than 4. [_readyToCapture] requires this to have held for
  /// [_requiredStableDuration] before allowing a capture, so a single
  /// flickery "4/4" frame (a brief glare, a shaky hand) can't by itself
  /// trigger a scan.
  DateTime? _all4FoundSince;

  /// How long all 4 corners must read as continuously found before capture
  /// is allowed. Live checks land roughly every 600ms
  /// ([_onCameraFrame]'s throttle), so this requires at least one
  /// corroborating re-check beyond the frame that first read 4/4, not just
  /// that single frame.
  static const Duration _requiredStableDuration = Duration(milliseconds: 500);

  /// Hard gate on capture: every corner must currently read as found *and*
  /// have done so continuously for [_requiredStableDuration]. The "Scan
  /// Next" button is disabled whenever this is false (see [build]), and
  /// [_capture] re-checks it defensively before ever calling
  /// `takePicture()` — there should be no path to a capture attempt while
  /// this is false, let alone to a scan result.
  bool get _readyToCapture {
    final since = _all4FoundSince;
    return since != null &&
        DateTime.now().difference(since) >= _requiredStableDuration;
  }

  /// Neutral until the first live check completes, green once all 4
  /// anchors are currently found, red otherwise (some or none found).
  Color get _scanWindowBorderColor {
    final found = _liveCornersFound;
    if (found == null) return AppColors.accentYellowGreen;
    return found.every((f) => f)
        ? AppColors.primaryGreen
        : AppColors.warmRedOrange;
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
    final template = omrTemplates[AppStateScope.of(context).activeExamCode];
    _isLandscapeExam =
        template != null && template.pageWidthPt > template.pageHeightPt;
    // A landscape-page exam (TAT) unlocks landscape device rotation for
    // this screen only — a user photographing a landscape sheet naturally
    // turns the phone sideways to fill the frame with it, the same way
    // they'd hold any camera for a wide subject. Restored to portrait-only
    // the moment this screen closes (see dispose()), so it never leaks
    // into the rest of the app, which stays portrait-only throughout (see
    // main.dart).
    if (_isLandscapeExam) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _initializeFuture = _setUpCamera();
  }

  Future<void> _setUpCamera() async {
    setState(() => _cameraError = null);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraError = 'No camera was found on this device.');
        return;
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        backCamera,
        // veryHigh (1080p, ~2MP) over the previous `high` (720p, ~0.92MP) —
        // a page with 72 small bubble rows needs real resolution to read
        // reliably; 720p was giving the decoder noticeably fewer pixels
        // per bubble than the phone's actual camera is capable of.
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
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
      } catch (_) {
        // Not all devices/lenses support explicit focus/exposure mode
        // control; capture still works with whatever the platform default is.
      }
      try {
        await controller.startImageStream(_onCameraFrame);
      } catch (_) {
        // Live guide feedback is advisory only; if streaming isn't
        // supported on this device, capture + the post-capture check
        // still work fine without it.
      }
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraError =
            e.code == 'CameraAccessDenied' ||
                e.code == 'CameraAccessDeniedWithoutPrompt'
            ? 'Camera permission was denied. Enable it in your device settings to scan sheets.'
            : 'Could not start the camera (${e.description ?? e.code}).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = 'Could not start the camera ($e).');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
      _cameraController = null;
      _liveCornersFound = null;
      _all4FoundSince = null;
    } else if (state == AppLifecycleState.resumed) {
      if (_isLandscapeExam) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      _initializeFuture = _setUpCamera();
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Restore the app-wide portrait lock (see main.dart) that
    // didChangeDependencies loosened for this one landscape-page exam --
    // every other screen is still built for a tall portrait frame, so
    // this must not leak past this screen's own lifetime.
    if (_isLandscapeExam) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    final controller = _cameraController;
    if (controller != null && controller.value.isStreamingImages) {
      controller.stopImageStream();
    }
    controller?.dispose();
    super.dispose();
  }

  /// Throttled live check: at most once every 600ms, and never overlapping
  /// a check already in flight, so this stays cheap enough to run
  /// continuously while framing. Feeds both the on-screen indicator and
  /// [_readyToCapture]'s stabilization tracking.
  void _onCameraFrame(CameraImage image) {
    if (!mounted || _frameCheckInFlight) return;
    final now = DateTime.now();
    if (_lastFrameCheckAt != null &&
        now.difference(_lastFrameCheckAt!) <
            const Duration(milliseconds: 600)) {
      return;
    }
    final template = omrTemplates[AppStateScope.of(context).activeExamCode];
    if (template == null) return;

    _lastFrameCheckAt = now;
    _frameCheckInFlight = true;
    final plane = image.planes.first;
    compute(
          _checkLiveCorners,
          _LiveCornersRequest(
            plane.bytes,
            image.width,
            image.height,
            plane.bytesPerRow,
          ),
        )
        .then((found) {
          _frameCheckInFlight = false;
          if (!mounted) return;
          setState(() {
            _liveCornersFound = found;
            if (found.every((f) => f)) {
              _all4FoundSince ??= now;
            } else {
              _all4FoundSince = null;
            }
          });
        })
        .catchError((_) {
          _frameCheckInFlight = false;
        });
  }

  Future<void> _capture(AppState appState) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isCapturing)
      return;
    // Defensive re-check: the "Scan Next" button is already disabled unless
    // this holds (see build()), but re-checking here means there's no path
    // to takePicture() while corners aren't confidently, stably found —
    // not just a button-state assumption.
    if (!_readyToCapture) return;

    setState(() => _isCapturing = true);
    try {
      final file = await controller.takePicture();
      final template = omrTemplates[appState.activeExamCode];
      if (template != null) {
        final check = await compute(
          _checkAlignment,
          _AlignmentCheckRequest(file.path, template),
        );
        if (!check.aligned) {
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
      appState.addCapturedPage(file);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: ${e.description ?? e.code}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    } finally {
      if (mounted) setState(() => _isCapturing = false);
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
    Navigator.of(context).pushReplacementNamed(AppRoutes.examResults);
  }

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
          const SizedBox(width: 32),
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
                    _liveCornersFound == null
                        ? 'Position sheet within the frame'
                        : _readyToCapture
                        ? 'Ready to scan'
                        : _liveCornersFound!.every((f) => f)
                        ? 'Hold steady…'
                        : _liveCornersFound!.any((f) => f)
                        ? '${_liveCornersFound!.where((f) => f).length}/4 corner marks locked'
                        : 'Align all 4 corners inside the frame',
                    style: const TextStyle(
                      color: Color(0xFF6EE7B7),
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
              appState.capturedPages.isEmpty
                  ? 'ALIGN SHEET AND CAPTURE'
                  : '${appState.capturedPages.length} SHEET${appState.capturedPages.length == 1 ? '' : 'S'} CAPTURED',
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
                        _cameraController?.value.isInitialized == true &&
                            !_isCapturing &&
                            _readyToCapture
                        ? () => _capture(appState)
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
                        : const Text(
                            'Scan Next',
                            style: TextStyle(
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
                            !appState.isProcessingScans
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
                    child: appState.isProcessingScans
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Compile Data',
                            style: TextStyle(
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
            appState.capturedPages.isEmpty
                ? 'ALIGN SHEET AND CAPTURE'
                : '${appState.capturedPages.length} SHEET${appState.capturedPages.length == 1 ? '' : 'S'} CAPTURED',
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
                          _readyToCapture
                      ? () => _capture(appState)
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
                      : const Text(
                          'Scan Next',
                          style: TextStyle(
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
                          !appState.isProcessingScans
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
                  child: appState.isProcessingScans
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Compile Data',
                          style: TextStyle(
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
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: previewWidth,
              height: previewHeight,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }
}

/// Draws a dimmed spotlight sized to match the real proportions of the
/// rectangle spanned by the sheet's 4 fiducial marks (not the full page —
/// see [markerAspectRatio]), a visible outline on that rectangle so it
/// reads as a target even against a busy background, and one L-shaped
/// bracket per corner — colored individually from [cornersFound] — so the
/// user can see exactly *which* corner still needs adjusting instead of
/// only an aggregate "X/4" count. The scan window's own overall border
/// color (see [_ExamScanningScreenState._scanWindowBorderColor]) still
/// gives an at-a-glance all-4 cue; this adds the specific, per-corner one.
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
  /// bracket draws neutral.
  final List<bool>? cornersFound;

  static const double _insetFraction = 0.06;
  static const double _bracketArmLength = 26;
  static const double _bracketStrokeWidth = 4;

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

    // A visible outline on the target rectangle itself — dimming alone
    // reads as ambiguous against a busy background, this is what makes
    // "the sheet goes exactly here" legible on its own, before any frame
    // has even been checked.
    canvas.drawRect(
      guideRect,
      Paint()
        ..color = Colors.white.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // One bracket per corner, positioned by normalizing each marker's page
    // fraction against the 4 markers' own bounding box — the same
    // normalization that gives markerAspectRatio its value (see the
    // caller in build()) — so a bracket lands exactly on that marker's
    // real position within guideRect for any exam's layout, not just a
    // generic corner of the box.
    final minX = cornerFractions.map((c) => c.$1).reduce(math.min);
    final maxX = cornerFractions.map((c) => c.$1).reduce(math.max);
    final minY = cornerFractions.map((c) => c.$2).reduce(math.min);
    final maxY = cornerFractions.map((c) => c.$2).reduce(math.max);

    for (var i = 0; i < cornerFractions.length; i++) {
      final (xFrac, yFrac) = cornerFractions[i];
      final localX = maxX > minX ? (xFrac - minX) / (maxX - minX) : 0.5;
      final localY = maxY > minY ? (yFrac - minY) / (maxY - minY) : 0.5;
      final point =
          guideRect.topLeft +
          Offset(localX * guideRect.width, localY * guideRect.height);
      final found = cornersFound != null && i < cornersFound!.length
          ? cornersFound![i]
          : null;
      final color = found == null
          ? Colors.white.withOpacity(0.85)
          : found
          ? AppColors.primaryGreen
          : AppColors.warmRedOrange;
      _drawBracket(
        canvas,
        point,
        towardRight: localX < 0.5,
        towardBottom: localY < 0.5,
        color: color,
      );
    }
  }

  /// Draws one L-shaped bracket at [point], arms extending toward the
  /// guide rectangle's interior — [towardRight]/[towardBottom] say which
  /// direction that is for this particular corner (e.g. the top-left
  /// corner's arms extend right and down).
  void _drawBracket(
    Canvas canvas,
    Offset point, {
    required bool towardRight,
    required bool towardBottom,
    required Color color,
  }) {
    final dx = towardRight ? _bracketArmLength : -_bracketArmLength;
    final dy = towardBottom ? _bracketArmLength : -_bracketArmLength;
    final paint = Paint()
      ..color = color
      ..strokeWidth = _bracketStrokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(point, point + Offset(dx, 0), paint);
    canvas.drawLine(point, point + Offset(0, dy), paint);
  }

  @override
  bool shouldRepaint(covariant _PageGuidePainter oldDelegate) =>
      !listEquals(cornerFractions, oldDelegate.cornerFractions) ||
      markerAspectRatio != oldDelegate.markerAspectRatio ||
      !listEquals(cornersFound, oldDelegate.cornersFound);
}
