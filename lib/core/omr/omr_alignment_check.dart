/// Result of `OmrDecoder.locateCorners` — whether all 4 fiducial marks were
/// found for a given photo + template, without doing the (much more
/// expensive) perspective warp and bubble sampling.
///
/// Plain data, no native/Web-specific dependency, so both the native
/// (opencv_dart-backed) and Web (stub) `OmrDecoder` implementations share
/// this exact same type — see omr_decoder.dart's conditional export.
class AlignmentCheck {
  final bool aligned;
  final String? message;
  const AlignmentCheck.aligned() : aligned = true, message = null;
  const AlignmentCheck.misaligned(this.message) : aligned = false;
}
