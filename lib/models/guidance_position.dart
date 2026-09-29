/// One Guidance Council position: a stable internal [value] (what
/// `UserModel.guidancePosition` / Firestore actually store) and its
/// human-facing [label] (what every screen displays).
class GuidancePosition {
  final String value;
  final String label;

  const GuidancePosition({required this.value, required this.label});

  @override
  bool operator ==(Object other) =>
      other is GuidancePosition && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);

  @override
  String toString() => 'GuidancePosition($value: $label)';
}

/// Pure helpers around the System-Admin-managed Guidance Position list
/// (`config/guidancePositions`'s `positions` map field, `{value: label}`).
/// No Firebase here -- reading/writing that document is
/// [FirestoreService.loadGuidancePositions]/[FirestoreService.
/// addGuidancePosition]; this class only does the value/label logic those
/// (and the four Position dropdowns) share, so it stays unit-testable
/// without Firebase and there is exactly one copy of it.
class GuidancePositions {
  const GuidancePositions._();

  /// The three positions this app has always had. Also this project's
  /// documented, in-code seed data for a brand-new `config/guidancePositions`
  /// document -- see [FirestoreService.ensureDefaultGuidancePositionsSeeded].
  /// Every screen falls back to exactly this list if the live configuration
  /// can't be read, so the Position control is never empty.
  static const List<GuidancePosition> defaults = [
    GuidancePosition(value: 'guidance_head', label: 'Guidance Head'),
    GuidancePosition(value: 'psychometrician', label: 'Psychometrician'),
    GuidancePosition(value: 'guidance_staff', label: 'Guidance Staff'),
  ];

  /// Parses the `positions` map field of `config/guidancePositions` into an
  /// ordered list. Never throws: anything that isn't a non-empty
  /// `Map<String, String>`-shaped value (missing document, wrong type, a
  /// malformed or empty map) falls back to [defaults], so a bad/partial
  /// document degrades to "the three originals still work" rather than an
  /// empty Position list.
  static List<GuidancePosition> fromFirestoreField(Object? raw) {
    if (raw is! Map) return defaults;
    final parsed = <GuidancePosition>[];
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is String && value is String && key.trim().isNotEmpty && value.trim().isNotEmpty) {
        parsed.add(GuidancePosition(value: key, label: value));
      }
    }
    return parsed.isEmpty ? defaults : parsed;
  }

  /// The human-facing label for [value] within [positions], or null if
  /// [value] is null or genuinely not present in [positions]. Callers
  /// decide what "not present" means for display (see
  /// `ProfileScreen._positionLabel`) -- this never guesses or falls back to
  /// [defaults] on its own, since a value truly missing from the live list is
  /// different from one this call site just doesn't know about yet.
  static String? labelFor(String? value, List<GuidancePosition> positions) {
    if (value == null) return null;
    for (final position in positions) {
      if (position.value == value) return position.label;
    }
    return null;
  }

  /// [positions] plus a synthetic entry for [currentValue], only if
  /// [currentValue] isn't already present. Every dropdown that pre-fills
  /// from an account's own stored `guidancePosition` needs this: Flutter's
  /// `DropdownButtonFormField` asserts if its `initialValue` doesn't match
  /// one of `items` exactly, so a custom position that isn't (yet, or ever)
  /// in the loaded/fallback list must still appear as a selectable item, or
  /// the account's own already-saved choice would either crash the widget or
  /// silently disappear. The synthetic entry's label is the raw stored
  /// value -- there is no better label available when the configured one
  /// isn't known here.
  static List<GuidancePosition> ensureIncludes(
    List<GuidancePosition> positions,
    String? currentValue,
  ) {
    if (currentValue == null || currentValue.trim().isEmpty) return positions;
    if (positions.any((p) => p.value == currentValue)) return positions;
    return [...positions, GuidancePosition(value: currentValue, label: currentValue)];
  }

  /// A deterministic lower_snake_case slug from [label] -- this project's
  /// existing internal-value convention (`guidance_head`, `guidance_staff`),
  /// never a random ID. Lowercases, then collapses any run of characters
  /// that aren't `a-z`/`0-9` into a single underscore and strips leading/
  /// trailing underscores, so "Auditing" -> `auditing` and
  /// "Data  Analysis!!" -> `data_analysis`.
  static String slugify(String label) {
    final lower = label.trim().toLowerCase();
    final collapsed = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  /// Validates a new position [label] against [existing] before it's added:
  /// rejects a blank label, a label matching an existing one (trimmed,
  /// case-insensitive), or a label whose generated [slugify] value collides
  /// with an existing internal value (two different labels that would
  /// otherwise slugify to the same stored value). Returns the user-facing
  /// error message, or null if [label] is safe to add.
  static String? validateNewLabel(String label, List<GuidancePosition> existing) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return 'Position name is required';
    final normalized = trimmed.toLowerCase();
    if (existing.any((p) => p.label.trim().toLowerCase() == normalized)) {
      return 'A position with this name already exists';
    }
    final slug = slugify(trimmed);
    if (slug.isEmpty) return 'Enter a position name using letters or numbers';
    if (existing.any((p) => p.value == slug)) {
      return 'A position with this name already exists';
    }
    return null;
  }

  /// Builds the [GuidancePosition] a validated [label] becomes -- callers
  /// must already have checked [validateNewLabel] returns null first; this
  /// does not re-validate.
  static GuidancePosition build(String label) {
    final trimmed = label.trim();
    return GuidancePosition(value: slugify(trimmed), label: trimmed);
  }
}
