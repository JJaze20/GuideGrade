-- Admission Test SAI inputs (Examinee Records, Guidance Council Web):
--
--   * examinees.gender         -- new, nullable. Information only; it does not
--                                 change any score.
--   * scans.exam_date          -- new, nullable date: the day THIS sitting of the
--                                 exam was taken. It lives on the scan (not the
--                                 examinee) so a retake keeps its own date and an
--                                 archived earlier attempt keeps the date it was
--                                 taken on.
--   * examinees.birth_date and examinees.last_attended_school ALREADY exist
--     (0001) and are reused as they are -- not touched here.
--
-- Two small functions are added so the web app can write these fields:
--   * create_examinee_from_scan_with_details(...)  -- 0004's create-and-link in
--     one transaction, plus the four details. 0004's original 5-argument
--     function is left exactly as it is, so an older app build keeps working.
--   * set_scan_exam_date(...)  -- the ONLY way the web writes scans.exam_date
--     after creation (the edit screen).
--
-- NOT executed automatically -- review, test on a TEST database first, then
-- apply by hand (SQL editor or `supabase db push`), the same as 0001-0012.
-- Nothing here deletes or rewrites any existing data: both new columns start
-- empty, so every existing result keeps its raw score and simply shows
-- "Add birth date and exam date" until someone fills the dates in.
--
-- Security (nothing is weakened):
--   * No RLS policy is changed. No new table. No grant on a table is widened.
--   * Both functions are SECURITY INVOKER (the default), like 0004: they run as
--     the caller, so the existing `examinees_insert_guidance` RLS and the
--     existing `scans` privileges still apply exactly as for a direct write.
--   * Each function ALSO checks the `user_role = 'guidance_council'` JWT claim
--     itself and refuses anyone else (42501), so a System Admin token cannot
--     use them even if some grant were later widened by mistake.
--   * EXECUTE is revoked from PUBLIC/anon and granted only to `authenticated`.
--   * The completed-batch guards from 0012 only fire on deleted_at / batch_id /
--     status changes, so setting exam_date on a Completed batch is still
--     allowed (details are often filled in after a batch is completed).
--
-- ---------------------------------------------------------------------------
-- PRE-CHECKS (run these first, read-only; they decide whether Step 4 is needed)
-- ---------------------------------------------------------------------------
--   -- a) Can `authenticated` UPDATE the scans table today? The existing
--   --    "Create Examinee Record from this Scan" and link/unlink flows already
--   --    update scans.examinee_id as the caller, so the answer should be yes.
--   select grantee, privilege_type, is_grantable
--     from information_schema.table_privileges
--    where table_schema = 'public' and table_name = 'scans'
--      and grantee in ('authenticated', 'anon');
--
--   -- b) If the table-level UPDATE row above is missing for `authenticated`,
--   --    UPDATE may be granted per column instead. Look for column rows:
--   select grantee, column_name, privilege_type
--     from information_schema.column_privileges
--    where table_schema = 'public' and table_name = 'scans'
--      and grantee = 'authenticated' and privilege_type = 'UPDATE'
--    order by column_name;
--
--   -- c) The new column names must not exist yet (expect zero rows):
--   select table_name, column_name from information_schema.columns
--    where table_schema = 'public'
--      and ((table_name = 'examinees' and column_name = 'gender')
--        or (table_name = 'scans' and column_name = 'exam_date'));

begin;

-- 1. New columns. Both nullable, no default, no backfill.
alter table public.examinees
  add column if not exists gender text;

-- A short length guard only; which values the screen offers (for example
-- Male / Female) is the app's choice, so the database does not hard-code a list.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.examinees'::regclass
       and conname = 'examinees_gender_length_check'
  ) then
    alter table public.examinees
      add constraint examinees_gender_length_check
      check (gender is null or char_length(gender) <= 30);
  end if;
end
$$;

alter table public.scans
  add column if not exists exam_date date;

-- 2. Create the examinee and link the scan in one transaction, saving the
--    details. Same flow and same safety rules as 0004's function (locks the
--    scan, refuses an already-linked scan, requires exactly one scan linked).
create or replace function public.create_examinee_from_scan_with_details(
  p_batch_id text,
  p_scan_id text,
  p_first_name text,
  p_middle_name text,
  p_last_name text,
  p_birth_date date,
  p_last_attended_school text,
  p_gender text,
  p_exam_date date
)
returns public.examinees
language plpgsql
as $$
declare
  v_examinee public.examinees;
  v_existing_examinee_id uuid;
  v_updated integer;
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'guidance_council' then
    raise exception 'create_examinee_from_scan_with_details: Guidance Council only'
      using errcode = '42501';
  end if;

  -- Light date sanity checks (the app validates too). A birth date in the
  -- future, or after the exam date, can never be right.
  if p_birth_date is not null and p_birth_date > current_date then
    raise exception 'create_examinee_from_scan_with_details: birth date is in the future'
      using errcode = '22023';
  end if;
  if p_birth_date is not null and p_exam_date is not null
     and p_birth_date > p_exam_date then
    raise exception 'create_examinee_from_scan_with_details: birth date is after the exam date'
      using errcode = '22023';
  end if;

  select examinee_id
    into v_existing_examinee_id
    from public.scans
   where batch_id = p_batch_id and id = p_scan_id
     for update;

  if not found then
    raise exception 'create_examinee_from_scan_with_details: scan % in batch % does not exist',
      p_scan_id, p_batch_id
      using errcode = 'P0002';
  end if;

  if v_existing_examinee_id is not null then
    raise exception 'create_examinee_from_scan_with_details: scan % in batch % is already linked to an examinee',
      p_scan_id, p_batch_id
      using errcode = '23505';
  end if;

  insert into public.examinees (
    first_name, middle_name, last_name,
    birth_date, last_attended_school, gender,
    status, created_by_uid, updated_by_uid
  )
  values (
    p_first_name, nullif(p_middle_name, ''), p_last_name,
    p_birth_date, nullif(btrim(p_last_attended_school), ''),
    nullif(btrim(p_gender), ''),
    'active',
    coalesce(auth.jwt() ->> 'sub', ''), coalesce(auth.jwt() ->> 'sub', '')
  )
  returning * into v_examinee;

  update public.scans
     set examinee_id = v_examinee.id,
         exam_date = p_exam_date
   where batch_id = p_batch_id
     and id = p_scan_id
     and examinee_id is null;

  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    raise exception 'create_examinee_from_scan_with_details: expected to link exactly 1 scan, linked % (scan % in batch %)',
      v_updated, p_scan_id, p_batch_id
      using errcode = 'P0001';
  end if;

  return v_examinee;
end;
$$;

revoke all on function public.create_examinee_from_scan_with_details(
  text, text, text, text, text, date, text, text, date) from public, anon;
grant execute on function public.create_examinee_from_scan_with_details(
  text, text, text, text, text, date, text, text, date) to authenticated;

-- 3. Correct (or clear) one sitting's exam date from the edit screen. It
--    changes ONLY scans.exam_date, only on a scan that is not soft-deleted,
--    and returns the stored value. Passing null clears the date.
create or replace function public.set_scan_exam_date(
  p_batch_id text,
  p_scan_id text,
  p_exam_date date
)
returns date
language plpgsql
as $$
declare
  v_birth_date date;
  v_updated integer;
begin
  if (auth.jwt() ->> 'user_role') is distinct from 'guidance_council' then
    raise exception 'set_scan_exam_date: Guidance Council only'
      using errcode = '42501';
  end if;

  -- The exam cannot be before the examinee's birth.
  select e.birth_date
    into v_birth_date
    from public.scans s
    left join public.examinees e on e.id = s.examinee_id
   where s.batch_id = p_batch_id and s.id = p_scan_id;

  if p_exam_date is not null and v_birth_date is not null
     and v_birth_date > p_exam_date then
    raise exception 'set_scan_exam_date: exam date is before the birth date'
      using errcode = '22023';
  end if;

  update public.scans
     set exam_date = p_exam_date
   where batch_id = p_batch_id
     and id = p_scan_id
     and deleted_at is null;

  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    raise exception 'set_scan_exam_date: expected to update exactly 1 scan, updated % (scan % in batch %)',
      v_updated, p_scan_id, p_batch_id
      using errcode = 'P0001';
  end if;

  return p_exam_date;
end;
$$;

revoke all on function public.set_scan_exam_date(text, text, date) from public, anon;
grant execute on function public.set_scan_exam_date(text, text, date) to authenticated;

commit;

-- ---------------------------------------------------------------------------
-- STEP 4 (ONLY IF pre-check a/b shows `authenticated` cannot UPDATE
-- scans.exam_date): grant just that ONE column, nothing broader. Leave this
-- commented out unless the owner decides it is needed after reading the
-- pre-check results.
--
--   grant update (exam_date) on table public.scans to authenticated;
--
-- ---------------------------------------------------------------------------
-- VERIFICATION (read-only, after applying)
-- ---------------------------------------------------------------------------
--   -- both columns exist and are empty for every existing row (expect 0, 0):
--   select count(*) filter (where gender is not null) from public.examinees;
--   select count(*) filter (where exam_date is not null) from public.scans;
--
--   -- both functions exist, SECURITY INVOKER (prosecdef = false), and are not
--   -- executable by PUBLIC/anon:
--   select proname, prosecdef from pg_proc
--    where proname in ('create_examinee_from_scan_with_details','set_scan_exam_date');
--
--   -- 0004's original function is unchanged:
--   select pg_get_function_arguments('public.create_examinee_from_scan(text,text,text,text,text)'::regprocedure);
--
-- ---------------------------------------------------------------------------
-- ROLLBACK NOTES (do NOT run unless reverting; the two drops lose any dates
-- entered since). The functions can be dropped safely at any time:
--   drop function if exists public.set_scan_exam_date(text, text, date);
--   drop function if exists public.create_examinee_from_scan_with_details(
--     text, text, text, text, text, date, text, text, date);
-- Dropping the columns is destructive and should be a deliberate decision:
--   alter table public.examinees drop constraint if exists examinees_gender_length_check;
--   alter table public.examinees drop column if exists gender;
--   alter table public.scans drop column if exists exam_date;
