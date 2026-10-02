"use strict";

/**
 * GuideGrade — Phase 4 / Phase 6A
 * LOCAL one-time backfill of the Supabase-required Firebase custom claims.
 *
 * WHAT IT DOES
 *   For every Firestore `users/{uid}` document where
 *       role     === "guidance_council"
 *       isActive === true
 *   it MERGES  { role: "authenticated", user_role: "guidance_council" }  into
 *   that Firebase user's existing custom claims.
 *     - `role: "authenticated"`  — Supabase's native Firebase third-party auth
 *       requires it; without it the token is the `anon` Postgres role.
 *     - `user_role: "guidance_council"`  — the authorization claim future
 *       Supabase RLS / Storage policies gate on.
 *
 * WHAT IT DOES NOT DO
 *   - It is NOT a Cloud Function and is never deployed. Runs once from a
 *     trusted local machine.
 *   - It NEVER writes Firestore. `users/{uid}` (role, isActive,
 *     guidancePosition, …) is read only.
 *   - It NEVER touches AuthService, UserProvisioningService, the Admin
 *     Console, System Logs, or the OMR/scanner code.
 *   - It NEVER adds `role` / `user_role` to a `system_admin` user or to a
 *     deactivated (`isActive != true`) user.
 *   - It NEVER overwrites unrelated custom claims — it reads the current
 *     claims first and only ever sets/removes the `role` and `user_role` keys.
 *
 * CREDENTIALS
 *   The service-account key is supplied ONLY via the environment variable
 *   GOOGLE_APPLICATION_CREDENTIALS (Application Default Credentials). Its
 *   path and contents never appear in this file, in git, or in any Flutter
 *   build. See README.md for how to obtain, place, use, and delete the key.
 *
 * USAGE
 *   node backfill-auth-claim.js                 # DRY RUN — prints a report, writes nothing
 *   node backfill-auth-claim.js --apply         # merges { role, user_role } into qualifying users
 *   node backfill-auth-claim.js --uid=<uid>     # restrict to one or more users (repeatable); dry run
 *   node backfill-auth-claim.js --uid=<uid> --apply
 *   node backfill-auth-claim.js --revoke-stale --apply
 *        # ALSO strips role="authenticated" and user_role="guidance_council"
 *        # from users who no longer qualify (e.g. after a deactivation) —
 *        # only when they hold those exact values. Off by default.
 *   node backfill-auth-claim.js --verbose       # print each user's existing claim keys
 *
 * EXIT CODES: 0 = ok / clean dry run · 1 = a write failed or a fatal error
 */

const fs = require("fs");
const admin = require("firebase-admin");

const EXPECTED_PROJECT_ID = "guidegrade-470ea";

// ---------------------------------------------------------------------------
// Args
// ---------------------------------------------------------------------------
const ARGV = process.argv.slice(2);
const APPLY = ARGV.includes("--apply");
const REVOKE_STALE = ARGV.includes("--revoke-stale");
const VERBOSE = ARGV.includes("--verbose");
const ONLY_UIDS = ARGV.filter((a) => a.startsWith("--uid="))
  .map((a) => a.slice("--uid=".length).trim())
  .filter(Boolean);

// Claims an ACTIVE guidance_council user must carry:
//   role       -> Supabase third-party auth: selects the `authenticated` Postgres role
//   user_role  -> the authorization claim future Supabase RLS / Storage policies gate on
const CLAIM_KEY = "role";
const CLAIM_VALUE = "authenticated";
const USER_ROLE_KEY = "user_role";
const USER_ROLE_VALUE = "guidance_council";
const DESIRED_CLAIMS = { [CLAIM_KEY]: CLAIM_VALUE, [USER_ROLE_KEY]: USER_ROLE_VALUE };

// ---------------------------------------------------------------------------
// Guard: credentials must come from the environment, never from this repo
// ---------------------------------------------------------------------------
if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  console.error(
    [
      "GOOGLE_APPLICATION_CREDENTIALS is not set.",
      "",
      "Point it at your Firebase service-account JSON (kept OUTSIDE this repo)",
      "and re-run. Example (PowerShell):",
      '  $env:GOOGLE_APPLICATION_CREDENTIALS = "$env:USERPROFILE\\.secrets\\guidegrade\\serviceAccountKey.json"',
      "",
      "See tools/firebase-claims/README.md.",
    ].join("\n")
  );
  process.exit(1);
}

// initializeApp() with no arguments picks up the key from
// GOOGLE_APPLICATION_CREDENTIALS.
admin.initializeApp();

/**
 * Reads ONLY the `project_id` field out of the service-account JSON that
 * GOOGLE_APPLICATION_CREDENTIALS points at. Nothing else from the file is
 * parsed into a variable, returned, logged, or retained — the private key,
 * client_email, key id, etc. are never read. Returns the trimmed project id
 * string, or null if the file can't be read/parsed or has no string
 * `project_id`.
 *
 * This is more reliable than admin.app().options.projectId, which is often
 * left "(unknown)" when the SDK is initialized purely from a credentials
 * file with no explicit projectId and no GOOGLE_CLOUD_PROJECT env var.
 */
function readCredentialProjectId() {
  try {
    const raw = fs.readFileSync(process.env.GOOGLE_APPLICATION_CREDENTIALS, "utf8");
    const projId = JSON.parse(raw).project_id;
    return typeof projId === "string" && projId.trim() ? projId.trim() : null;
  } catch (_) {
    return null;
  }
}

const credentialProjectId = readCredentialProjectId(); // string | null
const projectVerified = credentialProjectId === EXPECTED_PROJECT_ID;

const projectId =
  credentialProjectId ||
  admin.app().options.projectId ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.GCLOUD_PROJECT ||
  "(unknown)";

// ---------------------------------------------------------------------------
function qualifies(userData) {
  return (
    userData != null &&
    userData.role === "guidance_council" &&
    userData.isActive === true
  );
}

function fmt(list) {
  return list.length === 0 ? "  (none)" : list.map((x) => "  " + x).join("\n");
}

/** True iff every key in DESIRED_CLAIMS is already present at the exact value. */
function hasAllDesired(existing) {
  return Object.keys(DESIRED_CLAIMS).every((k) => existing[k] === DESIRED_CLAIMS[k]);
}

/** Which DESIRED_CLAIMS keys are missing or hold the wrong value on `existing`. */
function missingDesired(existing) {
  return Object.keys(DESIRED_CLAIMS).filter((k) => existing[k] !== DESIRED_CLAIMS[k]);
}

// ---------------------------------------------------------------------------
async function main() {
  console.log("GuideGrade — Firebase auth-claim backfill");
  console.log("Project        : " + projectId);
  console.log("Mode           : " + (APPLY ? "APPLY (will write)" : "DRY RUN (no writes)"));
  console.log("Revoke stale   : " + (REVOKE_STALE ? "yes" : "no"));
  if (ONLY_UIDS.length) console.log("Restricted to  : " + ONLY_UIDS.join(", "));
  console.log("Target claims  : " + JSON.stringify(DESIRED_CLAIMS));
  console.log("");

  if (!projectVerified) {
    const detail = credentialProjectId
      ? 'credential project_id is "' + credentialProjectId + '"'
      : "could not read project_id from the service-account credential";
    if (APPLY) {
      console.error(
        '\nREFUSING --apply: ' + detail + ', not "' + EXPECTED_PROJECT_ID + '".\n' +
          "Point GOOGLE_APPLICATION_CREDENTIALS at a " + EXPECTED_PROJECT_ID +
          " service-account key and retry.\n"
      );
      process.exit(1);
    }
    console.log(
      'WARNING: ' + detail + ' (expected "' + EXPECTED_PROJECT_ID + '"). ' +
        "Dry run continues; --apply would be refused.\n"
    );
  }

  const db = admin.firestore();
  const auth = admin.auth();

  // ----- gather users/{uid} docs -----
  let docs;
  if (ONLY_UIDS.length) {
    const refs = ONLY_UIDS.map((uid) => db.collection("users").doc(uid));
    docs = (await db.getAll(...refs)).filter((d) => d.exists);
    const missing = ONLY_UIDS.filter((uid) => !docs.find((d) => d.id === uid));
    if (missing.length) console.log("No users/{uid} doc for: " + missing.join(", ") + "\n");
  } else {
    docs = (await db.collection("users").get()).docs;
  }

  const plan = {
    willSet: [],       // qualifies, but role and/or user_role not yet at the desired value
    alreadySet: [],    // qualifies, both claims already correct
    skipAdmin: [],     // role == "system_admin"
    skipInactive: [],  // role == "guidance_council" && !isActive
    skipOther: [],     // any other / missing role
    willRevoke: [],    // --revoke-stale: no longer qualifies but still carries a managed guidance claim
    noAuthUser: [],    // users/{uid} doc exists but no Firebase Auth user
  };

  for (const doc of docs) {
    const uid = doc.id;
    const data = doc.data() || {};

    let rec;
    try {
      rec = await auth.getUser(uid);
    } catch (e) {
      plan.noAuthUser.push(uid + "  (" + (e.code || e.message) + ")");
      continue;
    }

    const existing = rec.customClaims || {};
    const otherKeys = Object.keys(existing).filter(
      (k) => k !== CLAIM_KEY && k !== USER_ROLE_KEY
    );
    const tail = VERBOSE ? "  [other claims: " + (otherKeys.join(", ") || "none") + "]" : "";
    const carriesManagedClaim =
      existing[CLAIM_KEY] === CLAIM_VALUE || existing[USER_ROLE_KEY] === USER_ROLE_VALUE;

    if (qualifies(data)) {
      if (hasAllDesired(existing)) {
        plan.alreadySet.push(uid + tail);
      } else {
        plan.willSet.push(uid + "  [needs: " + missingDesired(existing).join(", ") + "]" + tail);
      }
    } else {
      if (data.role === "system_admin") {
        plan.skipAdmin.push(uid + (carriesManagedClaim ? "  (carries a managed guidance claim)" : ""));
      } else if (data.role === "guidance_council") {
        plan.skipInactive.push(uid + "  (isActive=" + JSON.stringify(data.isActive) + ")");
      } else {
        plan.skipOther.push(uid + '  (role=' + JSON.stringify(data.role ?? null) + ", isActive=" + JSON.stringify(data.isActive ?? null) + ")");
      }
      if (carriesManagedClaim) {
        plan.willRevoke.push(uid + "  (role=" + JSON.stringify(data.role ?? null) + ", isActive=" + JSON.stringify(data.isActive ?? null) + ")" + tail);
      }
    }
  }

  // ----- report -----
  console.log("================  REPORT  ================");
  console.log("users/{uid} documents scanned : " + docs.length);
  console.log("");
  console.log(
    'WILL SET / UPDATE  role="authenticated", user_role="guidance_council"  (qualifies):\n' +
      fmt(plan.willSet)
  );
  console.log("");
  console.log("ALREADY SET (qualifies, both claims already correct):\n" + fmt(plan.alreadySet));
  console.log("");
  console.log("SKIP — system_admin (never gets role / user_role):\n" + fmt(plan.skipAdmin));
  console.log("");
  console.log("SKIP — inactive guidance_council (never gets role / user_role):\n" + fmt(plan.skipInactive));
  console.log("");
  console.log("SKIP — other / no recognized role:\n" + fmt(plan.skipOther));
  console.log("");
  console.log("NO FIREBASE AUTH USER for this users/{uid} doc:\n" + fmt(plan.noAuthUser));
  console.log("");
  if (REVOKE_STALE) {
    console.log(
      "WILL REVOKE  role / user_role  (--revoke-stale: no longer qualifies):\n" + fmt(plan.willRevoke)
    );
    console.log("");
  } else if (plan.willRevoke.length) {
    console.log(
      "NOTE: " + plan.willRevoke.length +
        " user(s) no longer qualify but still carry a managed guidance claim\n" +
        '      (role="authenticated" and/or user_role="guidance_council").\n' +
        "      Re-run with --revoke-stale --apply to strip those from them.\n"
    );
  }

  const addCount = plan.willSet.length;
  const revokeCount = REVOKE_STALE ? plan.willRevoke.length : 0;
  console.log("SUMMARY: " + addCount + " to set, " + revokeCount + " to revoke, " +
    plan.alreadySet.length + " already correct.");

  if (!APPLY) {
    console.log("\nDRY RUN — nothing was written. Re-run with --apply to make these changes.");
    process.exit(0);
  }

  if (addCount === 0 && revokeCount === 0) {
    console.log("\n--apply: nothing to do.");
    process.exit(0);
  }

  // ----- apply -----
  console.log("\n--apply: writing custom claims (merge only; never clobbers other keys)...\n");
  let ok = 0;
  let failed = 0;

  const targets = [];
  for (const line of plan.willSet) targets.push({ uid: line.split(/\s/)[0], op: "set" });
  if (REVOKE_STALE) {
    for (const line of plan.willRevoke) targets.push({ uid: line.split(/\s/)[0], op: "revoke" });
  }

  for (const t of targets) {
    try {
      // Re-read immediately before writing so the merge is against the
      // freshest claims and no concurrent change is lost.
      const rec = await auth.getUser(t.uid);
      const existing = rec.customClaims || {};
      let next;
      if (t.op === "revoke") {
        // Remove ONLY the managed guidance claims, and only when they hold
        // the exact values this script manages -- never an unrelated value an
        // operator may have set. Every other claim key is preserved.
        next = { ...existing };
        if (existing[USER_ROLE_KEY] === USER_ROLE_VALUE) delete next[USER_ROLE_KEY];
        if (existing[CLAIM_KEY] === CLAIM_VALUE) delete next[CLAIM_KEY];
      } else {
        // Merge: overwrite ONLY role + user_role, keep every other claim key.
        next = { ...existing, ...DESIRED_CLAIMS };
      }
      // Firebase Admin SDK: pass an object, or null to clear ALL claims.
      const payload = Object.keys(next).length === 0 ? null : next;
      await auth.setCustomUserClaims(t.uid, payload);
      ok++;
      console.log("  " + (t.op === "revoke" ? "revoked " : "set     ") + t.uid);
    } catch (e) {
      failed++;
      console.error("  FAILED  " + t.uid + " : " + (e.code || e.message));
    }
  }

  console.log("\nDone. ok=" + ok + " failed=" + failed);
  console.log(
    "Affected users receive the updated claims on their NEXT ID-token refresh\n" +
      "(automatic within ~1 hour) or immediately after the app calls\n" +
      "  await FirebaseAuth.instance.currentUser!.getIdToken(true);\n"
  );
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("Fatal:", e && (e.stack || e.message || e));
  process.exit(1);
});
