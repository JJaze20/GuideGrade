# TAT portrait proposed v2

Use the PDF and accompanying geometry JSON as the source of truth, not the AI mockups. This PDF has exactly 130 questions / 320 oval bubbles and 11 fiducials. Long bond paper: 8.5 x 13 inches (612 x 936 PDF points). Print Actual Size / 100%, not Legal or Fit.

Coordinates in JSON are top-left origin, in points. PDF native coordinates use bottom-left origin: convert y with 936-y. Name-field rectangles exclude the printed captions. Bubble numbering restarts per section. Test I: 30 A-D; Test II: 80 T/F; Test III: 20 T/F. All numbering was regenerated deterministically.

New small marks are above the question numbers Test I 11, Test II 21/41, Test III 6/11. There are six edge marks: four corners plus a side pair at y=468pt, the physical page midpoint. The former pair above Test III is removed. This revision preserves v1 question and field positions; it is distinct from answer_sheets/TAT.pdf and the current app template. Header and margins are based on the approved mockup concept, not measurements of an existing physical sheet.

This is a NEW proposed template, not currently supported by the app. Implement a separate template version and explicit selection; preserve existing TAT/AT/QTM and archived coordinates. Do not overwrite legacy definitions. Preserve scoring rules. Use identical mapping for sampling and review overlays. Crop names for manual entry; do not enable OCR automatically.

Measure and validate these vector positions independently. Marks at section boundaries do not fully constrain bending inside tall Test II columns. Validate against printed geometry and real device captures. Verify orientation discrimination rather than assuming all layouts uniquely identify direction. Test print margins, actual-size output, 130-question mapping, saved name crops, rotated/tilted capture, and archive compatibility before production use.
