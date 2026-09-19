# TAT twelve-mark registration

## Sheet and selection

Select **TAT** when scanning. New results use `TAT-redesign-v2` automatically.
Use `answer_sheets/TAT.pdf`, byte-identical to the supplied
`Downloads/TAT(Redesign).pdf` (SHA256
`8ec1f4b7a962cf98b0d799446fac98497b351908c7266f77a17b05f5e16a5b0c`).
The sheet itself was not changed. It has one landscape page, 936 × 612 PDF
points, and sections of 30 A–D, 80 T/F, and 20 T/F items.

Measured vector geometry, top-left origin:

- Corners: (24,24), (912,24), (24,588), (912,588), side length 14pt.
- Side marks: (24,306), (912,306), side length 14pt.
- Section marks: x=154,494,782 at y=145 and y=544, side length 9pt.
- All 320 bubbles have horizontal/vertical radii 8pt/6.4pt.

`tool/verify_tat_pdf.py` independently checks the vector rectangles, oval
outlines, and printed choice letters against the emitted Dart template.
The PDF was also rendered and visually inspected against the approved image.
Generate definitions without modifying printable PDFs with
`cd tool; dart run generate_sheets.dart --templates-only`.

## Implementation

- `tool/generate_sheets.dart` and `lib/core/omr/omr_templates.dart`: eight named
  additional references, measured sizes, and version identifier.
- `omr_decoder_native.dart` / `tat_marker_validation.dart`: TAT-only,
  resolution-scaled search windows and expected-size, shape, and competing
  candidate checks. Existing contrast/squareness checks remain in force.
- `omr_mesh_correction.dart`: separate continuous, piecewise-affine TAT
  topology using the actual twelve printed vertices. Flat measurements keep
  the original homography. Moderate offsets use local interpolation; orientation,
  triangle-area and edge-stretch checks guard against unsafe mappings.
- All eight references appear separately in mesh diagnostics with expected
  and detected positions, missing/displaced status, and residual in PDF points.
- Local correction requires all six section references and at least one side
  reference. One missing side is a regularizing zero-displacement anchor, never
  claimed as a detection. Missing evidence with measured displacement rejects;
  missing evidence without displacement keeps the global warp as inconclusive.
- TAT offsets over 12pt reject; coherent offsets suggest wrong corner matching.
  These are conservative engineering bounds, not device-calibrated guarantees.
- `app_state.dart` saves the exact provisional grayscale warp from TAT decode.
  The review overlay reconstructs the same persisted mesh used for bubble
  sampling. The saved image remains perspective-corrected, rather than being
  separately flattened by another transform. Original captures are retained.
- `omr_tat_legacy_template.dart` freezes v1 geometry for archived overlays.
  Unknown/unversioned TAT scans show the original image without a guessed overlay.
- `exam_scanning_screen.dart` explicitly distinguishes corner detection from
  full post-capture alignment checking. Preview still detects four corners.
- Name crops retain TAT's previous global-only mapping; OCR, manual-name
  behavior, answer-classification thresholds, and scoring rules were not changed.
  AT/QTM retain their prior detection and mesh paths.

## Verification and limitations

An earlier run passed `dart tool/verify_tat_registration.dart`: section/choice mapping,
all-mark diagnostics, flat and modest synthetic point displacement, missing-side
support, missing-section rejection, isolated severe errors, coherent shifts,
scale independence, positive local orientation, no outer extrapolation,
320 saved-overlay/sample-coordinate agreements, legacy behavior, and marker
shape/size/ambiguity gates. These tests use synthetic measurements; they do not
exercise native image detection or prove real handheld accuracy. The current
pre-commit rerun fails at `no unsupported outer extrapolation` (line 73).
The outside-mesh fallback now clamps to a triangle boundary; this remains an
unresolved regression, and the current standalone suite must not be reported
as passing.

Passed PDF vector comparison (12 marks and 320 bubbles/letters). Android debug
APK built successfully. Static analysis has no errors; pre-existing warnings
and style/deprecation notices remain.

The normal Flutter test run is blocked by the Windows OpenCV/CMake native hook.
An isolated pure-geometry Flutter test attempt is additionally blocked by Windows
Application Control preventing `flutter_tester.exe` from starting. The standalone
Dart checks above run without either dependency. Subsequent phone testing by the
user confirmed working TAT alignment and name crops after the landscape capture
orientation fix. This is informal device evidence, not a complete accuracy study.

Still required on device: repeated flat, rotated and perspective-tilted captures;
modest bending in different directions; blur/shadow/glare; partial marker occlusion;
false squares near reference windows; and blank/light/single/multiple-answer
regressions. Compare decoded choices and review overlays against the physical
paper. Native detection and its new candidate gates still need systematic device
validation across these conditions.

The printed layout has no middle-of-Test-II reference. Marker agreement does
not validate every bubble inside the answer blocks. Independent bubble-outline
validation and fully flattened image generation are not implemented in this change.
No claim of arbitrary curved-paper correction is made.
