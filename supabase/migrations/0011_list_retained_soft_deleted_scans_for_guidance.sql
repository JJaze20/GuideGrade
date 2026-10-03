-- Guidance Council READ RPC: lists retained (not-yet-expired) soft-deleted
-- UNLINKED scans, so the Guidance Web UI can display them and let a
-- Guidance Council user request restoration via the EXISTING
-- `create_scan_restore_request()` RPC from
-- 0009_create_unlinked_scan_soft_delete.sql.
--
-- This migration COMPLEMENTS 0009 and 0010 -- it does NOT replace, modify,
-- or depend on changing anything in either. Both are already applied to
-- the live database and are intentionally left completely untouched by
-- this file:
--   * 0009's five soft-delete columns on public.scans (deleted_at,
--     deleted_by_uid, deleted_by_name, deletion_reason, retention_until)
--     are only READ here, never written.
--   * 0009's `public.scan_restore_requests` table is only READ here (its
--     `status` column, to report whether an active request already
--     exists) -- no row in it is ever inserted, updated, or deleted by
--     this file.
--   * 0009's `trg_guard_scan_lifecycle` trigger and 0010's
--     `trg_guard_batch_delete_retained_scans` trigger are untouched; this
--     file creates no trigger at all.
--
-- Scope of THIS file: exactly one new SECURITY DEFINER function,
-- `public.list_retained_soft_deleted_scans_for_guidance()`. It is a
-- read-only listing RPC -- no INSERT/UPDATE/DELETE anywhere in its body,
-- on scans, scan_restore_requests, or any other table -- and it writes no
-- `guidance_activity` audit event (reads create no audit trail anywhere
-- else in this database either).
--
-- Deliberately excluded from the returned columns, same reasoning as
-- 0009's own `list_soft_deleted_unlinked_scans_for_admin()`: no `decoded`,
-- `raw_score`, `total_graded`, `total_items`, `score_percentage`,
-- `result_status`, `image_path`, `rectified_image_path`, or any other
-- image/answer-key data -- a deleted scan can be identified and acted on
-- without ever exposing what was on it.
--
-- NOT executed automatically -- apply by hand after review, exactly like
-- 0001-0010.

begin;

-- ---------------------------------------------------------------------------
-- 0. Prerequisite check -- refuse to run before 0009 (whose columns this
--    function reads) has been applied. Same pattern 0010 used to guard
--    against running before 0009.
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

  if to_regclass('public.scan_restore_requests') is null then
    raise exception
      'public.scan_restore_requests not found; run 0009_create_unlinked_scan_soft_delete.sql first';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- public.list_retained_soft_deleted_scans_for_guidance -- Guidance Council
-- only. Returns minimal identifying metadata for every UNLINKED scan that
-- is soft-deleted and still within its 30-day retention window, plus (as a
-- nullable convenience field, not a broadening of what the RPC exposes)
-- the status of that scan's own active restore request, if one exists --
-- so the UI can avoid offering a second request for a scan that already
-- has one PENDING or APPROVED. No requester/reviewer/timestamp metadata
-- from scan_restore_requests is exposed; direct table access to
-- scan_restore_requests remains revoked for every role (0009), unchanged
-- by this file.
-- ---------------------------------------------------------------------------
create or replace function public.list_retained_soft_deleted_scans_for_guidance()
returns table (
  batch_id text,
  scan_id text,
  exam_code text,
  deleted_at timestamptz,
  retention_until timestamptz,
  deletion_reason text,
  deleted_by_name text,
  active_restore_request_status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'guidance_council' then
    raise exception 'list_retained_soft_deleted_scans_for_guidance: caller is not an active Guidance Council user'
      using errcode = '42501';
  end if;

  return query
    select
      s.batch_id,
      s.id,
      s.exam_code,
      s.deleted_at,
      s.retention_until,
      s.deletion_reason,
      s.deleted_by_name,
      r.status
    from public.scans s
    left join public.scan_restore_requests r
      on r.batch_id = s.batch_id
     and r.scan_id = s.id
     and r.status in ('PENDING', 'APPROVED')
   where s.deleted_at is not null
     and s.retention_until is not null
     and s.retention_until > now()
     and s.examinee_id is null
   order by s.deleted_at desc;
end;
$$;

alter function public.list_retained_soft_deleted_scans_for_guidance()
  owner to postgres;
revoke all on function public.list_retained_soft_deleted_scans_for_guidance()
  from public, anon;
grant execute on function public.list_retained_soft_deleted_scans_for_guidance()
  to authenticated;

commit;
