"use strict";

/**
 * GuideGrade — Phase 3 Cloud Function.
 *
 * PURPOSE (and the ONLY thing this function does):
 *   Project the single Firebase custom claim that Supabase's native Firebase
 *   third-party auth integration requires — `role: "authenticated"` — from
 *   the app's existing source of truth, the Firestore `users/{uid}` doc.
 *
 * It is a READ-ONLY PROJECTION:
 *   - never writes Firestore
 *   - never changes `role`, `isActive`, `guidancePosition`, or any user field
 *   - never touches the Admin Console, User Management, System Logs,
 *     AuthService, UserProvisioningService, or any login flow
 *   - only calls admin.auth().setCustomUserClaims(uid, ...)
 *
 * CLAIM POLICY (smallest safe form for Phase 3):
 *   active guidance_council user  ->  { role: "authenticated" }
 *   everyone else (system_admin, deactivated, unknown role, deleted doc,
 *                  no matching auth user)  ->  claims cleared (null)
 *
 *   `role: "authenticated"` on its own GRANTS NOTHING — with no tables and
 *   no RLS/Storage policies deployed it only lets Supabase run the request
 *   as the `authenticated` Postgres role instead of `anon`. Because a
 *   system_admin's token never gets this claim, a system_admin is `anon` to
 *   Supabase and is denied by default now and after RLS is added later.
 *
 *   `user_role` (the guidance-vs-admin authorization claim used by future
 *   RLS) is deliberately NOT set here yet. When it is added in a later
 *   phase, replace the `setCustomUserClaims` payloads below with a merged
 *   object rather than overwriting.
 */

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

admin.initializeApp();

/** Desired `role` claim value for a given users/{uid} doc snapshot. */
function desiredRoleClaim(userData) {
  const isActiveGuidance =
    userData != null &&
    userData.role === "guidance_council" &&
    userData.isActive === true;
  return isActiveGuidance ? "authenticated" : null;
}

exports.syncSupabaseAuthClaim = onDocumentWritten(
  { document: "users/{uid}", region: "us-central1" },
  async (event) => {
    const uid = event.params.uid;

    const afterSnap = event.data && event.data.after;
    const userData =
      afterSnap && afterSnap.exists ? afterSnap.data() : null; // null = doc deleted

    const wanted = desiredRoleClaim(userData);

    let userRecord;
    try {
      userRecord = await admin.auth().getUser(uid);
    } catch (err) {
      // The users/{uid} id is the Firebase Auth UID by construction
      // (see UserProvisioningService). If there is no auth user, there is
      // nothing to project a claim onto.
      logger.warn(
        `syncSupabaseAuthClaim: no Firebase Auth user for users/${uid} (${err.code || err.message}); skipping`
      );
      return;
    }

    const current =
      (userRecord.customClaims && userRecord.customClaims.role) || null;

    if (current === wanted) {
      return; // no-op — avoids forcing a needless ID-token refresh
    }

    // Preserve nothing else on purpose: Phase 3 uses exactly one custom
    // claim. (A later phase that introduces `user_role` must merge instead.)
    const nextClaims = wanted ? { role: wanted } : null;

    await admin.auth().setCustomUserClaims(uid, nextClaims);

    logger.info(
      `syncSupabaseAuthClaim: users/${uid} role claim "${current || "none"}" -> "${wanted || "none"}"`
    );
  }
);
