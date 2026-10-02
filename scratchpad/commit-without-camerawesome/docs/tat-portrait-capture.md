# TAT portrait camera capture

The camera screen stays portrait, like AT/QTM. Place the landscape TAT sheet
sideways so it fills the portrait guide.

**Standardized on one placement (2026-09-18):** hold the phone portrait, and
turn the sheet so "TEACHING APTITUDE TEST (TAT)" reads normally at the top
and the name fields sit on the left. Counselors only ever need to learn one
rule; neither direction was inherently more accurate, so nothing is lost by
dropping the other. This also matches the on-screen viewfinder guide's own
corner-box layout, which was always drawn for this one placement.

The PDF and canonical bubble coordinates remain unchanged. Before decoding,
the scanner rotates the raw portrait capture 90° counterclockwise (the fixed
mapping from the standardized placement back to the sheet's print
orientation), then measures the asymmetric section marks to confirm the
sheet actually landed there: at least two upper and two lower section marks
must be found near their expected position, with a combined score high
enough to rule out a coincidental partial match. Symmetric side marks do not
vote on this check. If it fails, the capture is rejected with a message
naming the required placement, rather than trying other rotations.

Previously the scanner evaluated all four quarter turns and accepted
whichever scored best, so either printed-label direction worked. That
flexibility was the actual cause of reported orientation "struggling": a
noisy interior-fiducial read could make a genuinely wrong rotation score
competitively against the correct one, and every capture paid for three
rotation searches it didn't need. Checking only the one standardized
rotation removes that ambiguity outright and is cheaper per capture.

The common orientation routine serves decoding, corrected-image generation,
and name cropping. Existing saved scans are not regenerated. Preview remains
a corner-only check, not proof that the reading direction has been validated.
AT/QTM decoding and answer thresholds are unchanged.

`dart tool/verify_tat_orientation.dart` predates the single-placement change
and still exercises the underlying selection helper
(`selectTatOrientation`/`tat_marker_validation.dart`) directly with
decision-logic cases (four directions, missing marks, ambiguity, partial
evidence, false competing candidates) — that helper is no longer called from
the decoder's orientation path itself, but is left in place since the test
script still exercises it and nothing about its own logic is wrong. These
are decision-logic tests, not native image-detection accuracy tests.

Device validation still required: rescan the same TAT sheet with the phone
portrait and the label facing each direction. Compare every section's answers,
review rings, and name crops. Repeat with tilt and modest bending, and verify
that obscured section marks produce a useful retake message. Four orientation
searches add processing work; capture latency has not been measured on device.

After a reported portrait-capture rejection, the orientation warp was changed
from 1 px/pt to the normal registration scale of 2 px/pt. Fixed pixel blur and
dilation made the smaller warp more susceptible to rejecting small squares.
Residuals are converted back to PDF points, preserving physical tolerances.
Each rotation now logs measured positions, upper/lower support, and score.
The user's rejected original capture was unavailable, so this scale correction
is not yet confirmed to resolve that particular failure.

## Rescan retry investigation

Phone logs subsequently confirmed a decisive reading direction on rejected
captures. One capture missed `tatBelowI` while other residuals reached about
8.2pt. The saved diagnostic warp shows the marker present in a shadowed area;
missing detection must not be described as proof of physical occlusion.

A separate rescan-state bug accumulated previous attempts and decoded all of
them on every save. Thus a failed earlier attempt could block a later good
capture. Rescan capture now replaces its in-memory queue and clears stale
results/errors. Normal batch capture still appends. No geometry rejection
thresholds changed. The marker-detection failure itself remains unresolved.

Added `app_state_rescan_capture_test.dart` for retry replacement and normal
batch append behavior. Static analysis passed. Running the tests on this host
was blocked by the OpenCV native build hook because CMake is unavailable.
