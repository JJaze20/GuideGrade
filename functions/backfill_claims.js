"use strict";

/**
 * One-time backfill for Phase 3.
 *
 * Applies the SAME claim policy as index.js's syncSupabaseAuthClaim to every
 * EXISTING users/{uid} document, so accounts that were provisioned before the
 * trigger was deployed also get (or correctly lack) the `role: "authenticated"`
 * Firebase custom claim.
 *
 * Safe to re-run: it is idempotent (skips users whose claim already matches)
 * and never writes Firestore.
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

admin.initializeApp();

function desiredRoleClaim(userData) {
  const isActiveGuidance =
    userData != null &&
    userData.role === "guidance_council" &&
    userData.isActive === true;
  return isActiveGuidance ? "authenticated" : null;
}

(async () => {
  const snap = await admin.firestore().collection("users").get();
  let changed = 0;
  let unchanged = 0;
  let noAuthUser = 0;

  for (const doc of snap.docs) {
    const uid = doc.id;
    const wanted = desiredRoleClaim(doc.data());

    let userRecord;
    try {
      userRecord = await admin.auth().getUser(uid);
    } catch (err) {
      noAuthUser++;
      console.warn(`skip users/${uid}: no Firebase Auth user (${err.code || err.message})`);
      continue;
    }

    const current =
      (userRecord.customClaims && userRecord.customClaims.role) || null;

    if (current === wanted) {
      unchanged++;
      continue;
    }

    await admin.auth().setCustomUserClaims(uid, wanted ? { role: wanted } : null);
    changed++;
    console.log(`users/${uid}: "${current || "none"}" -> "${wanted || "none"}"`);
  }

  console.log(
    `\nbackfill complete — changed=${changed} unchanged=${unchanged} noAuthUser=${noAuthUser} total=${snap.size}`
  );
  process.exit(0);
})().catch((err) => {
  console.error("backfill failed:", err);
  process.exit(1);
});
