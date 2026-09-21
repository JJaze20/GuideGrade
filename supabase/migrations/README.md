# Supabase migrations

This repo has no migration runner wired up (no `supabase` CLI project here,
no CI step that applies these). The files in this folder are the schema
changes required by the Examinee Records feature (`lib/models/examinee_record.dart`
and `lib/features/guidance_web/...examinee_records...`) — apply them by hand,
in order, against the live Supabase project (SQL editor, or
`supabase db push` if you set up the CLI locally) before deploying that
feature:

1. `0001_create_examinees.sql` — the canonical `examinees` table, its
   immutable-`temporary_examinee_id` trigger, and Guidance-Council-only RLS.
2. `0002_add_examinee_id_to_scans.sql` — the nullable `scans.examinee_id`
   foreign key.
3. `0003_migrate_legacy_scans_to_examinees.sql` — the one-time, idempotent,
   conservative backfill described in Part 7 of the spec (one examinee per
   distinct nonblank legacy `examinee_number`, never merged by name). A
   one-time historical exception — never repurposed into an ongoing/automatic
   mechanism (no trigger is proposed anywhere in this folder).
4. `0004_create_examinee_from_scan_function.sql` — the `create_examinee_from_scan`
   RPC backing the Web Console's "Create Examinee Record from this Scan"
   action, so the new `examinees` row and the triggering scan's `examinee_id`
   are written in one transaction instead of two separate client calls.

5. `0005_prevent_duplicate_exam_type_per_examinee.sql` — partial unique index
   so one examinee has at most one scan per exam type. Run the duplicate
   check in its header first.
6. `0006_audit_examinee_unlink.sql` — `guidance_activity` audit event
   (`examinee_unlinked`) for Remove Link, via a narrow trigger on
   `scans.examinee_id`.
7. `0007_create_batch_archives.sql` — the Guidance Council Web Archive marker
   table (`batch_archives`, `ON DELETE CASCADE` to `batches`), select/insert
   only (no restore), and the `batch_archived` audit event. **Run 0006
   first**, and never re-run 0006 afterwards (both replace the audit action
   CHECK with a full list).

0001–0005 and 0007's table never write `batches`, existing `scans` columns,
scores, decoded OMR JSON, or images; the Web Archive marker is separate from
`batches.status`, which belongs to the mobile app. The only database triggers
here are the two audit triggers (0006, 0007), which write `guidance_activity`
and nothing else — every `examinees` row a Guidance Council user creates
going forward still comes from an explicit, human-confirmed click in the Web
Console (see `guidance_web_examinee_records_view.dart`), never an automatic
background reconciliation.
