-- Database-level protection for BATCH deletion: a batch cannot be deleted
-- while it still contains a soft-deleted scan whose 30-day retention window
-- has not expired.
--
-- This migration COMPLEMENTS 0009_create_unlinked_scan_soft_delete.sql --
-- it does NOT replace, modify, or depend on changing anything in it.
-- 0009 is already applied to the live database and is intentionally left
-- completely untouched by this file:
--   * 0009's `trg_guard_scan_lifecycle` (on public.scans) still governs
--     direct writes/deletes of individual scan rows, unchanged.
--   * 0009's five soft-delete columns (deleted_at, deleted_by_uid,
--     deleted_by_name, deletion_reason, retention_until) are only READ
--     here, never written.
--
-- Scope of THIS file: exactly one new trigger, on `public.batches`, that
-- inspects the batch's own scans before allowing the batch row itself to
-- be deleted. Nothing here touches Storage -- a Postgres trigger has no
-- mechanism to call the Storage API, and this migration does not attempt
-- to. Nothing here touches RLS, Storage policies, Firebase claims,
-- scheduled/automatic purge logic, or `guidance_activity` -- a blocked
-- batch deletion raises a plain SQL exception (SQLSTATE 42501) and writes
-- no audit event, exactly like 0009's own lifecycle-guard trigger does for
-- a blocked scan write.
--
-- IMPORTANT EDGE CASE, by design: the blocking condition below is
-- specifically `deleted_at IS NOT NULL AND retention_until > now()`.
-- 0010 blocks a batch ONLY while at least one of its soft-deleted scans
-- still has `retention_until > now()`. Once a soft-deleted scan is
-- EXPIRED (`retention_until <= now()`), 0010 does not block the batch.
--
-- Live rollback-only verification (post-apply, pre-commit, rolled back)
-- confirmed this end to end: a retained soft-deleted scan correctly
-- blocked batch deletion; an ordinary batch deleted normally; and a batch
-- whose only soft-deleted scan was already expired deleted successfully
-- -- the FK CASCADE from `batches` to `scans` completed, carrying that
-- expired scan row with it. Do NOT assume (as an earlier draft of this
-- comment incorrectly did) that 0009's `trg_guard_scan_lifecycle` rejects
-- that cascaded deletion of an expired scan -- it does not, confirmed by
-- this test.
--
-- Consequently: once a soft-deleted scan's retention window has expired,
-- the existing batch-deletion/cascade path can already permanently remove
-- it. This is strictly AFTER the protected 30-day retention period ends
-- and never shortens that period -- retention is never violated by this.
-- It is also not a substitute for a dedicated permanent-purge phase: a
-- FUTURE phase is still required for the full 30-day cleanup workflow,
-- including its pending-restore-request review guard, its own audit
-- events, and Storage cleanup independent of (and not currently triggered
-- by) batch deletion. This migration does not attempt to build that.
--
-- NOT executed automatically -- apply by hand after review, exactly like
-- 0001-0009.

begin;

-- ---------------------------------------------------------------------------
-- 0. Prerequisite check -- refuse to run before 0009 (whose columns this
--    trigger reads) has been applied.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'scans'
       and column_name  = 'deleted_at'
  ) then
    raise exception
      'public.scans.deleted_at not found; run 0009_create_unlinked_scan_soft_delete.sql first';
  end if;

  if not exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'scans'
       and column_name  = 'retention_until'
  ) then
    raise exception
      'public.scans.retention_until not found; run 0009_create_unlinked_scan_soft_delete.sql first';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- public.guard_batch_delete_retained_scans -- BEFORE DELETE trigger function
-- on public.batches. Deliberately NOT security definer and has NO
-- current_user bypass of any kind (unlike 0009's trg_guard_scan_lifecycle,
-- which trusts its own controlled SECURITY DEFINER RPCs) -- this guard is
-- meant to apply uniformly to every batch-deletion path with no carve-out,
-- per this migration's explicit requirement. It performs exactly one
-- read-only, row-locking existence check against public.scans for the
-- batch being deleted -- no INSERT/UPDATE/DELETE anywhere in this
-- function, on scans or any other table, and no Storage call (not
-- possible from a trigger function regardless).
-- ---------------------------------------------------------------------------
create or replace function public.guard_batch_delete_retained_scans()
returns trigger
language plpgsql
as $$
declare
  v_retained_scan_id text;
begin
  -- Existence-style check (not COUNT(*)): stop at the first matching row.
  -- FOR UPDATE locks that one scan row for the remainder of this
  -- transaction, so a concurrent soft-delete/restore lifecycle change for
  -- the SAME scan cannot race this batch-deletion decision -- it must wait
  -- for this transaction to finish, making the interaction deliberate
  -- rather than accidental.
  select s.id
    into v_retained_scan_id
    from public.scans s
   where s.batch_id = old.id
     and s.deleted_at is not null
     and s.retention_until > now()
   limit 1
     for update;

  if v_retained_scan_id is not null then
    raise exception
      'batch % cannot be deleted: it contains a soft-deleted scan still within its 30-day retention window',
      old.id
      using errcode = '42501';
  end if;

  return old;
end;
$$;

-- ---------------------------------------------------------------------------
-- Install the trigger. BEFORE DELETE on public.batches fires for ANY
-- DELETE against that table -- PostgREST/Flutter, the Supabase SQL
-- Editor, a future admin tool, or a direct psql session -- not just this
-- app's one Dart code path (SupabaseSyncClient.deleteBatch).
-- ---------------------------------------------------------------------------
drop trigger if exists trg_guard_batch_delete_retained_scans on public.batches;

create trigger trg_guard_batch_delete_retained_scans
  before delete on public.batches
  for each row
  execute function public.guard_batch_delete_retained_scans();

commit;
