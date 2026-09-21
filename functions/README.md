# GuideGrade Cloud Functions — Supabase auth-claim synchronization

Connects the **existing** Firebase Authentication to Supabase (native Firebase
third-party auth) by keeping two Firebase custom claims in sync with the
Firestore `users/{uid}` document. No tables, RLS, or Storage policies are
created here.

**Status: written and unit-tested, NOT deployed.** See §3 for prerequisites
and the exact commands.

---

## Current configuration

Defined in `functions/index.js`:

| Setting | Value |
|---|---|
| Function | `syncSupabaseAuthClaim` |
| Type | Cloud Functions **Gen 2** Firestore trigger (`onDocumentWritten`) |
| Trigger path | `users/{uid}` (created, updated, or deleted) |
| Region | `asia-southeast1` (must match the Firestore database location) |
| Retry | `retry: true` — failed executions may be delivered again |
| Runtime | Node 20 (`package.json` engines) |

Behavior summary:

- **Idempotent.** Running the sync any number of times for the same document
  state produces the same claims, and it writes nothing when the claims are
  already correct, so redelivered or duplicate events are harmless.
- **Reads the current document, not the event snapshot.** The handler ignores
  the event's own data and reads the live `users/{uid}` document each run, so
  a delayed or out-of-order event cannot re-grant stale claims.
- **Post-write verification / reconciliation.** After any claim write it
  re-reads the document and re-checks; if the document changed underneath the
  write, the next pass corrects the claims (max 3 passes, then it throws).
- **Failures may be retried.** Because `retry: true` is set, an execution that
  throws (Auth or Firestore error, timeout, crash between the write and its
  verification) can be retried by the Gen 2 trigger. Retries are safe for the
  two reasons above: the handler is idempotent and every retry re-reads the
  live document. Without retry, a failed deactivation could leave claims
  granted until someone corrected them manually.
- **Existing ID-token lifetime still applies.** Changing claims does not
  rewrite tokens that were already issued (see "Token refresh limitation").

---

## 1. What `syncSupabaseAuthClaim` does

Firestore trigger (Gen 2, `asia-southeast1` — it must match the Firestore
database location) on every write to `users/{uid}`. It re-reads the CURRENT
document (never client-supplied data, and never the trigger event's own
possibly-stale snapshot) and ensures:

| `users/{uid}` state | GuideGrade claims on the Firebase user |
|---|---|
| `role == 'guidance_council'` **and** `isActive == true` | `role = "authenticated"` **and** `user_role = "guidance_council"` |
| `system_admin`, inactive, unknown role, or deleted doc | those two claims **absent** |

- `role: "authenticated"` makes Supabase run the request as the `authenticated`
  Postgres role instead of `anon`. `user_role` is what the RLS policies on
  `public.examinees` check (`auth.jwt() ->> 'user_role' = 'guidance_council'`).
- **Other custom claims are preserved.** `setCustomUserClaims` replaces the
  whole claims object, so the function reads the user's current claims and
  writes back a merged object; only `role` / `user_role` are added,
  overwritten, or removed. Removal is conservative: `role` only if it is
  exactly `"authenticated"`, `user_role` only if exactly `"guidance_council"`.
- **Out-of-order events are safe.** Firestore delivers events at least once
  and not in order, so the function ignores the event data, reads the live
  `users/{uid}` document, and after any claim write re-reads and re-verifies
  (up to 3 passes, then fails loudly). The final claim state therefore
  converges on the current document; an older "active" event can never
  re-grant claims to a since-deactivated user. Firestore is only ever READ.
- **No writes when nothing changed.** Every login writes `lastLoginAt` to the
  user doc, which re-runs the function; it compares and does nothing.
- **No loop.** The function only READS Firestore and calls
  `admin.auth().getUser` / `setCustomUserClaims`; it never writes Firestore.
- **Retries.** `retry: true` is set on the trigger, so a failed execution may
  be retried. Each retry re-reads the live document, so a retried older event
  cannot re-grant stale claims.
- Logic lives in `claims.js` (pure, tested); `index.js` is a thin trigger.

It does **not** disable Auth accounts, revoke refresh tokens, or touch
`users/{uid}`.

### Token refresh limitation (important)

Changing custom claims does **not** rewrite an already-issued ID token. A user
sees a new/removed claim only after their token refreshes:

- automatically within ~1 hour, or
- immediately after re-login or `getIdToken(true)`.

Consequences: a newly created Guidance Council user's first token may predate
the function's claim write, so Supabase treats it as `anon` until refresh. And
a **deactivated** user's already-issued token (and any token they refresh
before the function runs) keeps its claims until it expires — Supabase RLS
only sees the token. The app does not force-refresh tokens; that is unchanged.

This limitation applies regardless of the trigger's retry setting: retrying
makes the claim change on the Firebase user eventually happen, but it cannot
shorten the lifetime of a token that was already issued.

---

## 2. Tests

```bash
cd functions
npm test        # node --test claims.test.js — no Firebase, network, or credentials
```

Covers: active Guidance Council, System Admin, inactive Guidance Council,
deleted doc, role changes, reactivation, preservation of unrelated claims,
no-op when already correct, missing Auth user, stale-event / read-write race
correction, non-stabilizing documents, error propagation from Auth and
Firestore reads, and the current-document lookup helper.

---

## 3. Deploy (NOT yet run)

Requires: Node 20 runtime (see `package.json` engines), Firebase CLI, and the
**Blaze (pay-as-you-go) plan** — Gen 2 functions run on Cloud Run / Cloud
Build / Eventarc. Enabling the required Google APIs happens on first deploy.

```bash
cd functions
npm install
firebase use guidegrade-470ea
firebase deploy --only functions:syncSupabaseAuthClaim
```

The trigger only fires on writes made AFTER deployment. Existing users need
the backfill (§4) or any write to their `users/{uid}` doc (e.g. their next
login writes `lastLoginAt`, which runs the sync).

---

## 4. Backfill for existing users (manual, migration/recovery)

Two manual tools remain available; neither is run automatically:

- `functions/backfill_claims.js` — applies the same policy as the function to
  every user (merge-safe). **Writes production claims** when run.
- `tools/firebase-claims/backfill-auth-claim.js` — dry-run by default,
  `--apply` to write, `--revoke-stale` to strip stale claims.

Both need a service-account key (`GOOGLE_APPLICATION_CREDENTIALS`). Do not
commit the key; delete it afterwards.

---

## 5. Supabase configuration (dashboard — no code)

Supabase → **Authentication → Sign In / Providers → Third-Party Auth → Add
provider → Firebase**, Firebase **Project ID** `guidegrade-470ea`. Supabase
then trusts tokens where `iss = https://securetoken.google.com/guidegrade-470ea`
and `aud = guidegrade-470ea`.

---

## 6. Verifying claims on a real session

Use the temporary read-only diagnostic (`temp_diagnostics/diag_token_claims.dart`,
untracked) to see which claims a signed-in user's token carries. Expected
after deployment + token refresh:

| Account | `role` | `user_role` |
|---|---|---|
| Active Guidance Council | `authenticated` | `guidance_council` |
| System Admin | absent | absent |
| Deactivated Guidance Council (after refresh) | absent | absent |
