-- Atomic "Create Examinee Record from this Scan" (Workflow 1 of the
-- Examinee Records feature). A plain client-side INSERT-then-UPDATE pair
-- cannot guarantee atomicity (a crash/disconnect between the two calls
-- would leave a scanless examinee or a still-unlinked scan with no way to
-- undo the insert, since there is deliberately no DELETE policy on
-- examinees). This function does both in ONE Postgres transaction and
-- FAILS -- rolling back everything -- unless exactly one, previously
-- unlinked scan was linked.
--
-- NOT executed automatically -- same as 0001-0003, apply by hand after
-- review.
--
-- Atomicity: a PL/pgSQL function body always runs inside the caller's
-- single transaction (PostgREST wraps each /rpc/ call in one). When the
-- function raises an exception, PostgreSQL aborts that transaction and
-- undoes EVERY change made since it began -- including the examinees row
-- inserted earlier in this same function. There is no explicit
-- BEGIN/COMMIT/ROLLBACK here and none is needed (or allowed in a function).
--
-- Security: deliberately NOT `security definer`. It runs as the CALLING
-- user, so the INSERT into `examinees` still goes through
-- `examinees_insert_guidance` RLS exactly as a direct client insert would,
-- and the scan lock/UPDATE is still subject to whatever grants/RLS `scans`
-- has today (unchanged by this migration) -- this function grants no
-- privilege a direct two-call sequence wouldn't already have.
--
-- `scans.id` / `scans.batch_id` are `text` (matching the existing `scans`
-- schema the app already writes with plain string ids -- see
-- SupabaseSyncClient.pushScan), never `uuid`.
create or replace function public.create_examinee_from_scan(
  p_batch_id text,
  p_scan_id text,
  p_first_name text,
  p_middle_name text,
  p_last_name text
)
returns public.examinees
language plpgsql
as $$
declare
  v_examinee public.examinees;
  v_existing_examinee_id uuid;
  v_updated integer;
begin
  -- 1. Lock the target scan row and inspect it BEFORE creating anything, so
  --    concurrent calls for the same scan serialize here (the second one
  --    waits, then sees the scan already linked and fails).
  select examinee_id
    into v_existing_examinee_id
    from public.scans
   where batch_id = p_batch_id and id = p_scan_id
     for update;

  if not found then
    raise exception 'create_examinee_from_scan: scan % in batch % does not exist',
      p_scan_id, p_batch_id
      using errcode = 'P0002'; -- no_data_found
  end if;

  if v_existing_examinee_id is not null then
    raise exception 'create_examinee_from_scan: scan % in batch % is already linked to an examinee',
      p_scan_id, p_batch_id
      using errcode = '23505'; -- unique_violation-class: already linked
  end if;

  -- 2. Create the examinee (temporary_examinee_id comes from the column's
  --    sequence-backed DEFAULT -- never supplied here).
  insert into public.examinees (
    first_name, middle_name, last_name, status,
    created_by_uid, updated_by_uid
  )
  values (
    -- The actor is the Firebase UID, i.e. the JWT `sub` claim read as TEXT.
    -- Deliberately NOT auth.uid(): that returns a uuid, and Firebase UIDs are
    -- not UUIDs, so casting would raise 22P02. No uuid cast anywhere here.
    p_first_name, nullif(p_middle_name, ''), p_last_name, 'active',
    coalesce(auth.jwt() ->> 'sub', ''), coalesce(auth.jwt() ->> 'sub', '')
  )
  returning * into v_examinee;

  -- 3. Link the scan, guarded again by `examinee_id is null`, and require
  --    that EXACTLY one row changed. Any other count (0 = something
  --    changed it under us / RLS hid it; >1 = ambiguous scan key) aborts
  --    the whole transaction, discarding the examinee inserted in step 2.
  update public.scans
     set examinee_id = v_examinee.id
   where batch_id = p_batch_id
     and id = p_scan_id
     and examinee_id is null;

  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    raise exception 'create_examinee_from_scan: expected to link exactly 1 scan, linked % (scan % in batch %)',
      v_updated, p_scan_id, p_batch_id
      using errcode = 'P0001';
  end if;

  return v_examinee;
end;
$$;

-- EXECUTE privilege. PostgreSQL grants EXECUTE on every new function to
-- PUBLIC (everyone, including `anon`) by default, so revoke that first, then
-- grant only to `authenticated`. This is a privilege gate only: the function
-- still runs as the caller, so `examinees_insert_guidance` RLS
-- (user_role = 'guidance_council') is what actually limits who can create
-- an examinee -- a System Admin token has no `role`/`user_role` claim and is
-- `anon`, so it can neither execute this nor pass that policy.
revoke all on function public.create_examinee_from_scan(text, text, text, text, text)
  from public, anon;
grant execute on function public.create_examinee_from_scan(text, text, text, text, text)
  to authenticated;
