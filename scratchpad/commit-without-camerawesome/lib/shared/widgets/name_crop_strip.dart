import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/services/batch_repository.dart';
import '../../models/local_batch.dart';

/// Shows the sheet's own cropped Last Name / First Name / MI handwriting
/// images side by side, so staff can read them directly instead of relying
/// on any automatic recognition (this app runs none — see
/// [LocalScan.nameCropLastFileName]'s doc comment). Reused on the result/
/// archive cards and inside [showExamineeDialog] so there's one place to
/// tune how the crop is presented.
///
/// Resolves lazily (each crop is decrypted from disk) the same way
/// `_ScanThumbnail` already does for the full scan photo. Renders nothing
/// — not a placeholder box — when none of the three crops are available,
/// which covers both an older scan that predates this feature and a sheet
/// whose cropping failed; neither is an error worth calling out visually.
class NameCropStrip extends StatefulWidget {
  final String batchId;
  final LocalScan scan;
  final BatchRepository repository;
  final double height;

  const NameCropStrip({
    super.key,
    required this.batchId,
    required this.scan,
    required this.repository,
    this.height = 80,
  });

  @override
  State<NameCropStrip> createState() => _NameCropStripState();
}

class _NameCropStripState extends State<NameCropStrip> {
  late final Future<List<Uint8List?>> _future = Future.wait([
    widget.repository.resolveScanNameCropLast(widget.batchId, widget.scan),
    widget.repository.resolveScanNameCropFirst(widget.batchId, widget.scan),
    widget.repository.resolveScanNameCropMiddle(widget.batchId, widget.scan),
  ]);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Uint8List?>>(
      future: _future,
      builder: (context, snapshot) {
        final crops = (snapshot.data ?? const []).whereType<Uint8List>().toList();
        if (crops.isEmpty) return const SizedBox.shrink();
        // A single FittedBox around the whole row so everything stays on
        // one line, sharing one scale factor: Wrap (dropping an
        // overflowing field to a second line) and a scrollable Row (needs
        // a swipe to see the rest) were both tried and rejected — staff
        // want to see all three crops at once, in one glance, even if that
        // means a mild uniform downscale. This should only ever be a small
        // adjustment now: [OmrDecoder.cropNameFields] already trims each
        // crop to just past where the handwriting ends (see
        // `_trimNameCropToContent` there), so the row's natural width at
        // [widget.height] should already be close to fitting.
        return SizedBox(
          width: double.infinity,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.lightBg,
              border: Border.all(color: AppColors.cardBorder),
              borderRadius: BorderRadius.circular(6),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < crops.length; i++) ...[
                    // Wider than it looks like it needs to be at full
                    // scale: the whole strip (this gap included) gets
                    // uniformly downscaled by the FittedBox above whenever
                    // it doesn't fit on one line, so a small gap here can
                    // shrink to the point of barely reading as a space
                    // between Last Name / First Name / MI (confirmed on a
                    // real device).
                    if (i > 0) const SizedBox(width: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.memory(
                        crops[i],
                        height: widget.height,
                        fit: BoxFit.fitHeight,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
