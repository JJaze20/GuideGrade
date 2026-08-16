import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

class _LiveAlignmentRequest {
  final Uint8List lumaBytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final OmrExamTemplate template;
  const _LiveAlignmentRequest(this.lumaBytes, this.width, this.height, this.bytesPerRow, this.template);
}

AlignmentCheck _checkLiveAlignment(_LiveAlignmentRequest request) {
  return const OmrDecoder().checkAlignmentFromLuma(
    request.lumaBytes,
    request.width,
    request.height,
    request.bytesPerRow,
    request.template,
  );
}

/// OMR Scanner Loop — mirrors SCREENS.EXAM_SCANNING.
/// Shows a live camera feed inside a capture viewfinder with an alignment
/// overlay and scan-line animation, and lets the user photograph each
/// answer sheet ("Scan Next" captures + advances) before compiling the
/// batch ("Compile Data").
class ExamScanningScreen extends StatefulWidget {
  const ExamScanningScreen({super.key});

  @override
  State<ExamScanningScreen> createState() => _ExamScanningScreenState();
}

class _ExamScanningScreenState extends State<ExamScanningScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _scanController;

  CameraController? _cameraController;
  Future<void>? _initializeFuture;
  String? _cameraError;
  bool _isCapturing = false;

  /// Bumped every time camera setup is (re)started or torn down. An
  /// in-flight [_setUpCamera] call captures the generation it was started
  /// under and checks it again after every await — if it no longer
  /// matches, a newer setup or a teardown has superseded this one, so its
  /// (possibly just-initialized) controller is disposed immediately
  /// instead of being handed to the widget tree. This is what prevents a
  /// stale controller from a rapid pause/resume (or a resume racing a
  /// still-in-flight initial setup) from ever landing in
  /// [_cameraController].
  int _cameraGeneration = 0;

  /// Live, advisory-only alignment feedback for the on-screen guide: null
  /// until the first frame check completes, then whether the most recent
  /// checked frame found all 4 corner marks. The post-capture check in
  /// [_capture] remains the real gate (Retake/Use Anyway) — this only
  /// colors the guide while framing, and runs against lower-effort preview
  /// frames rather than the full-resolution captured photo.
  bool? _liveAligned;
  DateTime? _lastFrameCheckAt;
  bool _frameCheckInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _initializeFuture = _setUpCamera();
  }

  Future<void> _setUpCamera() async {
    final myGeneration = ++_cameraGeneration;
    setState(() => _cameraError = null);
    try {
      final cameras = await availableCameras();
      if (!mounted || myGeneration != _cameraGeneration) return;
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
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted || myGeneration != _cameraGeneration) {
        // The widget is gone, or a newer setup/teardown has already
        // superseded this call (e.g. a quick pause->resume) while this one
        // was still initializing. Never hand a controller from an outdated
        // attempt to the widget tree -- dispose it immediately instead.
        await controller.dispose();
        return;
      }
      setState(() => _cameraController = controller);
      try {
        await controller.startImageStream(_onCameraFrame);
      } catch (_) {
        // Live guide feedback is advisory only; if streaming isn't
        // supported on this device, capture + the post-capture check
        // still work fine without it.
      }
    } on CameraException catch (e) {
      if (!mounted || myGeneration != _cameraGeneration) return;
      setState(() {
        _cameraError = e.code == 'CameraAccessDenied' || e.code == 'CameraAccessDeniedWithoutPrompt'
            ? 'Camera permission was denied. Enable it in your device settings to scan sheets.'
            : 'Could not start the camera (${e.description ?? e.code}).';
      });
    } catch (e) {
      if (!mounted || myGeneration != _cameraGeneration) return;
      setState(() => _cameraError = 'Could not start the camera ($e).');
    }
  }

  /// Detaches [_cameraController] from the widget tree synchronously --
  /// before any async stop/dispose work starts -- so that no later rebuild
  /// (even one racing in from an unrelated notifyListeners firing while
  /// stopImageStream/dispose are still in flight) can ever construct a
  /// CameraPreview against a controller that's mid-teardown or already
  /// disposed. This is what [didChangeAppLifecycleState] and [dispose] both
  /// use, so there's exactly one teardown path.
  void _teardownCamera({required bool notify}) {
    _cameraGeneration++; // invalidate any in-flight _setUpCamera call
    final controller = _cameraController;
    if (controller == null) return;
    if (notify) {
      setState(() {
        _cameraController = null;
        _liveAligned = null;
      });
    } else {
      _cameraController = null;
      _liveAligned = null;
    }
    if (controller.value.isStreamingImages) {
      controller.stopImageStream();
    }
    controller.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _teardownCamera(notify: true);
    } else if (state == AppLifecycleState.resumed) {
      _initializeFuture = _setUpCamera();
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // notify: false -- setState is not safe to call once dispose() has
    // started; the field reset alone is enough since the widget is being
    // torn down and won't rebuild again.
    _teardownCamera(notify: false);
    _scanController.dispose();
    super.dispose();
  }

  /// Throttled, advisory-only live check: at most once every 600ms, and
  /// never overlapping a check already in flight, so this stays cheap
  /// enough to run continuously while framing.
  void _onCameraFrame(CameraImage image) {
    if (!mounted || _frameCheckInFlight) return;
    final now = DateTime.now();
    if (_lastFrameCheckAt != null && now.difference(_lastFrameCheckAt!) < const Duration(milliseconds: 600)) {
      return;
    }
    final template = omrTemplates[AppStateScope.of(context).activeExamCode];
    if (template == null) return;

    _lastFrameCheckAt = now;
    _frameCheckInFlight = true;
    final plane = image.planes.first;
    compute(
      _checkLiveAlignment,
      _LiveAlignmentRequest(plane.bytes, image.width, image.height, plane.bytesPerRow, template),
    ).then((check) {
      _frameCheckInFlight = false;
      if (!mounted) return;
      setState(() => _liveAligned = check.aligned);
    }).catchError((_) {
      _frameCheckInFlight = false;
    });
  }

  Future<void> _capture(AppState appState) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;

    setState(() => _isCapturing = true);
    try {
      final file = await controller.takePicture();
      final template = omrTemplates[appState.activeExamCode];
      if (template != null) {
        final check = await compute(_checkAlignment, _AlignmentCheckRequest(file.path, template));
        if (!check.aligned) {
          if (!mounted) return;
          final useAnyway = await _showMisalignedDialog(check.message);
          if (useAnyway != true) return; // Retake: discard this photo.
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  /// Returns true if the user chose to keep the photo despite the alignment
  /// check failing, false (or null, if dismissed) to retake it.
  Future<bool?> _showMisalignedDialog(String? message) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Photo may not be aligned'),
        content: Text(message ?? "This sheet's corner markers weren't found clearly in this photo."),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Retake')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Use Anyway')),
        ],
      ),
    );
  }

  Future<void> _compileData(AppState appState) async {
    await appState.processCapturedPages();
    if (!mounted) return;
    if (appState.scanProcessingError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not process the scan: ${appState.scanProcessingError}')),
      );
      return;
    }
    Navigator.of(context).pushReplacementNamed(AppRoutes.examResults);
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            return Column(
              children: [
                // Top bar
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      InkWell(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(color: Colors.black.withOpacity(0.4), shape: BoxShape.circle),
                          child: const Icon(Icons.close, color: Colors.white, size: 16),
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
                      const SizedBox(width: 32),
                    ],
                  ),
                ),

                // Scanning viewfinder
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Stack(
                        children: [
                          Positioned.fill(child: _buildCameraLayer()),
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(color: AppColors.accentYellowGreen.withOpacity(0.6), width: 2),
                              ),
                            ),
                          ),
                          if (_cameraController?.value.isInitialized == true) ...[
                            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _PageGuidePainter(_liveAligned)))),
                            AnimatedBuilder(
                              animation: _scanController,
                              builder: (context, child) {
                                return Positioned(
                                  top: _scanController.value * 320,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    height: 2,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.transparent,
                                          AppColors.accentYellowGreen,
                                          Colors.transparent,
                                        ],
                                      ),
                                      boxShadow: [
                                        BoxShadow(color: AppColors.accentYellowGreen.withOpacity(0.6), blurRadius: 8),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                            Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: AppColors.accentYellowGreen.withOpacity(0.2)),
                                ),
                                child: const Text(
                                  'Target Lock Alignment Target Matrix',
                                  style: TextStyle(color: Color(0xFF6EE7B7), fontSize: 10, fontFamily: 'monospace'),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                // Bottom action panel
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black, Colors.black.withOpacity(0.95), Colors.transparent],
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
                          style: const TextStyle(color: Color(0xFF34D399), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _cameraController?.value.isInitialized == true && !_isCapturing
                                    ? () => _capture(appState)
                                    : null,
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: AppColors.slate800,
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: AppColors.slate800.withOpacity(0.4),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: _isCapturing
                                    ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                                    : const Text('Scan Next', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: appState.capturedPages.isNotEmpty && !appState.isProcessingScans
                                    ? () => _compileData(appState)
                                    : null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primaryGreen,
                                  disabledBackgroundColor: AppColors.primaryGreen.withOpacity(0.35),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: appState.isProcessingScans
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Text('Compile Data', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
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
            const Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 32),
            const SizedBox(height: 12),
            Text(
              _cameraError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() => _initializeFuture = _setUpCamera()),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
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
                const Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 32),
                const SizedBox(height: 12),
                const Text(
                  'Could not start the camera.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => setState(() => _initializeFuture = _setUpCamera()),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        if (controller == null || !controller.value.isInitialized) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator(color: AppColors.accentYellowGreen)),
          );
        }
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.previewSize!.height,
              height: controller.value.previewSize!.width,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }
}

/// Draws a dimmed spotlight with corner brackets sized to the OMR sheet's
/// aspect ratio (US Letter portrait, matching every [OmrExamTemplate]'s
/// pageWidthPt/pageHeightPt), so the user can line the physical sheet up to
/// a known frame position instead of guessing. Consistent framing keeps the
/// full sheet - and all 4 corner fiducials - reliably in shot, which is
/// what the decoder's corner search depends on.
class _PageGuidePainter extends CustomPainter {
  const _PageGuidePainter(this.aligned);

  /// Live, advisory alignment state: null before the first check completes,
  /// then whether the most recently checked preview frame found all 4
  /// corner marks. Purely visual feedback while framing — capture is never
  /// blocked on this.
  final bool? aligned;

  static const double _pageAspectRatio = 595.28 / 841.89; // A4 portrait, matches every OmrExamTemplate's page size
  static const double _insetFraction = 0.06;
  static const double _cornerArmFraction = 0.08;

  Color get _guideColor => switch (aligned) {
    true => AppColors.primaryGreen,
    false => AppColors.warmRedOrange,
    null => AppColors.accentYellowGreen,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final maxWidth = size.width * (1 - _insetFraction * 2);
    final maxHeight = size.height * (1 - _insetFraction * 2);
    double guideWidth = maxWidth;
    double guideHeight = guideWidth / _pageAspectRatio;
    if (guideHeight > maxHeight) {
      guideHeight = maxHeight;
      guideWidth = guideHeight * _pageAspectRatio;
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
    canvas.drawPath(dimPath, Paint()..color = Colors.black.withOpacity(0.45));

    final bracketPaint = Paint()
      ..color = _guideColor
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final armLength = guideWidth * _cornerArmFraction;

    void drawCorner(Offset corner, Offset horizontal, Offset vertical) {
      canvas.drawLine(corner, corner + horizontal * armLength, bracketPaint);
      canvas.drawLine(corner, corner + vertical * armLength, bracketPaint);
    }

    drawCorner(guideRect.topLeft, const Offset(1, 0), const Offset(0, 1));
    drawCorner(guideRect.topRight, const Offset(-1, 0), const Offset(0, 1));
    drawCorner(guideRect.bottomLeft, const Offset(1, 0), const Offset(0, -1));
    drawCorner(guideRect.bottomRight, const Offset(-1, 0), const Offset(0, -1));
  }

  @override
  bool shouldRepaint(covariant _PageGuidePainter oldDelegate) => aligned != oldDelegate.aligned;
}