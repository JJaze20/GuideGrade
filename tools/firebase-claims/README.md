# Phase 4 — Local Firebase Admin SDK claim backfill

A **local, one-time** Node.js script that assigns the Firebase custom claim

```json
{ "role": "authenticated" }
```

to existing Firebase users whose Firestore `users/{uid}` document has
`role == "guidance_council"` **and** `isActive == true`.

This is the **no-billing** alternative to a Cloud Function. It is **not** a
Cloud Function, is never deployed, and does not require the Blaze plan or
the Cloud Functions API. Firebase stays on **Spark**.

## Why the claim is needed

Supabase's native Firebase third‑party auth **requires** a `role` claim in
the JWT: *"Your Supabase project inspects the `role` claim present in all
JWTs sent to it to assign the correct Postgres role."* A Firebase ID token
has no `role` claim by default, so *"the `anon` role would be assigned"* and
every RLS / Storage policy denies the request. This script adds
`role: "authenticated"` so an active guidance user's Firebase token is
accepted as the `authenticated` Postgres role.

- Sources: [Firebase Auth | Supabase Docs](https://supabase.com/docs/guides/auth/third-party/firebase-auth) · [Control Access with Custom Claims | Firebase](https://firebase.google.com/docs/auth/admin/custom-claims)

## What it will and will not do

| ✅ does | ❌ never does |
|---|---|
| Reads every `users/{uid}` doc (or the ones you pass with `--uid=`) | Writes Firestore — `users/{uid}` is read-only |
| Reads each Firebase user's **current** custom claims first | Overwrites unrelated custom claims — it only ever sets/removes the `role` key |
| MERGES `{ role: "authenticated" }` into existing claims for qualifying users | Adds `role: "authenticated"` to a `system_admin` user |
| Prints a full dry-run report by default | Adds `role: "authenticated"` to an inactive (`isActive != true`) user |
| Writes only when you pass `--apply` | Touches `auth_service.dart`, `user_provisioning_service.dart`, the Admin Console, System Logs, or the OMR/scanner |
| Optionally strips a stale `role` claim from users who no longer qualify (`--revoke-stale`) | Runs on a server, or requires billing / Cloud Functions |

---

## 1. Get the service-account key

Firebase Console → **`guidegrade-470ea`** → gear icon → **Project settings**
→ **Service accounts** tab → **Generate new private key** → confirm.
A `guidegrade-470ea-firebase-adminsdk-XXXXX.json` file downloads.

This key can do anything in the project. Treat it like a root password.

## 2. Put the key somewhere safe on Windows (OUTSIDE this repo)

Do **not** place it under `lib/`, `assets/`, `android/`, `web/`, `build/`,
or anywhere inside the Flutter project. Recommended:

```powershell
# a private, per-user folder outside the repo
mkdir "$env:USERPROFILE\.secrets\guidegrade" -Force
Move-Item "$env:USERPROFILE\Downloads\guidegrade-470ea-firebase-adminsdk-*.json" `
          "$env:USERPROFILE\.secrets\guidegrade\serviceAccountKey.json"

# lock it down to just your user account
icacls "$env:USERPROFILE\.secrets\guidegrade\serviceAccountKey.json" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

`%USERPROFILE%\.secrets\` is not synced by OneDrive by default and is not in
any project folder. The repo `.gitignore` also blocks `*firebase-adminsdk*.json`,
`*serviceAccount*.json`, and `tools/firebase-claims/*.json` as a backstop.

## 3. Point `GOOGLE_APPLICATION_CREDENTIALS` at it

**Current PowerShell session only (preferred — the variable disappears when
you close the window):**

```powershell
$env:GOOGLE_APPLICATION_CREDENTIALS = "$env:USERPROFILE\.secrets\guidegrade\serviceAccountKey.json"
```

Command Prompt session only:

```bat
set GOOGLE_APPLICATION_CREDENTIALS=%USERPROFILE%\.secrets\guidegrade\serviceAccountKey.json
```

Avoid `setx` / a permanent user variable for a credential path — keep it
scoped to the session in which you run the backfill.

The script reads the key **only** through this variable (Application Default
Credentials). The path and contents never appear in the script or in git.

## 4. Install dependencies

```powershell
cd tools\firebase-claims
npm install          # installs firebase-admin locally (node_modules is gitignored)
```

Requires Node.js **18+**.

## 5. Dry run (writes nothing)

```powershell
node backfill-auth-claim.js
```

Read the report. It lists, per category:

- **WILL ADD** — qualifies, has no `role` claim yet
- **WILL SET role -> "authenticated"** — qualifies, has a different `role` claim now
- **ALREADY SET** — nothing to do
- **SKIP — system_admin** / **SKIP — inactive guidance_council** — never get the claim
- **SKIP — other / no recognized role**
- **NO FIREBASE AUTH USER** — a `users/{uid}` doc with no matching Auth account
- a **NOTE** if any non-qualifying user still carries `role: "authenticated"`

Restrict to specific users (repeatable) — e.g. right after provisioning one
new guidance account:

```powershell
node backfill-auth-claim.js --uid=THE_NEW_UID
node backfill-auth-claim.js --verbose        # also shows each user's other claim keys
```

## 6. Apply the claims

Only after the dry-run report looks right:

```powershell
node backfill-auth-claim.js --apply
```

- Each write re-reads the user's current claims and merges — other claim
  keys are preserved untouched.
- `system_admin` and inactive users are never written.

Optional reconcile (e.g. a guidance user was deactivated and should lose the
claim):

```powershell
node backfill-auth-claim.js --revoke-stale --apply
```

`--revoke-stale` also removes `role: "authenticated"` from users who
currently have it but no longer qualify. It is **off unless you pass it**;
the plain backfill is purely additive.

## 7. Delete the key afterward

```powershell
Remove-Item "$env:USERPROFILE\.secrets\guidegrade\serviceAccountKey.json" -Force
Remove-Item Env:\GOOGLE_APPLICATION_CREDENTIALS
```

If the key was ever exposed (emailed, pasted, committed): Firebase Console →
Project settings → Service accounts → **Manage service account permissions**
→ Google Cloud IAM → delete that key from the `firebase-adminsdk` service
account, and generate a fresh one.

Re-run this script (steps 1–6) only when you provision, deactivate, or
reactivate a guidance user — download a new key each time, or keep one key
in `%USERPROFILE%\.secrets\` under tight ACLs.

---

## 8. Verify a Guidance user's Firebase ID token contains `role = "authenticated"`

**When it takes effect:** a user who is *already signed in* keeps their old
token until it refreshes — automatically within ~1 hour, or immediately on a
forced refresh (below). A *new* sign-in mints a token with the current
claims right away.

### Option A — from the server side (fastest check, no app needed)

In a Node REPL with `GOOGLE_APPLICATION_CREDENTIALS` still set:

```js
const admin = require("firebase-admin");
admin.initializeApp();
admin.auth().getUser("THE_UID").then(u => console.log(u.customClaims));
// expect: { role: 'authenticated' }   (plus any other keys, untouched)
```

### Option B — decode the actual ID token the app holds

In the Flutter debug build, after signing in as the guidance user, the
Phase 3 helper already does this locally (no network):

```dart
final claims = await SupabaseAuthProbe.firebaseIdTokenClaims();
print(claims?['role']);        // expect: authenticated
print(claims?['sub']);         // the Firebase UID Supabase will see
```

Or paste the token into an **offline** JWT decoder and read the payload —
never paste a real token into an online tool.

### Option C — end to end through Supabase

After configuring Supabase → Third-Party Auth → Firebase (`guidegrade-470ea`)
and creating the temporary `public.whoami()` diagnostic (see
`functions/README.md`):

```dart
final who = await SupabaseAuthProbe.supabaseWhoAmI();
// expect: auth_role == "authenticated", jwt_role == "authenticated", auth_uid == currentUser.uid
```

## 9. Force-refresh the ID token in the app

After you run `--apply`, tell an already-signed-in guidance user's app to
pull the updated claim without waiting for the ~1 h auto-refresh:

```dart
final user = FirebaseAuth.instance.currentUser;
if (user != null) {
  await user.getIdToken(true);   // forceRefresh: true → new token includes role: "authenticated"
}
```

A natural place is right after `AuthService._authorize` succeeds on the
mobile login, so every fresh sign-in also self-heals a missing claim. (That
wiring is a later phase — this script and its verification do not require
any Flutter change.)

---

## Files in this folder

| file | committed? | purpose |
|---|---|---|
| `backfill-auth-claim.js` | yes | the script |
| `package.json` | yes | declares `firebase-admin` |
| `.gitignore` | yes | blocks `node_modules/` and every `*.json` except the manifest |
| `README.md` | yes | this file |
| `serviceAccountKey.json` (or similar) | **NO — never** | your key; keep it in `%USERPROFILE%\.secrets\` |
| `node_modules/` | no | `npm install` output |
