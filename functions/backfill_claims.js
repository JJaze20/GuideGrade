"use strict";

/**
 * One-time / recovery backfill.
 *
 * Applies the SAME claim policy as index.js's syncSupabaseAuthClaim (shared
 * via claims.js) to every EXISTING users/{uid} document: active Guidance
 * Council users get role="authenticated" + user_role="guidance_council";
 * everyone else has those two claims removed. Unrelated custom claims are
 * preserved (merge, never replace).
 *
 * Safe to re-run: idempotent (skips users already correct) and never writes
 * Firestore. NOTE: this WRITES Firebase custom claims -- it is a manual
 * migration/recovery tool; do not run it against production unless intended.
 *
 * (The separate tools/firebase-claims/backfill-auth-claim.js remains
 * available too; it has a dry-run mode and --revoke-stale.)
 *
 * RUN:
 *   cd functions
 *   npm install
 *   # authenticate with a service account for project guidegrade-470ea:
 *   export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/serviceAccountKey.json
 *   node backfill_claims.js
 *
 * The service account needs: Firebase Authentication Admin + Cloud Datastore
 * User (read). Do NOT commit the key. Delete it after the backfill.
 */

const admin = require("firebase-admin");
const { syncUserClaims, readCurrentUserData } = require("./claims");

admin.initializeApp();

(async () => {
  const db = admin.firestore();
  const snap = await db.collection("users").get();
  const tally = { updated: 0, unchanged: 0, "no-auth-user": 0 };

  for (const doc of snap.docs) {
    const uid = doc.id;
    // Same shared logic as the trigger: re-reads the live doc per user.
    const result = await syncUserClaims({
      auth: admin.auth(),
      uid,
      readUserData: () => readCurrentUserData(db, uid),
      logger: console,
    });
    tally[result]++;
    if (result === "updated") console.log(`users/${uid}: claims updated`);
  }

  console.log(
    `\nbackfill complete — updated=${tally.updated} unchanged=${tally.unchanged} ` +
      `noAuthUser=${tally["no-auth-user"]} total=${snap.size}`
  );
  process.exit(0);
})().catch((err) => {
  console.error("backfill failed:", err);
  process.exit(1);
});
