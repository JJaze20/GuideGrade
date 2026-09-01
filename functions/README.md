# GuideGrade Cloud Functions — Phase 3 (Supabase auth-claim projection)

Scope of this phase: connect the **existing** Firebase Authentication to
Supabase using Supabase's native Firebase third-party auth. Nothing else —
no tables, no RLS, no Storage policies, no sync.

The Flutter side is done (`pubspec.yaml`, `lib/main.dart`,
`lib/core/services/supabase_auth_probe.dart`). This directory is the one
server-side piece: a Cloud Function that sets the single custom claim
Supabase requires.

---

## 1. What `syncSupabaseAuthClaim` does

Firestore trigger on `users/{uid}` writes. On every change it sets the
Firebase custom claim:

| `users/{uid}` state | custom claim applied |
|---|---|
| `role == 'guidance_council'` **and** `isActive == true` | `{ "role": "authenticated" }` |
| anything else — `system_admin`, deactivated, unknown role, deleted doc, no matching Auth user | claims cleared (`null`) |

It **never** writes Firestore, never changes `role`/`isActive`, never
touches the Admin Console or any login code. It only calls
`admin.auth().setCustomUserClaims`.

`role: "authenticated"` grants nothing on its own — with no tables and no
policies it just makes Supabase run the request as the `authenticated`
Postgres role instead of `anon`. A `system_admin` never receives it, so a
`system_admin` is `anon` to Supabase and denied by default (now, and after
RLS is added later).

`user_role` is intentionally **not** set yet. When a later phase adds it,
change the `setCustomUserClaims` payloads to **merge** rather than replace.

---

## 2. Deploy

```bash
cd functions
npm install
firebase use guidegrade-470ea          # if not already the active project
firebase deploy --only functions:syncSupabaseAuthClaim
```

Requires: Node 20, Firebase CLI, Blaze plan (Cloud Functions v2 needs it).
`firebase.json` already has the `functions` codebase entry.

---

## 3. One-time backfill for existing users

```bash
cd functions
npm install
export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/serviceAccountKey.json   # project guidegrade-470ea
node backfill_claims.js
```

Idempotent and safe to re-run. Prints one line per changed user and a
summary. Service account needs *Firebase Authentication Admin* + read on
Firestore. **Do not commit the key; delete it afterwards.**

New users provisioned after deploy need no backfill — the trigger fires on
the `users/{uid}` write that `UserProvisioningService` already performs.
The account's **first login** issues a fresh ID token that carries the
claim (or call `user.getIdToken(true)` once to force-pull it).

---

## 4. Supabase configuration (dashboard — no code)

Supabase → **Authentication → Sign In / Providers → Third-Party Auth → Add
provider → Firebase**, then enter Firebase **Project ID**:

```
guidegrade-470ea
```

Supabase then trusts tokens where
`iss = https://securetoken.google.com/guidegrade-470ea` and
`aud = guidegrade-470ea`, verifying the RS256 signature against Google's
public JWKS. No secret is entered anywhere.

Local dev equivalent (`supabase/config.toml`):

```toml
[auth.third_party.firebase]
enabled = true
project_id = "guidegrade-470ea"
```

**Do not create tables, RLS policies, or Storage policies in this phase.**

---

## 5. Optional diagnostic: `public.whoami()`

Only needed for the deeper proof in step 6. It is a plain claims echo — not
an examination table and not an RLS policy. Create it, run the proof, then
drop it.

```sql
-- run in the Supabase SQL editor; DROP FUNCTION public.whoami(); when done
create or replace function public.whoami()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'auth_uid',       auth.uid(),                 -- Firebase UID (sub claim)
    'auth_role',      auth.role(),                -- Postgres role from the token
    'jwt_role',       auth.jwt() ->> 'role',      -- the custom claim we set
    'jwt_iss',        auth.jwt() ->> 'iss',
    'jwt_email',      auth.jwt() ->> 'email',
    'jwt_user_role',  auth.jwt() ->> 'user_role'  -- expected NULL in Phase 3
  );
$$;

grant execute on function public.whoami() to anon, authenticated;
```

---

## 6. Proof procedure (`SupabaseAuthProbe`)

Build with the Supabase defines (publishable/anon key only — never
`service_role`):

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<publishable-anon-key>
```

Then, from a debug build, after signing in, call the probe (temporary
button / hot-reload one-liner / DevTools):

| step | call | pass condition |
|---|---|---|
| 1. Guidance user logs into GuideGrade | (existing login) | reaches Staff Home |
| 2. Token carries `role=authenticated` | `SupabaseAuthProbe.firebaseIdTokenClaims()` | map contains `"role": "authenticated"` and a `sub` |
| 3. Supabase accepts the Firebase token | `SupabaseAuthProbe.supabaseWhoAmI()` | returns a row (no `PostgrestException` / 401) |
| 4. Supabase sees the right UID | same result | `auth_uid` == the Firebase `currentUser.uid` |
| 5. Logout removes authorization | `FirebaseAuth.signOut()` then `supabaseWhoAmI()` | `auth_uid` is `null` (anonymous) |
| 6. `system_admin` gets no guidance access | log in as `system_admin`, `firebaseIdTokenClaims()` | **no** `role` claim → `whoami().auth_role` is `anon`, `jwt_role` is `null`; there is nothing a `system_admin` can read |
| 7. Unauthenticated request denied | call `supabaseWhoAmI()` with nobody signed in | `auth_uid` `null`; any future guidance table/policy denies `anon` |

`jwt_user_role` must be `null` for everyone in Phase 3 — `user_role` is a
later phase.
