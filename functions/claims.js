"use strict";

/**
 * GuideGrade authorization-claim synchronization (pure logic, no Firebase
 * imports, so it is unit-testable with a fake Auth client).
 *
 * The source of truth is the Firestore `users/{uid}` document -- never any
 * client-supplied value. Two Firebase custom claims are GuideGrade-managed:
 *
 *   role      = "authenticated"      -> Supabase third-party auth: selects the
 *                                       `authenticated` Postgres role
 *   user_role = "guidance_council"   -> what the Supabase RLS policies gate on
 *
 * ACTIVE guidance_council user  -> both claims present with those values.
 * Anyone else (system_admin, inactive, unknown role, deleted doc)
 *                               -> those two claims absent.
 *
 * `setCustomUserClaims` REPLACES the whole custom-claims object, so this
 * module always reads the user's current claims first and writes back a
 * merged object: only `role` / `user_role` are ever added, overwritten, or
 * removed; every other claim key is preserved untouched.
 *
 * Removal is conservative: `role` is removed only when it is exactly
 * "authenticated", and `user_role` only when it is exactly
 * "guidance_council" -- an unrelated value someone set on those keys is left
 * alone (same rule as tools/firebase-claims/backfill-auth-claim.js
 * --revoke-stale).
 */

const ROLE_KEY = "role";
const ROLE_VALUE = "authenticated";
const USER_ROLE_KEY = "user_role";
const USER_ROLE_VALUE = "guidance_council";

/** True iff this users/{uid} document describes an active Guidance Council user. */
function qualifies(userData) {
  return (
    userData != null &&
    userData.role === "guidance_council" &&
    userData.isActive === true
  );
}

/**
 * Computes the claims object that should exist for a user.
 *
 * @param {object|null} userData  the users/{uid} document data (null = deleted)
 * @param {object|null} existing  the user's current custom claims
 * @returns {{claims: object|null, changed: boolean}}
 *   `claims` is what to pass to setCustomUserClaims (null = clear all, only
 *   when nothing at all remains); `changed` is false when no write is needed.
 */
function computeClaims(userData, existing) {
  const current = existing || {};
  const next = { ...current };

  if (qualifies(userData)) {
    next[ROLE_KEY] = ROLE_VALUE;
    next[USER_ROLE_KEY] = USER_ROLE_VALUE;
  } else {
    if (next[ROLE_KEY] === ROLE_VALUE) delete next[ROLE_KEY];
    if (next[USER_ROLE_KEY] === USER_ROLE_VALUE) delete next[USER_ROLE_KEY];
  }

  const keys = new Set([...Object.keys(current), ...Object.keys(next)]);
  const changed = [...keys].some((k) => current[k] !== next[k]);
  const claims = Object.keys(next).length === 0 ? null : next;
  return { claims, changed };
}

/**
 * Reads the CURRENT `users/{uid}` document straight from Firestore (Admin
 * SDK, read-only; a plain `get()` is strongly consistent).
 *
 * @param {{doc: Function}} db  admin.firestore()
 * @returns {Promise<object|null>} the document data, or null if it does not exist
 */
async function readCurrentUserData(db, uid) {
  const snap = await db.doc(`users/${uid}`).get();
  return snap.exists ? snap.data() : null;
}

/** Upper bound on re-verification passes (see syncUserClaims). */
const MAX_PASSES = 3;

/**
 * Synchronizes one user's claims from their CURRENT Firestore document.
 *
 * Why it re-reads instead of trusting the trigger event: Firestore events are
 * delivered at least once and NOT in guaranteed order, so an older event
 * (e.g. an `isActive: true` write) can arrive after a newer deactivation and,
 * if its snapshot were trusted, re-grant claims. This function ignores the
 * event's data entirely and asks `readUserData` for the live document.
 *
 * Why it also verifies after writing: a read-then-write can still interleave
 * with another invocation (read doc -> [doc changes, newer invocation writes]
 * -> this invocation writes its now-stale result). So after every write it
 * loops: re-read the document and recompute. If the document still says what
 * we just applied, `computeClaims` reports "no change" and we stop; if it
 * changed underneath us, the next pass corrects it. Consequently the last
 * invocation to write always finishes by observing the live document, and any
 * later document change triggers its own invocation -- the final claim state
 * converges on the current document. No delays, sleeps or timestamps needed.
 *
 * Only ever calls `readUserData` (a Firestore READ), `auth.getUser`, and
 * `auth.setCustomUserClaims` -- it never writes Firestore, so it cannot
 * retrigger itself (e.g. from the `lastLoginAt` write on every login).
 * Errors from any of them propagate to the caller (nothing is swallowed
 * except a missing Auth user, which is reported as "no-auth-user").
 *
 * @param {{getUser: Function, setCustomUserClaims: Function}} auth  admin.auth()
 * @param {() => Promise<object|null>} readUserData  returns the CURRENT users/{uid} data (null = missing)
 * @returns {Promise<"no-auth-user"|"unchanged"|"updated">}
 */
async function syncUserClaims({ auth, uid, readUserData, logger }) {
  let wrote = false;

  for (let pass = 1; pass <= MAX_PASSES; pass++) {
    const userData = await readUserData();

    let userRecord;
    try {
      userRecord = await auth.getUser(uid);
    } catch (err) {
      // users/{uid} id is the Firebase Auth UID by construction; no auth user
      // means there is nothing to project claims onto.
      if (logger) {
        logger.warn(
          `syncUserClaims: no Firebase Auth user for users/${uid} (${err.code || err.message}); skipping`
        );
      }
      return wrote ? "updated" : "no-auth-user";
    }

    const { claims, changed } = computeClaims(userData, userRecord.customClaims);
    if (!changed) return wrote ? "updated" : "unchanged"; // verified against the live doc

    await auth.setCustomUserClaims(uid, claims);
    wrote = true;
    if (logger) {
      logger.info(
        `syncUserClaims: users/${uid} claims updated (authorized=${qualifies(userData)}, pass ${pass})`
      );
    }
    // Loop: re-read the doc and verify nothing changed underneath this write.
  }

  throw new Error(
    `syncUserClaims: users/${uid} did not stabilize after ${MAX_PASSES} passes (document keeps changing)`
  );
}

module.exports = {
  ROLE_KEY,
  ROLE_VALUE,
  USER_ROLE_KEY,
  USER_ROLE_VALUE,
  qualifies,
  computeClaims,
  readCurrentUserData,
  syncUserClaims,
  MAX_PASSES,
};
