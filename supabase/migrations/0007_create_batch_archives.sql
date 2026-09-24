-- Guidance Council WEB Archive marker.
--
-- A row in public.batch_archives means "this batch is archived in the
-- Guidance Council Web application". No row means it is not. Nothing is
-- moved, copied, or deleted: the batch, its scans, scores, decoded answers,
-- images and examinee links are untouched, and public.batches (including
-- batches.status and batches.updated_at, which belong to the mobile app) is
-- NEVER written by this feature. Mobile sync (pushBatch upserts an explicit
-- column list into public.batches) does not know this table exists, so a
-- mobile sync can never unarchive a batch.
--
-- There is deliberately NO restore: no UPDATE and no DELETE grant or policy
-- for `authenticated`. (A batch deleted from mobile removes its marker via
-- the ON DELETE CASCADE below -- that cascade runs as the table owner and
-- needs no privilege on this table.)
--
-- PREREQUISITES -- run 0006_audit_examinee_unlink.sql FIRST. Both files
-- replace public.guidance_activity's action CHECK with a full list; this one
-- refuses to run unless 0006's 'examinee_unlinked' is already allowed, and
-- its list includes 'examinee_unlinked', so 0006 must never be re-run
-- afterwards (it would drop 'batch_archived' from the list).
--
-- NOT executed automatically -- apply by hand after review.
--
-- Security notes:
--  * Authorization is the same claim the existing scans policies and the
--    examinees policies use: auth.jwt() ->> 'user_role' = 'guidance_council'.
--  * The audit trigger below is SECURITY INVOKER (default), so the caller
--    must be able to INSERT into public.guidance_activity. If that is not
--    the case (e.g. the existing audit functions are SECURITY DEFINER for
--    exactly that reason), archiving fails and rolls back -- safely, but
--    this file must then be revised before use.

begin;

-- 1. The marker table. batch_id is text to match public.batches.id.
create table if not exists public.batch_archives (
  batch_id text primary key
    references public.batches(id) on delete cascade,
  archived_at timestamptz not null default now(),
  archived_by_uid text not null,
  archived_by_name text,
  reason text
);

alter table public.batch_archives enable row level security;

-- 2. Minimum grants: read and create only. No UPDATE, no DELETE, nothing for
--    anon. Reset first so the result is exactly this regardless of default
--    privileges.
revoke all on table public.batch_archives from anon, authenticated;
grant select, insert on table public.batch_archives to authenticated;

-- 3. Policies (Guidance Council only). INSERT additionally requires that
--    the actor is recorded truthfully (archived_by_uid must equal the JWT
--    `sub`) and that the batch is currently Completed -- the database-side
--    twin of the app's eligibility check. Reading batches.status here is a
--    read only; batches is never modified.
drop policy if exists batch_archives_select_guidance on public.batch_archives;
create policy batch_archives_select_guidance on public.batch_archives
  for select
  using ((auth.jwt() ->> 'user_role') = 'guidance_council');

drop policy if exists batch_archives_insert_guidance on public.batch_archives;
create policy batch_archives_insert_guidance on public.batch_archives
  for insert
  with check (
    (auth.jwt() ->> 'user_role') = 'guidance_council'
    and archived_by_uid = (auth.jwt() ->> 'sub')
    and exists (
      select 1
        from public.batches b
       where b.id = batch_archives.batch_id
         and b.status = 'Completed'
    )
  );

-- 4. Audit support. Add 'batch_archived' to guidance_activity's action
--    CHECK, preserving every existing action (including 0006's
--    'examinee_unlinked'). entity_type's CHECK is not touched: rows use the
--    existing entity_type 'batch'. Fail loudly instead of silently
--    duplicating/replacing the wrong constraint.
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

  if def not like '%examinee_unlinked%' then
    raise exception
      'guidance_activity_action_check does not allow examinee_unlinked; run 0006_audit_examinee_unlink.sql first';
  end if;
end
$$;

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
    'batch_archived'
  ));

-- 5. The audit trigger. Actor extraction mirrors the existing audit
--    functions (request.jwt.claims -> sub / email, 'system' when there is no
--    JWT). actor_name is the name the app recorded on the marker row itself.
--    batch_code / exam_code / scan_count are read from the batch and its
--    scans at archive time. `reason` is the optional archive reason. `hard`,
--    `id` and `occurred_at` keep their column defaults. AFTER INSERT in the
--    same transaction, with no exception handling: if the audit insert
--    fails, the archive insert is rolled back rather than losing the event.
create or replace function public.audit_batch_archive()
returns trigger
language plpgsql
as $$
declare
  claims       jsonb;
  v_batch_code text;
  v_exam_code  text;
  v_scan_count integer;
begin
  claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;

  select b.batch_code, b.exam_code
    into v_batch_code, v_exam_code
    from public.batches b
   where b.id = new.batch_id;

  select count(*)
    into v_scan_count
    from public.scans s
   where s.batch_id = new.batch_id;

  insert into public.guidance_activity (
    actor_uid,
    actor_email,
    actor_name,
    action,
    entity_type,
    entity_id,
    batch_id,
    batch_code,
    exam_code,
    scan_count,
    reason
  )
  values (
    coalesce(claims ->> 'sub', 'system'),
    claims ->> 'email',
    nullif(new.archived_by_name, ''),
    'batch_archived',
    'batch',
    new.batch_id,
    new.batch_id,
    v_batch_code,
    v_exam_code,
    v_scan_count,
    nullif(new.reason, '')
  );

  return new;
end;
$$;

drop trigger if exists trg_audit_batch_archive on public.batch_archives;

create trigger trg_audit_batch_archive
  after insert on public.batch_archives
  for each row
  execute function public.audit_batch_archive();

commit;
