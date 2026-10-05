-- Review and deploy explicitly; the application does not execute this migration.
-- Business completion is Completed or a Web batch_archives marker, not the
-- mobile Archived label meaning a successfully synchronized revision.
begin;
create or replace function public.guard_completed_batch_deletion()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'Completed' or exists (
    select 1 from public.batch_archives where batch_id = old.id
  ) then
    if tg_op = 'DELETE' then
      raise exception 'Completed batches cannot be deleted' using errcode = '42501';
    end if;
    if new.status is distinct from old.status then
      raise exception 'Completed batch status cannot be reopened' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger protect_completed_batch before delete or update of status
on public.batches for each row execute function public.guard_completed_batch_deletion();

create or replace function public.guard_completed_batch_scan_deletion()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  -- Serialize with status changes to the parent batch.
  select status into v_status from public.batches where id = old.batch_id for update;
  if v_status = 'Completed' or exists (
    select 1 from public.batch_archives where batch_id = old.batch_id
  ) then
    if tg_op = 'DELETE' then
      raise exception 'Completed batch scans cannot be deleted' using errcode = '42501';
    end if;
    if (old.deleted_at is null and new.deleted_at is not null)
        or new.batch_id is distinct from old.batch_id then
      raise exception 'Completed batch scans cannot be removed' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger protect_completed_batch_scans before delete or update of deleted_at, batch_id
on public.scans for each row execute function public.guard_completed_batch_scan_deletion();

create or replace function public.guard_batch_archive_marker()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform 1 from public.batches where id = new.batch_id for update;
    return new;
  end if;
  raise exception 'Completed Batch archive markers cannot be removed or changed' using errcode = '42501';
end;
$$;
create trigger protect_batch_archive_marker before insert or update or delete
on public.batch_archives for each row execute function public.guard_batch_archive_marker();
commit;
