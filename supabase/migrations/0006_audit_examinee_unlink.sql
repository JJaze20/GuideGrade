-- Audit trail for "Remove Link" (Examinee Records): record when a scan's
-- examinee link is cleared -- scans.examinee_id going from an examinee UUID
-- to NULL. The scan itself is never deleted; only the link is cleared.
--
-- Deliberately a SEPARATE function + trigger. The existing delete audit
-- mechanism (public.audit_batch_delete(), public.audit_scan_delete() and the
-- trg_audit_scan_delete BEFORE DELETE trigger on public.scans) is NOT touched.
--
-- NOT executed automatically -- apply by hand after review. Run the
-- "PRE-CHECKS" in the accompanying review first.
--
-- Atomicity: the trigger is AFTER UPDATE and runs inside the same
-- transaction as the unlink UPDATE that fired it. There is no exception
-- handling anywhere in the function, so if the guidance_activity INSERT
-- fails (bad value, missing privilege, ...), the error propagates and the
-- whole unlink UPDATE is rolled back -- an audit event can never be silently
-- lost while the link is cleared.
--
-- Security: the function is SECURITY INVOKER (the default). It changes no
-- RLS policy and no grant. It therefore relies on the calling role already
-- being allowed to INSERT into public.guidance_activity -- see the
-- pre-check on that in the review; if the existing audit functions turn out
-- to be SECURITY DEFINER for exactly that reason, this one must follow the
-- same pattern and this file must be revised BEFORE it is run.

begin;

-- 1. Allow the new action. Preserves EVERY existing action and adds only
--    'examinee_unlinked'. entity_type's CHECK is not touched (the new rows use
--    the existing entity_type 'scan').
--
--    Fail loudly if the constraint is not there under the expected name:
--    otherwise `drop ... if exists` would silently do nothing, the ADD below
--    would create a SECOND check, the old one would still reject
--    'examinee_unlinked', and every Remove Link would then fail.
do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conrelid = 'public.guidance_activity'::regclass
       and conname  = 'guidance_activity_action_check'
       and contype  = 'c'
  ) then
    raise exception
      'guidance_activity_action_check not found on public.guidance_activity; refusing to continue';
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
    'examinee_unlinked'
  ));

-- 2. The audit function. Actor extraction mirrors the existing audit
--    functions: request.jwt.claims -> sub / email, 'system' when there is no
--    JWT (e.g. a manual SQL-editor update). OLD.examinee_id is what is
--    recorded, because NEW.examinee_id is NULL by definition of an unlink --
--    OLD is the only place the examinee that was unlinked still exists.
--    actor_name, batch_code, scan_count, was_tagged, image_paths and reason
--    are left NULL; `hard` and `id`/`occurred_at` keep their column defaults.
create or replace function public.audit_scan_examinee_unlink()
returns trigger
language plpgsql
as $$
declare
  claims jsonb;
begin
  -- Re-checked here (the trigger's WHEN clause already restricts it) so the
  -- function is safe on its own: only "examinee -> NULL" is ever audited.
  if old.examinee_id is not null and new.examinee_id is null then
    claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;

    insert into public.guidance_activity (
      actor_uid,
      actor_email,
      action,
      entity_type,
      entity_id,
      batch_id,
      exam_code,
      examinee_id
    )
    values (
      coalesce(claims ->> 'sub', 'system'),
      claims ->> 'email',
      'examinee_unlinked',
      'scan',
      old.id,
      old.batch_id,
      old.exam_code,
      old.examinee_id
    );
  end if;

  return new;
end;
$$;

-- 3. The trigger. Fires only for an UPDATE that names examinee_id AND only
--    when a non-null examinee_id becomes NULL. It does NOT fire for
--    NULL -> examinee (link), examinee A -> examinee B, updates that do not
--    touch examinee_id (the mobile sync upsert never sends it), or DELETE.
drop trigger if exists trg_audit_examinee_unlink on public.scans;

create trigger trg_audit_examinee_unlink
  after update of examinee_id on public.scans
  for each row
  when (old.examinee_id is not null and new.examinee_id is null)
  execute function public.audit_scan_examinee_unlink();

commit;
