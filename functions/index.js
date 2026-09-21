"use strict";

/**
 * GuideGrade Cloud Function: keep the Firebase custom claims Supabase needs
 * in sync with the Firestore `users/{uid}` document.
 *
 * Claim policy (see claims.js for the full rules and their tests):
 *   ACTIVE guidance_council -> role="authenticated" AND user_role="guidance_council"
 *   everyone else           -> those two claims absent
 *
 * Properties:
 *   - Authorization comes only from the CURRENT Firestore document (re-read
 *     on every run, never the possibly-stale event snapshot), never from
 *     client-supplied data.
 *   - Unrelated existing custom claims are preserved (merge, not replace).
 *   - It only READS Firestore and calls admin.auth() (getUser /
 *     setCustomUserClaims). It NEVER writes Firestore, so the `lastLoginAt` write on every login cannot
 *     cause a loop -- that write just runs a cheap no-op comparison.
 *   - A claim change does NOT rewrite an already-issued ID token: the user
 *     picks it up on their next token refresh (automatic within ~1 hour) or
 *     re-login. See README.md.
 */

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { logger } = require("firebase-functions/v2");
const admin = require("firebase-admin");

const { syncUserClaims, readCurrentUserData } = require("./claims");

admin.initializeApp();

// Region MUST match the Firestore database location (`(default)` is in
// asia-southeast1) -- Gen 2 Firestore triggers are location-bound.
//
// retry: true -- failed executions (a thrown Auth/Firestore error, a timeout,
// a crash between the claim write and its verification) are delivered again,
// so a failed deactivation cannot stay authorized indefinitely. Safe because
// the handler is idempotent and every run re-reads the LIVE users/{uid}
// document, so a redelivered (older) event can never re-grant stale claims.
exports.syncSupabaseAuthClaim = onDocumentWritten(
  { document: "users/{uid}", region: "asia-southeast1", retry: true },
  async (event) => {
    const uid = event.params.uid;
    const db = admin.firestore();

    // The event's own snapshot is deliberately IGNORED: events can arrive
    // out of order, so a stale one must never decide the claims. The live
    // users/{uid} document is re-read (and re-verified after any write) --
    // see syncUserClaims in claims.js. A deleted document reads as null.
    await syncUserClaims({
      auth: admin.auth(),
      uid,
      readUserData: () => readCurrentUserData(db, uid),
      logger,
    });
  }
);
