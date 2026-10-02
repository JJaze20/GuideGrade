# TAT portrait proposed v4

Use the PDF and accompanying geometry JSON as the source of truth, not the AI mockups. This PDF has exactly 130 questions / 320 oval bubbles and 14 fiducials. Long bond paper: 8.5 x 13 inches (612 x 936 PDF points). Print Actual Size / 100%, not Legal or Fit.

Coordinates in JSON are top-left origin, in points. PDF native coordinates use bottom-left origin: convert y with 936-y. Name-field rectangles exclude the printed captions. Bubble numbering restarts per section. Test I: 30 A-D; Test II: 80 T/F; Test III: 20 T/F. All numbering was regenerated deterministically.

Seven 6pt small marks are centered above the answer groups: Test I 1/11/21 at their B/C midpoints, Test II 21/41 and Test III 6/11 at their T/F midpoints. A new 11pt square at (306,468) lies in the central gutter between Test II 23 and 43, level with the side pair. It is 3.6pt above those rows' bubble centers (y=471.6), preserving the side pair at the physical page midpoint. There are six edge marks: four corners plus a side pair at y=468pt, the physical page midpoint. The former pair above Test III is removed. This revision preserves v1 question and field positions; it is distinct from answer_sheets/TAT.pdf and the current app template. Header and margins are based on the approved mockup concept, not measurements of an existing physical sheet.

This is a NEW proposed template, not currently supported by the app. Implement a separate template version and explicit selection; preserve existing TAT/AT/QTM and archived coordinates. Do not overwrite legacy definitions. Preserve scoring rules. Use identical mapping for sampling and review overlays. Crop names for manual entry; do not enable OCR automatically.

Measure and validate these vector positions independently. Marks at section boundaries do not fully constrain bending inside tall Test II columns. Validate against printed geometry and real device captures. Verify orientation discrimination rather than assuming all layouts uniquely identify direction. Test print margins, actual-size output, 130-question mapping, saved name crops, rotated/tilted capture, and archive compatibility before production use.
