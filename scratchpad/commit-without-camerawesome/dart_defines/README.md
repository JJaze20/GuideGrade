# Supabase build configuration (`--dart-define-from-file`)

`lib/main.dart` reads the Supabase project URL and publishable (anon) key from
compile-time defines:

```dart
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey = String.fromEnvironment('SUPABASE_ANON_KEY');
```

To avoid typing `--dart-define=...` by hand every build, keep those two values
in a local JSON file that is **never committed**.

## One-time setup (per machine)

1. Copy the template:

   ```
   cp dart_defines/prod.example.json dart_defines/prod.json
   ```

2. Open `dart_defines/prod.json` and replace the placeholders with the real
   Supabase project URL and **publishable / anon** key (never the
   `service_role` key).

3. Do **not** commit `dart_defines/prod.json` — it is already git-ignored
   (`.gitignore`: `dart_defines/*.json`, with `!dart_defines/prod.example.json`
   as the only tracked file in this folder).

## Development

```
flutter run --dart-define-from-file=dart_defines/prod.json
```

## Release APK

```
flutter build apk --release --dart-define-from-file=dart_defines/prod.json
```

Each `"KEY": "value"` in the JSON is passed exactly as `--dart-define=KEY=value`,
so `String.fromEnvironment('SUPABASE_URL')` / `String.fromEnvironment('SUPABASE_ANON_KEY')`
in `lib/main.dart` receive them unchanged. If the file is absent (or the keys
are empty) the app still runs — Supabase is simply left uninitialised and the
app is local-only.
