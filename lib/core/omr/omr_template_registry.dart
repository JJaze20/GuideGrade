import 'omr_tat_legacy_template.dart';
import 'omr_template_tat_v5.dart';
import 'omr_templates.dart';

/// The template a scan was made with, looked up by the version stored on the
/// scan ([OmrExamTemplate.templateVersion]), or the current template for
/// [examCode] when [version] is null.
///
/// Sheets change over time and archived scans must keep reading with the
/// geometry they were captured against, so every earlier TAT layout that was
/// ever scanned against stays defined here. Returns null when [version] names a
/// layout that no longer exists in the app (its overlay is then not drawn
/// rather than drawn from the wrong geometry).
OmrExamTemplate? omrTemplateFor(String examCode, String? version) {
  final current = omrTemplates[examCode];
  if (version == null) return current;
  if (current != null && current.templateVersion == version) return current;
  if (examCode == 'TAT') {
    switch (version) {
      case 'TAT-portrait-v5':
        return omrTATPortraitV5;
      case 'TAT-portrait-v1':
        return omrTATPortraitV1;
      case 'TAT-redesign-v1':
        return legacyTatTemplate;
    }
  }
  return null;
}
