-- Canonical applicant/examinee record -- one examinee (person) can have many
-- scans across QTM / TAT / Admission Test (see 0002_add_examinee_id_to_scans.sql).
-- Mirrors lib/models/examinee_record.dart field-for-field.
--
-- NOT executed automatically -- this repo has no migration runner wired up.
-- Run this by hand (Supabase SQL editor or `supabase db push`) against the
-- project, in order, before deploying the Examinee Records feature.

-- Backs temporary_examinee_id's DEFAULT below. PostgreSQL's nextval() is
-- atomic under concurrent transactions -- two simultaneous creates (e.g.
-- from two different Guidance Council devices/sessions) can never be
-- assigned the same value, unlike a client-generated timestamp+counter.
-- This sequence is deliberately separate from anything the mobile app's
-- per-scan `generateExamineeId()` uses -- it exists only for this table.
create sequence if not exists public.examinees_temporary_id_seq;

create table if not exists public.examinees (
  id uuid primary key default gen_random_uuid(),
  -- Human-readable, e.g. 'EX-000001', 'EX-000002', ... Assigned ONLY by
  -- this default -- the application never sends this column on insert
  -- (see SupabaseSyncClient.createExamineeFromScan /
  -- create_examinee_from_scan in 0004). Format is structurally
  -- distinct from the legacy per-scan `scans.examinee_number` values
  -- (which look like 'EX-<13-digit-millis>-<n>'), so a legacy ID migrated
  -- by 0003 can never collide with a newly-generated one; the `unique`
  -- constraint below would reject it loudly rather than corrupt data even
  -- in the extreme edge case that it somehow did.
  temporary_examinee_id text not null unique
    default ('EX-' || lpad(nextval('public.examinees_temporary_id_seq')::text, 6, '0')),
  official_student_id text,
  first_name text not null,
  middle_name text,
  last_name text not null,
  birth_date date,
  last_attended_school text,
  status text not null default 'active' check (status in ('active', 'archived')),
  archived_at timestamptz,
  archived_by_uid text,
  created_at timestamptz not null default now(),
  created_by_uid text not null default '',
  updated_at timestamptz not null default now(),
  updated_by_uid text not null default ''
);

create index if not exists examinees_status_idx on public.examinees (status);
create index if not exists examinees_official_student_id_idx on public.examinees (official_student_id);
create index if not exists examinees_name_idx on public.examinees (last_name, first_name);

-- Belt-and-suspenders: the Dart app never exposes temporary_examinee_id as
-- editable (no update method accepts it), and this trigger rejects any
-- change at the database level too, including a manual SQL edit.
create or replace function public.examinees_prevent_temporary_id_change()
returns trigger as $$
begin
  if new.temporary_examinee_id is distinct from old.temporary_examinee_id then
    raise exception 'temporary_examinee_id is immutable once assigned';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists examinees_immutable_temporary_id on public.examinees;
create trigger examinees_immutable_temporary_id
  before update on public.examinees
  for each row execute function public.examinees_prevent_temporary_id_change();

alter table public.examinees enable row level security;

-- Table privileges (PostgreSQL GRANTs), separate from and in addition to RLS.
-- A correct RLS policy is not enough on its own: the calling role must ALSO
-- hold the table privilege, or the request fails with 42501 "permission
-- denied for table" before any policy is consulted. (This project's existing
-- tables deny `anon` by missing grants; nothing in the repo documents
-- `authenticated`'s grants on batches/scans/answer_keys, so none are assumed
-- here.)
--
-- Reset first so the result is exactly the minimum regardless of what
-- default privileges the project applies to new tables, then grant only what
-- the approved Examinee Records workflow needs:
--   SELECT  -> list/search examinees, load a record
--   INSERT  -> create_examinee_from_scan (runs as the caller, SECURITY INVOKER)
--   UPDATE  -> name-only correction, archive/restore
-- NO DELETE (nobody can delete an examinee), and nothing for `anon`.
revoke all on table public.examinees from anon, authenticated;
grant select, insert, update on table public.examinees to authenticated;

-- The temporary_examinee_id DEFAULT calls nextval() with the INSERTING role's
-- privileges, so `authenticated` needs USAGE on the sequence (USAGE is the
-- minimum nextval() requires; SELECT/UPDATE on it are not needed).
revoke all on sequence public.examinees_temporary_id_seq from anon, authenticated;
grant usage on sequence public.examinees_temporary_id_seq to authenticated;

-- Only Guidance Council has any access to this feature (see the app's own
-- route gating in lib/core/routes/app_routes.dart -- System Admin never
-- even reaches a screen that could call these). Keys off the same
-- `user_role` JWT claim already staged (but unused) for
-- tools/firebase-claims/backfill-auth-claim.js.
--
-- Deliberately NO delete policy at all -- nobody can delete an examinee
-- through PostgREST; archiving (an UPDATE of `status`) is the only
-- supported way to remove one from active view.
create policy examinees_select_guidance on public.examinees
  for select
  using ((auth.jwt() ->> 'user_role') = 'guidance_council');

create policy examinees_insert_guidance on public.examinees
  for insert
  with check ((auth.jwt() ->> 'user_role') = 'guidance_council');

create policy examinees_update_guidance on public.examinees
  for update
  using ((auth.jwt() ->> 'user_role') = 'guidance_council')
  with check ((auth.jwt() ->> 'user_role') = 'guidance_council');
