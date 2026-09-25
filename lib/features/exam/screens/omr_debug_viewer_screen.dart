import 'dart:io';

import 'package:flutter/material.dart';

/// One stage of the decode pipeline, as written by
/// `OmrDecoder.saveDebugVisualization`.
class _DebugStage {
  /// Filename suffix after `sheet{pageIndex}_`.
  final String suffix;
  final String title;

  /// What to look for in this image when a scan reads badly.
  final String whatToCheck;

  const _DebugStage(this.suffix, this.title, this.whatToCheck);
}

/// Pipeline order, which is also the order to read them in when diagnosing:
/// a stage can only be trusted once every stage above it looks right.
const List<_DebugStage> _stages = [
  _DebugStage(
    'corners',
    '1 · Corner detection',
    'The four black corner squares should each be ringed. A missed or '
        'mis-ringed corner means the whole page geometry is wrong, and every '
        'answer below it is unreliable — nothing later in this list can '
        'recover from it.',
  ),
  _DebugStage(
    'grid',
    '2 · Flattened page + bubble grid',
    'The page should look square-on, and the drawn grid should sit centred '
        'over the printed circles. Grid drifting off the circles — usually '
        'worst at one edge or corner — is what produces wrong reads on a '
        'slanted or curled sheet.',
  ),
  _DebugStage(
    'warped_gray',
    '3 · Grayscale',
    'The raw brightness the decoder works from. Glare blowing out a region '
        '(shiny graphite, a lamp reflection) shows up here as a washed-out '
        'patch, and marks inside it are already lost by this point.',
  ),
  _DebugStage(
    'normalized',
    '4 · Illumination normalised',
    'Lighting gradients removed, so the page should read evenly bright side '
        'to side. Any shadow or bright band still visible here will bias '
        'every bubble under it.',
  ),
  _DebugStage(
    'clahe',
    '5 · Contrast enhanced (CLAHE)',
    'Faint pencil should now stand out from paper. If marks are still barely '
        'visible here, the capture was too washed out to rescue and the fix '
        'is exposure, not tuning.',
  ),
  _DebugStage(
    'inkmap',
    '6 · Ink map — what counts as a mark',
    'The decision the score is actually built on: white is ink, black is '
        'paper. Filled bubbles should be solid white blobs and empty ones '
        'near-empty rings. Speckle across the page means the threshold is '
        'treating paper texture as ink.',
  ),
];

/// Shows how the decoder processed one captured sheet, stage by stage.
///
/// These images are already written on every scan by
/// `OmrDecoder.saveDebugVisualization` into the app's `omr_debug` folder —
/// before this screen existed nothing read them back, so diagnosing a bad
/// scan meant pulling files off the device over USB.
///
/// Read them top to bottom. The pipeline is a chain, so the first stage that
/// looks wrong is the one to fix; everything after it inherits the problem.
class OmrDebugViewerScreen extends StatelessWidget {
  /// Directory the decoder wrote into — `AppState.lastDebugImagesDir`.
  final String debugDir;

  /// 1-based page number, matching the decoder's own `pageIndex`.
  final int pageIndex;

  final String title;

  /// The decode's `OmrMeshVerdict` name, or null for a scan made before it
  /// was recorded — see `OmrScanResult.meshVerdict`.
  ///
  /// Shown because whether local geometry correction actually ran is
  /// otherwise invisible, and it is the single thing that decides how a
  /// slanted or bowed sheet reads. A template with no interior fiducials
  /// reports `notApplicable` and gets only the 4-corner warp, which cannot
  /// correct anything BETWEEN the corners — so seeing that on a sheet that
  /// should have fiducials means the wrong sheet version is being printed.
  final String? meshVerdict;

  const OmrDebugViewerScreen({
    super.key,
    required this.debugDir,
    required this.pageIndex,
    required this.title,
    this.meshVerdict,
  });

  /// Plain-language reading of [meshVerdict]: the explanation, and whether it
  /// is good news.
  (String, bool) get _meshSummary => switch (meshVerdict) {
        'meshApplied' => (
            'Geometry correction APPLIED — the sheet was measurably bowed and '
                'was corrected before the bubbles were read.',
            true,
          ),
        'planar' => (
            'Geometry checked, sheet was flat — the interior marks landed '
                'where the template says, so no correction was needed.',
            true,
          ),
        'inconclusive' => (
            'Too few interior marks were found to judge the geometry. The '
                'read fell back to the 4-corner warp alone. Not necessarily '
                'wrong, but it is unverified.',
            false,
          ),
        'notApplicable' => (
            'This sheet has NO interior reference marks, so local geometry '
                'correction could not run at all — only the 4-corner warp, '
                'which cannot correct bowing between the corners. If this is '
                'a TAT sheet, an older layout is being printed: the current '
                'one (TAT-portrait-v5) has ten interior marks.',
            false,
          ),
        'tooSevere' => (
            'The sheet was too bowed or slanted to correct reliably. Flatten '
                'it and rescan.',
            false,
          ),
        'likelyMisregistered' => (
            'The interior marks disagree with the corners by a large, uniform '
                'amount — usually one corner square was mismatched, which '
                'makes every answer on the sheet unreliable.',
            false,
          ),
        'unsupportedDistortion' => (
            'Distortion was measured but there were not enough reference '
                'points to correct it.',
            false,
          ),
        _ => ('Geometry verdict was not recorded for this scan.', false),
      };

  File _fileFor(String suffix) =>
      File('$debugDir/sheet${pageIndex}_$suffix.jpg');

  /// Present only when the decode bailed out before it could flatten the
  /// page — in that case the raw frame plus the reason are all that exist.
  File get _failedImage => File('$debugDir/sheet${pageIndex}_FAILED.jpg');
  File get _errorText => File('$debugDir/sheet${pageIndex}_error.txt');

  @override
  Widget build(BuildContext context) {
    final available = [
      for (final stage in _stages)
        if (_fileFor(stage.suffix).existsSync()) stage,
    ];
    final failed = _failedImage.existsSync();
    String? errorMessage;
    if (_errorText.existsSync()) {
      try {
        errorMessage = _errorText.readAsStringSync().trim();
      } catch (_) {
        errorMessage = null;
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        backgroundColor: const Color(0xFF111827),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          if (errorMessage != null && errorMessage.isNotEmpty)
            _ErrorCard(message: errorMessage),
          // Above the stages: the stages show what the page LOOKED like, this
          // says whether its geometry was actually corrected. A sheet can pass
          // every visual stage and still read badly if this never ran.
          _MeshVerdictCard(
            verdict: meshVerdict,
            summary: _meshSummary.$1,
            good: _meshSummary.$2,
          ),
          if (failed) ...[
            const _StageCardHeader(
              title: 'Decode failed before flattening',
              whatToCheck:
                  'The page below is the raw frame as captured. The decoder '
                  'could not find a usable set of four corners in it, so no '
                  'later stage exists to show.',
            ),
            _StageImage(file: _failedImage, title: 'Raw capture'),
            const SizedBox(height: 16),
          ],
          if (available.isEmpty && !failed)
            const _EmptyState()
          else
            for (final stage in available) ...[
              _StageCardHeader(
                title: stage.title,
                whatToCheck: stage.whatToCheck,
              ),
              _StageImage(
                file: _fileFor(stage.suffix),
                title: stage.title,
              ),
              const SizedBox(height: 16),
            ],
        ],
      ),
    );
  }
}

class _StageCardHeader extends StatelessWidget {
  final String title;
  final String whatToCheck;

  const _StageCardHeader({required this.title, required this.whatToCheck});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            whatToCheck,
            style: const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// A stage image, tappable for a zoomable full-screen look — the interesting
/// detail (a grid ringing the wrong circle, speckle in the ink map) is
/// usually far too small to judge at list width.
class _StageImage extends StatelessWidget {
  final File file;
  final String title;

  const _StageImage({required this.file, required this.title});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _FullScreenStage(file: file, title: title),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          file,
          fit: BoxFit.fitWidth,
          width: double.infinity,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => Container(
            height: 90,
            alignment: Alignment.center,
            color: const Color(0xFF1F2937),
            child: const Text(
              'Could not read this image',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullScreenStage extends StatelessWidget {
  final File file;
  final String title;

  const _FullScreenStage({required this.file, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 8,
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// Whether local geometry correction ran, in plain language.
///
/// Sits above the image stages because it answers a question none of them
/// can: the page can look perfectly fine at every stage and still have been
/// read on uncorrected geometry.
class _MeshVerdictCard extends StatelessWidget {
  final String? verdict;
  final String summary;
  final bool good;

  const _MeshVerdictCard({
    required this.verdict,
    required this.summary,
    required this.good,
  });

  @override
  Widget build(BuildContext context) {
    final accent = good ? const Color(0xFF34D399) : const Color(0xFFFBBF24);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(good ? Icons.check_circle_outline : Icons.info_outline,
                  size: 16, color: accent),
              const SizedBox(width: 7),
              Text(
                'Sheet geometry',
                style: TextStyle(
                  color: accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                verdict ?? 'not recorded',
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            summary,
            style: const TextStyle(
              color: Color(0xFFCBD5E1),
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;

  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF7F1D1D),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFFFEE2E2),
          fontSize: 11.5,
          height: 1.35,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Text(
        'No debug images were written for this sheet.\n\n'
        'They are saved during scanning, so scans processed before this '
        'screen existed, or on a device where external storage was '
        'unavailable, have nothing to show.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5, height: 1.4),
      ),
    );
  }
}
