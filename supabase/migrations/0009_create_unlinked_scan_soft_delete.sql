-- PHASE 1 (database foundation only) of the 30-day Unlinked Scan
-- soft-delete/restoration feature.
--
-- Scope of THIS file: schema + constraints + controlled RPCs + a protective
-- trigger + new audit actions, for UNLINKED scans only. Explicitly OUT OF
-- SCOPE here (left for later phases, by design):
--   * Any Flutter/UI change.
--   * Firebase custom claims (functions/claims.js) -- the RPCs below check
--     `auth.jwt() ->> 'user_role' = 'system_admin'`, but NOTHING in the
--     currently-deployed claims-sync mechanism ever sets that value (see
--     "KNOWN GAP" below). Wiring that claim up is a separate, later phase.
--   * Any scheduled/automatic cleanup job that purges an expired scan after
--     its 30-day retention window, or that sets action 'scan_permanently_purged'
--     (reserved below, used by nothing in this file).
--   * Any change to the existing `scans_select` / `scans_insert` /
--     `scans_update` / `scans_delete` RLS policies (not touched, not even
--     read, since their text is not tracked anywhere in this repo).
--   * Any Storage policy (a later security phase, after this foundation is
--     reviewed).
--
-- Builds only on 0001-0007's LIVE objects and the existing Firebase-via-
-- third-party-auth claims model (`auth.jwt() ->> 'user_role'`,
-- `auth.jwt() ->> 'sub'`) -- NOT on 0008, which is a separate, dormant,
-- not-yet-applied design for a future Supabase-Auth-native `public.users`
-- system. This migration is numbered 0009 purely for sequential ordering
-- and does not depend on 0008 in any way.
--
-- PREREQUISITE: run 0001-0007 first (this file's guidance_activity section
-- refuses to run unless 0007's 'batch_archived' action is already present).
--
-- NOT executed automatically -- apply by hand after review, exactly like
-- 0001-0008.
--
-- ===========================================================================
-- KNOWN GAP (read before relying on the System Admin RPCs below):
-- As of this migration, NOTHING sets `user_role = 'system_admin'` on any
-- issued JWT. The live claims-sync mechanism (functions/claims.js,
-- `qualifies()`) only ever grants `role`/`user_role` to an ACTIVE
-- `guidance_council` user; a System Admin's Firebase ID token carries
-- neither claim today and is treated as `anon` by Supabase (this is the
-- exact, intentional behavior documented in this repo's own comment at
-- 0004_create_examinee_from_scan_function.sql's EXECUTE-privilege note).
-- Consequently, `list_soft_deleted_unlinked_scans_for_admin()`,
-- `list_scan_restore_requests_for_admin()`, `review_scan_restore_request()`
-- and `restore_soft_deleted_scan()` are all correctly gated per this spec,
-- but are UNREACHABLE by any real System Admin session until a later phase
-- adds a `user_role = 'system_admin'` claim for active System Admin users
-- (the "Firebase claims" phase explicitly deferred above). This migration
-- intentionally proceeds anyway, on the assumption that phase is coming --
-- flagged here so it is never mistaken for an oversight.
-- ===========================================================================
--
-- ===========================================================================
-- FUTURE-PHASE REQUIREMENT -- NOT implemented in this file (documentation
-- only, per explicit instruction not to touch batch deletion/orphan cleanup
-- yet):
-- `public.scans.batch_id` has `references public.batches(id) on delete
-- cascade`, and `SupabaseSyncClient.deleteStoragePrefix` recursively removes
-- every Storage object under `batches/<batchId>/` with no awareness of scan
-- state. Neither is changed here. As things stand, deleting a batch (via the
-- mobile "Batch Management" screen, or via SyncManager's orphan-batch
-- cleanup) physically removes EVERY scans row in it -- including any
-- soft-deleted-but-still-within-retention row created by this migration's
-- `soft_delete_unlinked_scan()` -- and separately deletes its Storage
-- images, regardless of `retention_until`. A future phase MUST address this
-- (e.g. a guard against deleting a batch that still contains a
-- soft-deleted, not-yet-expired scan, and/or excluding such a scan's
-- objects from `deleteStoragePrefix`) before the 30-day retention guarantee
-- can be considered reliable end-to-end. Tracked here only as a documented
-- gap, not fixed.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Prerequisite check -- refuse to run before 0007 (same pattern 0007 used
--    to guard against running before 0006).
-- ---------------------------------------------------------------------------
do $$
declare
  def text;
begin
  select pg_get_constraintdef(oid)
    into def
    from pg_constraint
   where conrelid = 'public.guidance_activity'::regclass
     and conname  = 'guidance_activity_action_check'
     and contype  = 'c';

  if def is null then
    raise exception
      'guidance_activity_action_check not found on public.guidance_activity; refusing to continue';
  end if;

  if def not like '%batch_archived%' then
    raise exception
      'guidance_activity_action_check does not allow batch_archived; run 0006 and 0007 first';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- A. public.scans -- soft-delete metadata (UNLINKED scans only; nothing here
--    changes attempt_no / attempt_status / archive semantics, and a
--    soft-deleted scan keeps its batch_id/id, its examinee_id (always NULL,
--    enforced below), and every Storage object -- nothing here touches
--    Storage at all).
-- ---------------------------------------------------------------------------
alter table public.scans add column if not exists deleted_at timestamptz;
alter table public.scans add column if not exists deleted_by_uid text;
alter table public.scans add column if not exists deleted_by_name text;
alter table public.scans add column if not exists deletion_reason text;
alter table public.scans add column if not exists retention_until timestamptz;

-- Either every soft-delete column is NULL, or the complete required set is
-- populated. `deleted_by_name` is intentionally NOT required to be
-- nonblank in the "deleted" branch (the actor may have no recorded display
-- name) -- only `deleted_by_uid`, `deletion_reason` and `retention_until`
-- are mandatory once `deleted_at` is set, per this phase's spec.
alter table public.scans
  add constraint scans_soft_delete_metadata_check
  check (
    (
      deleted_at is null
      and deleted_by_uid is null
      and deleted_by_name is null
      and deletion_reason is null
      and retention_until is null
    )
    or
    (
      deleted_at is not null
      and deleted_by_uid is not null and length(trim(deleted_by_uid)) > 0
      and deletion_reason is not null and length(trim(deletion_reason)) > 0
      and retention_until is not null
    )
  );

-- A soft-deleted scan is always unlinked. This is also enforced procedurally
-- by soft_delete_unlinked_scan() (which refuses a linked scan) and by
-- restore_soft_deleted_scan() (which never re-links), but is additionally
-- guaranteed here at the schema level so no future code path can ever leave
-- a soft-deleted scan with a non-null examinee_id.
alter table public.scans
  add constraint scans_soft_delete_unlinked_check
  check (deleted_at is null or examinee_id is null);

-- Serves future retention-expiry lookups (a later scheduled-cleanup phase
-- finding "retention_until < now()") -- partial, since the overwhelming
-- majority of rows have deleted_at null and would never match anyway.
create index if not exists scans_retention_until_idx
  on public.scans (retention_until)
  where deleted_at is not null;

-- ---------------------------------------------------------------------------
-- B. public.scan_restore_requests -- deliberately NO foreign key to
--    public.scans (batch_id/scan_id are plain text, unvalidated by a FK), so
--    a request's history row survives even after its scan is eventually
--    purged in a future phase. No direct table grants are given to anyone
--    (see policy/grant block below) -- every read and write goes through
--    the SECURITY DEFINER RPCs in this file, consistent with K's
--    instruction not to grant System Admin direct table access.
-- ---------------------------------------------------------------------------
create table if not exists public.scan_restore_requests (
  id uuid primary key default gen_random_uuid(),
  batch_id text not null check (length(trim(batch_id)) > 0),
  scan_id text not null check (length(trim(scan_id)) > 0),
  exam_code text not null check (length(trim(exam_code)) > 0),
  reason text not null check (length(trim(reason)) > 0),
  status text not null default 'PENDING'
    check (status in ('PENDING', 'APPROVED', 'REJECTED', 'RESTORED', 'PURGED')),
  requested_by_uid text not null check (length(trim(requested_by_uid)) > 0),
  requested_by_name text,
  requested_at timestamptz not null default now(),
  reviewed_by_uid text,
  reviewed_by_name text,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint scan_restore_requests_reviewed_by_uid_nonblank
    check (reviewed_by_uid is null or length(trim(reviewed_by_uid)) > 0),
  constraint scan_restore_requests_review_note_nonblank
    check (review_note is null or length(trim(review_note)) > 0)
);

alter table public.scan_restore_requests enable row level security;

-- No policy is created at all (default-deny for every role under RLS), and
-- table-level grants are reset to nothing for anon/authenticated -- the
-- owner (postgres, via the SECURITY DEFINER functions below) bypasses RLS
-- as table owner and does not need a grant. Nobody else can read or write
-- this table directly, by design.
revoke all on table public.scan_restore_requests
  from public, anon, authenticated;

-- batch_id + scan_id lookups (history for one scan).
create index if not exists scan_restore_requests_batch_scan_idx
  on public.scan_restore_requests (batch_id, scan_id);

-- status-based listing (the admin "requests" screen's natural filter).
create index if not exists scan_restore_requests_status_idx
  on public.scan_restore_requests (status);

-- Exactly one PENDING or APPROVED request may exist per scan at a time --
-- also the natural index for "does an active request already exist".
create unique index if not exists scan_restore_requests_active_unique
  on public.scan_restore_requests (batch_id, scan_id)
  where status in ('PENDING', 'APPROVED');

-- Chronological listing / retention-adjacent bookkeeping for the request
-- records themselves (distinct from scans_retention_until_idx above, which
-- is about the SCAN's own retention clock).
create index if not exists scan_restore_requests_requested_at_idx
  on public.scan_restore_requests (requested_at);

-- ---------------------------------------------------------------------------
-- Internal audit helper -- NOT the retake-specific write_retake_audit()
-- (left untouched, per instruction). SECURITY DEFINER so it can insert into
-- guidance_activity regardless of the calling role's own grants; never
-- exposed to anon/authenticated/public directly -- only ever called from
-- inside the SECURITY DEFINER functions below, which already run as this
-- function's owner (postgres).
-- ---------------------------------------------------------------------------
create or replace function public.write_scan_lifecycle_audit(
  p_action text,
  p_batch_id text,
  p_scan_id text,
  p_actor_uid text,
  p_actor_name text,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_exam_code text;
begin
  -- Best-effort only: for every action in this phase the scan row still
  -- exists (soft delete/restore/review never remove it); exam_code is left
  -- NULL if a future action somehow runs after the row is gone rather than
  -- failing the whole audit write over a missing label.
  select s.exam_code into v_exam_code
    from public.scans s
   where s.batch_id = p_batch_id and s.id = p_scan_id;

  insert into public.guidance_activity (
    actor_uid,
    actor_name,
    action,
    entity_type,
    entity_id,
    batch_id,
    exam_code,
    reason
  )
  values (
    coalesce(nullif(trim(p_actor_uid), ''), 'system'),
    nullif(trim(p_actor_name), ''),
    p_action,
    'scan',
    p_scan_id,
    p_batch_id,
    v_exam_code,
    nullif(trim(p_reason), '')
  );
end;
$$;

alter function public.write_scan_lifecycle_audit(text, text, text, text, text, text)
  owner to postgres;
revoke all on function public.write_scan_lifecycle_audit(text, text, text, text, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- C. soft_delete_unlinked_scan -- Guidance Council only. Soft-deletes ONE
--    scan: must exist, must be unlinked, must not be an archived attempt,
--    must not already be soft-deleted. Never touches Storage.
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_unlinked_scan(
  p_batch_id text,
  p_scan_id text,
  p_deleted_by_uid text,
  p_deleted_by_name text,
  p_deletion_reason text
)
returns table (
  batch_id text,
  scan_id text,
  deleted_at timestamptz,
  retention_until timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_examinee_id      uuid;
  v_attempt_status   text;
  v_current_deleted  timestamptz;
  v_uid              text;
  v_name             text;
  v_reason           text;
  v_deleted_at       timestamptz;
  v_retention_until  timestamptz;
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'guidance_council' then
    raise exception 'soft_delete_unlinked_scan: caller is not an active Guidance Council user'
      using errcode = '42501';
  end if;

  v_uid := nullif(trim(p_deleted_by_uid), '');
  if v_uid is null then
    raise exception 'soft_delete_unlinked_scan: p_deleted_by_uid is required'
      using errcode = '22023';
  end if;

  if v_uid is distinct from (auth.jwt() ->> 'sub') then
    raise exception 'soft_delete_unlinked_scan: p_deleted_by_uid does not match the authenticated caller'
      using errcode = '42501';
  end if;

  v_reason := nullif(trim(p_deletion_reason), '');
  if v_reason is null then
    raise exception 'soft_delete_unlinked_scan: p_deletion_reason is required'
      using errcode = '22023';
  end if;

  v_name := nullif(trim(p_deleted_by_name), '');

  -- Lock the target row before inspecting or changing it, so a concurrent
  -- link/unlink/archive/soft-delete call for the same scan serializes here.
  select s.examinee_id, s.attempt_status, s.deleted_at
    into v_examinee_id, v_attempt_status, v_current_deleted
    from public.scans s
   where s.batch_id = p_batch_id and s.id = p_scan_id
     for update;

  if not found then
    raise exception 'soft_delete_unlinked_scan: scan % in batch % does not exist',
      p_scan_id, p_batch_id
      using errcode = 'P0002';
  end if;

  if v_examinee_id is not null then
    raise exception 'soft_delete_unlinked_scan: scan % in batch % is linked to an examinee and is not eligible',
      p_scan_id, p_batch_id
      using errcode = '42501';
  end if;

  if v_attempt_status is not null and upper(v_attempt_status) = 'ARCHIVED' then
    raise exception 'soft_delete_unlinked_scan: scan % in batch % is an archived historical attempt and is not eligible',
      p_scan_id, p_batch_id
      using errcode = '42501';
  end if;

  if v_current_deleted is not null then
    raise exception 'soft_delete_unlinked_scan: scan % in batch % is already soft-deleted',
      p_scan_id, p_batch_id
      using errcode = '42501';
  end if;

  v_deleted_at := now();
  v_retention_until := v_deleted_at + interval '30 days';

  -- No bypass flag needed here: this function is SECURITY DEFINER, owned by
  -- postgres, so this UPDATE (and the trg_guard_scan_lifecycle trigger it
  -- fires) executes as `postgres` automatically. The trigger recognizes
  -- that trusted execution context via `current_user = 'postgres'`.
  update public.scans as s
     set deleted_at = v_deleted_at,
         deleted_by_uid = v_uid,
         deleted_by_name = v_name,
         deletion_reason = v_reason,
         retention_until = v_retention_until
   where s.batch_id = p_batch_id and s.id = p_scan_id;

  perform public.write_scan_lifecycle_audit(
    'scan_soft_deleted', p_batch_id, p_scan_id, v_uid, v_name, v_reason
  );

  return query select p_batch_id, p_scan_id, v_deleted_at, v_retention_until;
end;
$$;

alter function public.soft_delete_unlinked_scan(text, text, text, text, text)
  owner to postgres;
revoke all on function public.soft_delete_unlinked_scan(text, text, text, text, text)
  from public, anon;
grant execute on function public.soft_delete_unlinked_scan(text, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- D. create_scan_restore_request -- Guidance Council only. Queues a request
--    to restore a soft-deleted, still-unlinked scan.
-- ---------------------------------------------------------------------------
create or replace function public.create_scan_restore_request(
  p_batch_id text,
  p_scan_id text,
  p_reason text,
  p_requested_by_uid text,
  p_requested_by_name text
)
returns table (
  request_id uuid,
  status text,
  requested_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted_at       timestamptz;
  v_examinee_id      uuid;
  v_exam_code        text;
  v_retention_until  timestamptz;
  v_uid              text;
  v_name             text;
  v_reason           text;
  v_has_active       boolean;
  v_request_id       uuid;
  v_requested_at     timestamptz;
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'guidance_council' then
    raise exception 'create_scan_restore_request: caller is not an active Guidance Council user'
      using errcode = '42501';
  end if;

  v_uid := nullif(trim(p_requested_by_uid), '');
  if v_uid is null then
    raise exception 'create_scan_restore_request: p_requested_by_uid is required'
      using errcode = '22023';
  end if;

  if v_uid is distinct from (auth.jwt() ->> 'sub') then
    raise exception 'create_scan_restore_request: p_requested_by_uid does not match the authenticated caller'
      using errcode = '42501';
  end if;

  v_reason := nullif(trim(p_reason), '');
  if v_reason is null then
    raise exception 'create_scan_restore_request: p_reason is required'
      using errcode = '22023';
  end if;

  v_name := nullif(trim(p_requested_by_name), '');

  select s.deleted_at, s.examinee_id, s.exam_code, s.retention_until
    into v_deleted_at, v_examinee_id, v_exam_code, v_retention_until
    from public.scans s
   where s.batch_id = p_batch_id and s.id = p_scan_id
     for update;

  if not found then
    raise exception 'create_scan_restore_request: scan % in batch % does not exist',
      p_scan_id, p_batch_id
      using errcode = 'P0002';
  end if;

  if v_deleted_at is null then
    raise exception 'create_scan_restore_request: scan % in batch % is not currently soft-deleted',
      p_scan_id, p_batch_id
      using errcode = '42501';
  end if;

  -- Guaranteed by scans_soft_delete_unlinked_check already, re-checked here
  -- so this function is safe standing on its own.
  if v_examinee_id is not null then
    raise exception 'create_scan_restore_request: scan % in batch % is linked to an examinee',
      p_scan_id, p_batch_id
      using errcode = '42501';
  end if;

  -- Lock any existing active request row(s) for this scan too, so two
  -- concurrent calls cannot both pass this check (the unique partial index
  -- above is the final backstop regardless).
  select exists (
    select 1 from public.scan_restore_requests r
     where r.batch_id = p_batch_id and r.scan_id = p_scan_id
       and r.status in ('PENDING', 'APPROVED')
     for update
  ) into v_has_active;

  if v_has_active then
    raise exception 'create_scan_restore_request: an active restore request already exists for scan % in batch %',
      p_scan_id, p_batch_id
      using errcode = '23505';
  end if;

  -- Retention check, simplified: `v_has_active` is already proven false at
  -- this point (the check above would have aborted otherwise), and
  -- scans_soft_delete_metadata_check already guarantees retention_until is
  -- not null whenever deleted_at is not null (already confirmed above) --
  -- so the only real condition is whether the window has actually expired.
  -- No artificial extension of retention is applied here.
  if v_retention_until <= now() then
    raise exception 'create_scan_restore_request: scan % in batch % is past its retention window',
      p_scan_id, p_batch_id
      using errcode = '42501';
  end if;

  insert into public.scan_restore_requests as r (
    batch_id, scan_id, exam_code, reason, status,
    requested_by_uid, requested_by_name
  )
  values (
    p_batch_id, p_scan_id, v_exam_code, v_reason, 'PENDING',
    v_uid, v_name
  )
  returning r.id, r.requested_at into v_request_id, v_requested_at;

  perform public.write_scan_lifecycle_audit(
    'scan_restore_requested', p_batch_id, p_scan_id, v_uid, v_name, v_reason
  );

  return query select v_request_id, 'PENDING'::text, v_requested_at;
end;
$$;

alter function public.create_scan_restore_request(text, text, text, text, text)
  owner to postgres;
revoke all on function public.create_scan_restore_request(text, text, text, text, text)
  from public, anon;
grant execute on function public.create_scan_restore_request(text, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- E. System Admin READ-ONLY RPCs. Both deliberately select only minimum
--    restore-management metadata -- never decoded answers, scores, result
--    fields, or any image path (original/rectified or otherwise).
-- ---------------------------------------------------------------------------
create or replace function public.list_soft_deleted_unlinked_scans_for_admin()
returns table (
  batch_id text,
  scan_id text,
  exam_code text,
  deleted_at timestamptz,
  retention_until timestamptz,
  deletion_reason text,
  deleted_by_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'system_admin' then
    raise exception 'list_soft_deleted_unlinked_scans_for_admin: caller is not a System Administrator'
      using errcode = '42501';
  end if;

  return query
    select s.batch_id, s.id, s.exam_code, s.deleted_at, s.retention_until,
           s.deletion_reason, s.deleted_by_name
      from public.scans s
     where s.deleted_at is not null
     order by s.deleted_at desc;
end;
$$;

alter function public.list_soft_deleted_unlinked_scans_for_admin()
  owner to postgres;
revoke all on function public.list_soft_deleted_unlinked_scans_for_admin()
  from public, anon;
grant execute on function public.list_soft_deleted_unlinked_scans_for_admin()
  to authenticated;

create or replace function public.list_scan_restore_requests_for_admin()
returns table (
  request_id uuid,
  batch_id text,
  scan_id text,
  exam_code text,
  status text,
  reason text,
  requested_by_name text,
  requested_at timestamptz,
  reviewed_by_name text,
  reviewed_at timestamptz,
  review_note text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'system_admin' then
    raise exception 'list_scan_restore_requests_for_admin: caller is not a System Administrator'
      using errcode = '42501';
  end if;

  return query
    select r.id, r.batch_id, r.scan_id, r.exam_code, r.status, r.reason,
           r.requested_by_name, r.requested_at,
           r.reviewed_by_name, r.reviewed_at, r.review_note
      from public.scan_restore_requests r
     order by r.requested_at desc;
end;
$$;

alter function public.list_scan_restore_requests_for_admin()
  owner to postgres;
revoke all on function public.list_scan_restore_requests_for_admin()
  from public, anon;
grant execute on function public.list_scan_restore_requests_for_admin()
  to authenticated;

-- ---------------------------------------------------------------------------
-- F. review_scan_restore_request -- System Admin only. APPROVE/REJECT a
--    PENDING request. Review is kept SEPARATE from restoration: G
--    (restore_soft_deleted_scan) requires status = 'APPROVED' as its own
--    precondition, which only makes sense as an independently reachable,
--    stable state -- so an atomic "approve = restore" design (the preferred
--    option per this phase's instructions, when safely possible) would
--    make G's own stated precondition unreachable. The two-step design is
--    therefore the one implemented here; see this file's report for the
--    same reasoning.
-- ---------------------------------------------------------------------------
create or replace function public.review_scan_restore_request(
  p_request_id uuid,
  p_action text,
  p_reviewer_uid text,
  p_reviewer_name text,
  p_review_note text
)
returns table (
  request_id uuid,
  status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_batch_id         text;
  v_scan_id          text;
  v_status           text;
  v_scan_deleted     timestamptz;
  v_retention_until  timestamptz;
  v_action           text;
  v_uid              text;
  v_name             text;
  v_note             text;
  v_new_status       text;
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'system_admin' then
    raise exception 'review_scan_restore_request: caller is not a System Administrator'
      using errcode = '42501';
  end if;

  v_uid := nullif(trim(p_reviewer_uid), '');
  if v_uid is null then
    raise exception 'review_scan_restore_request: p_reviewer_uid is required'
      using errcode = '22023';
  end if;

  if v_uid is distinct from (auth.jwt() ->> 'sub') then
    raise exception 'review_scan_restore_request: p_reviewer_uid does not match the authenticated caller'
      using errcode = '42501';
  end if;

  v_action := upper(coalesce(p_action, ''));
  if v_action not in ('APPROVE', 'REJECT') then
    raise exception 'review_scan_restore_request: p_action must be APPROVE or REJECT, got %',
      p_action
      using errcode = '22023';
  end if;

  v_name := nullif(trim(p_reviewer_name), '');
  v_note := nullif(trim(p_review_note), '');

  select r.batch_id, r.scan_id, r.status
    into v_batch_id, v_scan_id, v_status
    from public.scan_restore_requests r
   where r.id = p_request_id
     for update;

  if not found then
    raise exception 'review_scan_restore_request: request % does not exist', p_request_id
      using errcode = 'P0002';
  end if;

  if v_status <> 'PENDING' then
    raise exception 'review_scan_restore_request: request % is % and is no longer reviewable',
      p_request_id, v_status
      using errcode = '42501';
  end if;

  -- Lock the associated scan too, so a concurrent restore/purge cannot race
  -- this review. A missing scan means it was already permanently purged
  -- (a future phase's concern) -- reported distinctly, never silently
  -- approved/rejected as though the scan were still there.
  select s.deleted_at, s.retention_until
    into v_scan_deleted, v_retention_until
    from public.scans s
   where s.batch_id = v_batch_id and s.id = v_scan_id
     for update;

  if not found then
    raise exception 'review_scan_restore_request: the scan behind request % no longer exists (permanently purged)',
      p_request_id
      using errcode = '42501';
  end if;

  if v_scan_deleted is null then
    -- Not reachable in this phase (nothing un-soft-deletes a scan except
    -- restore_soft_deleted_scan, which itself sets this request to
    -- RESTORED, not back to PENDING) -- guarded anyway rather than assumed.
    raise exception 'review_scan_restore_request: the scan behind request % is not currently soft-deleted',
      p_request_id
      using errcode = '42501';
  end if;

  -- Retention is enforced on APPROVE only -- REJECT never restores data, so
  -- it may always proceed for a valid PENDING request regardless of
  -- whether the window has since expired.
  if v_action = 'APPROVE' and v_retention_until <= now() then
    raise exception 'review_scan_restore_request: the restoration window for request % has expired',
      p_request_id
      using errcode = '42501';
  end if;

  v_new_status := case v_action when 'APPROVE' then 'APPROVED' else 'REJECTED' end;

  update public.scan_restore_requests
     set status = v_new_status,
         reviewed_by_uid = v_uid,
         reviewed_by_name = v_name,
         reviewed_at = now(),
         review_note = v_note,
         updated_at = now()
   where id = p_request_id;

  perform public.write_scan_lifecycle_audit(
    case v_action when 'APPROVE' then 'scan_restore_approved' else 'scan_restore_rejected' end,
    v_batch_id, v_scan_id, v_uid, v_name, v_note
  );

  return query select p_request_id, v_new_status;
end;
$$;

alter function public.review_scan_restore_request(uuid, text, text, text, text)
  owner to postgres;
revoke all on function public.review_scan_restore_request(uuid, text, text, text, text)
  from public, anon;
grant execute on function public.review_scan_restore_request(uuid, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- G. restore_soft_deleted_scan -- System Admin only. Requires an APPROVED
--    request. Clears soft-delete metadata ONLY -- never touches scan id,
--    batch_id, captured_at, OCR/result data, attempt_no, or attempt_status.
-- ---------------------------------------------------------------------------
create or replace function public.restore_soft_deleted_scan(
  p_request_id uuid,
  p_reviewer_uid text,
  p_reviewer_name text
)
returns table (
  batch_id text,
  scan_id text,
  restored_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_batch_id         text;
  v_scan_id          text;
  v_status           text;
  v_deleted_at       timestamptz;
  v_retention_until  timestamptz;
  v_examinee_id      uuid;
  v_uid              text;
  v_name             text;
  v_restored_at      timestamptz;
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'system_admin' then
    raise exception 'restore_soft_deleted_scan: caller is not a System Administrator'
      using errcode = '42501';
  end if;

  v_uid := nullif(trim(p_reviewer_uid), '');
  if v_uid is null then
    raise exception 'restore_soft_deleted_scan: p_reviewer_uid is required'
      using errcode = '22023';
  end if;

  if v_uid is distinct from (auth.jwt() ->> 'sub') then
    raise exception 'restore_soft_deleted_scan: p_reviewer_uid does not match the authenticated caller'
      using errcode = '42501';
  end if;

  v_name := nullif(trim(p_reviewer_name), '');

  select r.batch_id, r.scan_id, r.status
    into v_batch_id, v_scan_id, v_status
    from public.scan_restore_requests r
   where r.id = p_request_id
     for update;

  if not found then
    raise exception 'restore_soft_deleted_scan: request % does not exist', p_request_id
      using errcode = 'P0002';
  end if;

  if v_status <> 'APPROVED' then
    raise exception 'restore_soft_deleted_scan: request % is % and is not approved for restoration',
      p_request_id, v_status
      using errcode = '42501';
  end if;

  select s.deleted_at, s.examinee_id, s.retention_until
    into v_deleted_at, v_examinee_id, v_retention_until
    from public.scans s
   where s.batch_id = v_batch_id and s.id = v_scan_id
     for update;

  if not found then
    raise exception 'restore_soft_deleted_scan: the scan behind request % no longer exists (permanently purged)',
      p_request_id
      using errcode = '42501';
  end if;

  if v_deleted_at is null then
    raise exception 'restore_soft_deleted_scan: the scan behind request % is not currently soft-deleted',
      p_request_id
      using errcode = '42501';
  end if;

  -- Guaranteed by scans_soft_delete_unlinked_check already, re-checked here
  -- so this function is safe standing on its own.
  if v_examinee_id is not null then
    raise exception 'restore_soft_deleted_scan: the scan behind request % is linked to an examinee',
      p_request_id
      using errcode = '42501';
  end if;

  -- Final retention gate, re-checked at the moment of restoration (not just
  -- at review time) -- an expired scan must never be restored even if it
  -- was approved before expiry.
  if v_retention_until <= now() then
    raise exception 'restore_soft_deleted_scan: the restoration window for request % has expired',
      p_request_id
      using errcode = '42501';
  end if;

  v_restored_at := now();

  -- No bypass flag needed here either, for the same reason as
  -- soft_delete_unlinked_scan: this function already runs as `postgres`.
  update public.scans as s
     set deleted_at = null,
         deleted_by_uid = null,
         deleted_by_name = null,
         deletion_reason = null,
         retention_until = null,
         updated_at = v_restored_at
   where s.batch_id = v_batch_id and s.id = v_scan_id;

  update public.scan_restore_requests
     set status = 'RESTORED',
         updated_at = v_restored_at
   where id = p_request_id;

  perform public.write_scan_lifecycle_audit(
    'scan_restored', v_batch_id, v_scan_id, v_uid, v_name, null
  );

  return query select v_batch_id, v_scan_id, v_restored_at;
end;
$$;

alter function public.restore_soft_deleted_scan(uuid, text, text)
  owner to postgres;
revoke all on function public.restore_soft_deleted_scan(uuid, text, text)
  from public, anon;
grant execute on function public.restore_soft_deleted_scan(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- I. Protective trigger -- blocks ordinary application/client writes
--    (pushScan, patchImageStatus, linkScanToExaminee,
--    unlinkScanFromExaminee, the existing deleteUnlinkedScan/deleteScan
--    DELETEs, or a direct Supabase REST INSERT) from touching a
--    soft-deleted scan or its soft-delete metadata, UNLESS the write is
--    executed by one of the controlled SECURITY DEFINER RPCs above (C, G),
--    which are owned by `postgres`. Trusted, privileged PostgreSQL
--    execution context (the `postgres` role itself -- including, for
--    example, a Supabase SQL Editor session connected as `postgres`) is
--    intentionally allowed through by the same `current_user = 'postgres'`
--    check; this trigger governs ordinary application-level access, not
--    administrative database access.
--
--    Trust boundary: `current_user = 'postgres'`. This mirrors the already-
--    existing, already-trusted pattern used by
--    `prevent_direct_attempt_field_change()` elsewhere in this database --
--    NOT a client-settable GUC or any other client-controlled flag.
--    `current_user` reflects the actual authenticated Postgres role for the
--    current execution context, controlled exclusively by Postgres's own
--    role/connection system and by SECURITY DEFINER semantics; an
--    `authenticated`/`anon` PostgREST session has no SQL-level way to make
--    `current_user` evaluate to `postgres` (that would require `SET ROLE
--    postgres`, a privilege `authenticated` does not have). Because
--    soft_delete_unlinked_scan() and restore_soft_deleted_scan() are both
--    `security definer` + `owner to postgres`, their UPDATEs on `scans`
--    (and the trigger that fires from them) automatically execute as
--    `postgres` -- no bypass flag of any kind is needed or used.
--
--    Scope: BEFORE INSERT OR UPDATE OR DELETE.
--      * INSERT: outside the `postgres` trust boundary, rejects any INSERT
--        that arrives with a non-null soft-delete column -- normal scan
--        creation (pushScan's upsert) never sends these columns, so this
--        only fires on a deliberate attempt to create an already-
--        soft-deleted row (e.g. a direct Supabase REST POST to
--        /rest/v1/scans supplying them).
--      * UPDATE, not currently soft-deleted (old.deleted_at is null): every
--        column OTHER than the 5 soft-delete columns remains completely
--        free to update, exactly as before this migration -- pushScan, the
--        retake workflow's attempt_status flip, linkScanToExaminee,
--        unlinkScanFromExaminee and patchImageStatus are all unaffected.
--        The retake workflow only ever touches a LINKED examinee's scan
--        history, and a soft-deleted scan is always unlinked
--        (scans_soft_delete_unlinked_check) -- the two paths can never
--        collide.
--      * UPDATE, already soft-deleted (old.deleted_at is not null): blocks
--        EVERY further UPDATE outside the `postgres` trust boundary -- this
--        intentionally also blocks the EXISTING deleteUnlinkedScan RPC and
--        linkScanToExaminee from acting on an already-soft-deleted row
--        (both would otherwise still structurally match it, since it is
--        unlinked by definition); this is the explicit point of this
--        trigger, not an unintended interaction.
--      * DELETE: continues to block only a direct DELETE of an
--        already-soft-deleted row outside the `postgres` trust boundary --
--        unrelated deletion behavior (deleteUnlinkedScan/deleteScan on a
--        NOT-soft-deleted row) is entirely unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.guard_scan_lifecycle_write()
returns trigger
language plpgsql
as $$
begin
  if current_user = 'postgres' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.deleted_at is not null
       or new.deleted_by_uid is not null
       or new.deleted_by_name is not null
       or new.deletion_reason is not null
       or new.retention_until is not null then
      raise exception 'scan % in batch % cannot be created already soft-deleted',
        new.id, new.batch_id
        using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.deleted_at is not null then
      raise exception 'scan % in batch % is soft-deleted and cannot be deleted directly',
        old.id, old.batch_id
        using errcode = '42501';
    end if;
    return old;
  end if;

  -- tg_op = 'UPDATE'
  if old.deleted_at is not null then
    if new is distinct from old then
      raise exception 'scan % in batch % is soft-deleted and cannot be modified directly',
        old.id, old.batch_id
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.deleted_at is not null
     or new.deleted_by_uid is not null
     or new.deleted_by_name is not null
     or new.deletion_reason is not null
     or new.retention_until is not null then
    raise exception 'scan % in batch % soft-delete metadata can only be set by soft_delete_unlinked_scan()',
      old.id, old.batch_id
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_scan_lifecycle on public.scans;

create trigger trg_guard_scan_lifecycle
  before insert or update or delete on public.scans
  for each row
  execute function public.guard_scan_lifecycle_write();

-- ---------------------------------------------------------------------------
-- H. Audit vocabulary -- extend guidance_activity's action CHECK with the
--    6 new lifecycle actions, preserving every existing action (0001-0007's
--    full list). 'scan_permanently_purged' is reserved here for a future
--    scheduled-cleanup phase; nothing in this file ever writes it. 'hard' is
--    left untouched everywhere (its column default), never repurposed as an
--    undocumented flag for this workflow.
-- ---------------------------------------------------------------------------
alter table public.guidance_activity
  drop constraint guidance_activity_action_check;

alter table public.guidance_activity
  add constraint guidance_activity_action_check
  check (action in (
    'batch_deleted',
    'scan_deleted',
    'image_deleted',
    'examinee_set',
    'examinee_edited',
    'examinee_cleared',
    'result_edited',
    'scan_rescanned',
    'batch_completed',
    'dup_override',
    'examinee_unlinked',
    'batch_archived',
    'retake_requested',
    'retake_approved',
    'retake_rejected',
    'attempt_archived',
    'retake_linked',
    'scan_soft_deleted',
    'scan_restore_requested',
    'scan_restore_approved',
    'scan_restore_rejected',
    'scan_restored',
    'scan_permanently_purged'
  ));

commit;
