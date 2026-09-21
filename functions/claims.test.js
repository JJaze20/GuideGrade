"use strict";

// Run with: cd functions && npm test   (uses Node's built-in test runner; no
// Firebase, network, or credentials involved -- everything is a fake).

const test = require("node:test");
const assert = require("node:assert/strict");
const { computeClaims, qualifies, syncUserClaims, readCurrentUserData, MAX_PASSES } = require("./claims");

const activeGuidance = { role: "guidance_council", isActive: true };
const inactiveGuidance = { role: "guidance_council", isActive: false };
const admin = { role: "system_admin", isActive: true };
const BOTH = { role: "authenticated", user_role: "guidance_council" };

/**
 * Fake admin.auth(): STATEFUL (a write changes what the next getUser sees, as
 * in real Firebase) and it records every write. `failSet` makes writes reject.
 * Only getUser / setCustomUserClaims exist -- there is nothing on it (and no
 * Firestore write path at all) that could retrigger the function.
 */
function fakeAuth(claims, { missing = false, failSet = null } = {}) {
  let current = claims;
  const calls = { set: [], get: 0 };
  return {
    calls,
    get claims() {
      return current;
    },
    async getUser() {
      calls.get++;
      if (missing) throw Object.assign(new Error("nope"), { code: "auth/user-not-found" });
      return { customClaims: current };
    },
    async setCustomUserClaims(uid, c) {
      if (failSet) throw failSet;
      calls.set.push({ uid, claims: c });
      current = c === null ? undefined : c;
    },
  };
}

/** A readUserData that returns the given docs in order (last one repeats). */
function docSequence(...docs) {
  let i = 0;
  const fn = async () => docs[Math.min(i++, docs.length - 1)];
  fn.reads = () => i;
  return fn;
}

test("qualifies: only an ACTIVE guidance_council user", () => {
  assert.equal(qualifies(activeGuidance), true);
  assert.equal(qualifies(inactiveGuidance), false);
  assert.equal(qualifies(admin), false);
  assert.equal(qualifies({ role: "guidance_council" }), false); // isActive missing
  assert.equal(qualifies({ role: "guidance_council", isActive: "true" }), false); // strict boolean
  assert.equal(qualifies({ role: "unknown", isActive: true }), false);
  assert.equal(qualifies(null), false);
});

test("active Guidance Council with no claims receives BOTH claims", () => {
  const r = computeClaims(activeGuidance, undefined);
  assert.deepEqual(r.claims, BOTH);
  assert.equal(r.changed, true);
});

test("active Guidance Council that only has the old `role` claim gains user_role", () => {
  const r = computeClaims(activeGuidance, { role: "authenticated" });
  assert.deepEqual(r.claims, BOTH);
  assert.equal(r.changed, true);
});

test("active Guidance Council already correct -> no write needed", () => {
  const r = computeClaims(activeGuidance, { ...BOTH });
  assert.equal(r.changed, false);
});

test("System Admin never receives the GuideGrade claims", () => {
  const r = computeClaims(admin, undefined);
  assert.equal(r.changed, false);
  assert.equal(r.claims, null);
});

test("System Admin that somehow carries the claims has them removed", () => {
  const r = computeClaims(admin, { ...BOTH });
  assert.equal(r.changed, true);
  assert.equal(r.claims, null); // nothing else left -> cleared
});

test("inactive Guidance Council loses both claims", () => {
  const r = computeClaims(inactiveGuidance, { ...BOTH });
  assert.equal(r.changed, true);
  assert.equal(r.claims, null);
});

test("deleted users/{uid} document (null) loses both claims", () => {
  const r = computeClaims(null, { ...BOTH });
  assert.equal(r.changed, true);
  assert.equal(r.claims, null);
});

test("unrelated existing claims are PRESERVED when adding", () => {
  const r = computeClaims(activeGuidance, { plan: "pro", beta: true });
  assert.deepEqual(r.claims, { plan: "pro", beta: true, ...BOTH });
});

test("unrelated existing claims are PRESERVED when removing", () => {
  const r = computeClaims(inactiveGuidance, { ...BOTH, plan: "pro", beta: true });
  assert.deepEqual(r.claims, { plan: "pro", beta: true });
  assert.equal(r.changed, true);
});

test("removal is conservative: an unrelated value on role/user_role is left alone", () => {
  const r = computeClaims(admin, { role: "editor", user_role: "custom" });
  assert.equal(r.changed, false);
});

test("role change guidance_council -> system_admin removes the claims", () => {
  const before = computeClaims(activeGuidance, undefined).claims;
  const after = computeClaims(admin, before);
  assert.equal(after.changed, true);
  assert.equal(after.claims, null);
});

test("role change system_admin -> guidance_council adds the claims", () => {
  const after = computeClaims(activeGuidance, { plan: "pro" });
  assert.deepEqual(after.claims, { plan: "pro", ...BOTH });
});

test("reactivation (isActive false -> true) restores both claims", () => {
  const off = computeClaims(inactiveGuidance, { ...BOTH }).claims; // null
  const on = computeClaims(activeGuidance, off);
  assert.deepEqual(on.claims, BOTH);
  assert.equal(on.changed, true);
});

test("computeClaims does not mutate its input", () => {
  const existing = { ...BOTH, plan: "pro" };
  const snapshot = { ...existing };
  computeClaims(inactiveGuidance, existing);
  assert.deepEqual(existing, snapshot);
});


// ---------------------------------------------------------------------------
// syncUserClaims: re-reads the CURRENT document (stale-event safety)
// ---------------------------------------------------------------------------

test("A/create: active Guidance Council gets both claims, unrelated claim preserved", async () => {
  const auth = fakeAuth({ some_other_claim: "keep-me" });
  const result = await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(activeGuidance) });
  assert.equal(result, "updated");
  assert.deepEqual(auth.claims, { some_other_claim: "keep-me", ...BOTH });
});

test("B/H: inactive Guidance Council loses both claims, unrelated claim preserved", async () => {
  const auth = fakeAuth({ some_other_claim: "keep-me", ...BOTH });
  const result = await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(inactiveGuidance) });
  assert.equal(result, "updated");
  assert.deepEqual(auth.claims, { some_other_claim: "keep-me" });
});

test("C/H: System Admin ends with neither managed claim, unrelated claim preserved", async () => {
  const auth = fakeAuth({ some_other_claim: "keep-me" });
  const result = await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(admin) });
  assert.equal(result, "unchanged");
  assert.deepEqual(auth.claims, { some_other_claim: "keep-me" });
  assert.equal(auth.calls.set.length, 0);
});

test("D: reactivation restores both claims", async () => {
  const auth = fakeAuth({ some_other_claim: "keep-me" });
  await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(activeGuidance) });
  await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(inactiveGuidance) });
  assert.deepEqual(auth.claims, { some_other_claim: "keep-me" });
  await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(activeGuidance) });
  assert.deepEqual(auth.claims, { some_other_claim: "keep-me", ...BOTH });
});

test("E/F: role change TO Guidance Council grants, role change AWAY revokes", async () => {
  const auth = fakeAuth(undefined);
  await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(activeGuidance) });
  assert.deepEqual(auth.claims, BOTH);
  await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(admin) });
  assert.equal(auth.claims, undefined); // nothing else left -> cleared
});

test("G: deleted user document (null) revokes and preserves unrelated claims", async () => {
  const auth = fakeAuth({ some_other_claim: "keep-me", ...BOTH });
  const result = await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(null) });
  assert.equal(result, "updated");
  assert.deepEqual(auth.claims, { some_other_claim: "keep-me" });
});

test("I: no-op when claims already correct -- one read, no write (e.g. every lastLoginAt write)", async () => {
  const auth = fakeAuth({ ...BOTH });
  const read = docSequence(activeGuidance);
  const result = await syncUserClaims({ auth, uid: "u1", readUserData: read });
  assert.equal(result, "unchanged");
  assert.equal(auth.calls.set.length, 0);
  assert.equal(read.reads(), 1);
});

test("J: missing Auth user is skipped without writing", async () => {
  const auth = fakeAuth(undefined, { missing: true });
  const result = await syncUserClaims({ auth, uid: "ghost", readUserData: docSequence(activeGuidance) });
  assert.equal(result, "no-auth-user");
  assert.equal(auth.calls.set.length, 0);
});

test("K: STALE EVENT cannot re-grant: the function takes no event data and acts on the live doc", async () => {
  // A stale event would have said "active"; the live document says inactive.
  // syncUserClaims has no event-data parameter at all -- it only sees what
  // readUserData returns, i.e. the CURRENT state.
  const auth = fakeAuth({ ...BOTH });
  const result = await syncUserClaims({ auth, uid: "u1", readUserData: docSequence(inactiveGuidance) });
  assert.equal(result, "updated");
  assert.equal(auth.claims, undefined);
});

test("K: a document that CHANGES between the read and the write is corrected by the post-write re-read", async () => {
  // Pass 1 reads "active" (stale by the time we write); pass 2 re-reads the
  // now-inactive doc and revokes -> final state matches the current doc.
  const auth = fakeAuth(undefined);
  const read = docSequence(activeGuidance, inactiveGuidance);
  const result = await syncUserClaims({ auth, uid: "u1", readUserData: read });
  assert.equal(result, "updated");
  assert.deepEqual(auth.calls.set.map((c) => c.claims), [BOTH, null]); // granted, then corrected
  assert.equal(auth.claims, undefined);
  // pass 1 read+grant, pass 2 read+revoke, pass 3 read -> verified unchanged.
  assert.equal(read.reads(), 3);
});

test("K: after a write it verifies once more against the live doc (2 reads, then stops)", async () => {
  const auth = fakeAuth(undefined);
  const read = docSequence(activeGuidance); // doc stays active
  await syncUserClaims({ auth, uid: "u1", readUserData: read });
  assert.equal(read.reads(), 2);
  assert.equal(auth.calls.set.length, 1); // idempotent: no second write
});

test("K: a document that never stabilizes fails loudly instead of looping forever", async () => {
  const auth = fakeAuth(undefined);
  let flip = false;
  const flapping = async () => ((flip = !flip) ? activeGuidance : inactiveGuidance);
  await assert.rejects(
    () => syncUserClaims({ auth, uid: "u1", readUserData: flapping }),
    /did not stabilize/
  );
  assert.equal(auth.calls.set.length, MAX_PASSES);
});

test("L: an error from setCustomUserClaims propagates (not swallowed)", async () => {
  const boom = new Error("auth backend unavailable");
  const auth = fakeAuth(undefined, { failSet: boom });
  await assert.rejects(
    () => syncUserClaims({ auth, uid: "u1", readUserData: docSequence(activeGuidance) }),
    (e) => e === boom
  );
});

test("L: an error from reading the user document propagates", async () => {
  const boom = new Error("firestore unavailable");
  const auth = fakeAuth(undefined);
  await assert.rejects(
    () =>
      syncUserClaims({
        auth,
        uid: "u1",
        readUserData: async () => {
          throw boom;
        },
      }),
    (e) => e === boom
  );
  assert.equal(auth.calls.set.length, 0);
});

test("logger receives an info line on update and a warning for a missing Auth user", async () => {
  const lines = [];
  const logger = { info: (m) => lines.push(["info", m]), warn: (m) => lines.push(["warn", m]) };
  await syncUserClaims({ auth: fakeAuth(undefined), uid: "u1", readUserData: docSequence(activeGuidance), logger });
  await syncUserClaims({
    auth: fakeAuth(undefined, { missing: true }),
    uid: "u2",
    readUserData: docSequence(activeGuidance),
    logger,
  });
  assert.deepEqual(lines.map((l) => l[0]), ["info", "warn"]);
});

// ---------------------------------------------------------------------------
// M: readCurrentUserData (the current-state lookup helper)
// ---------------------------------------------------------------------------

function fakeDb(docs) {
  const reads = [];
  return {
    reads,
    doc(path) {
      return {
        async get() {
          reads.push(path);
          return docs[path] === undefined
            ? { exists: false, data: () => undefined }
            : { exists: true, data: () => docs[path] };
        },
      };
    },
  };
}

test("M: readCurrentUserData reads users/{uid} and returns its data", async () => {
  const db = fakeDb({ "users/u1": activeGuidance });
  assert.deepEqual(await readCurrentUserData(db, "u1"), activeGuidance);
  assert.deepEqual(db.reads, ["users/u1"]);
});

test("M: readCurrentUserData returns null for a missing/deleted document (never reads fields from it)", async () => {
  const db = fakeDb({});
  assert.equal(await readCurrentUserData(db, "gone"), null);
});

test("M: readCurrentUserData only needs a read (get) -- no Firestore write API is used", async () => {
  const db = { doc: () => ({ get: async () => ({ exists: false }) }) }; // no set/update/delete exist on it
  await assert.doesNotReject(() => readCurrentUserData(db, "u1"));
});
