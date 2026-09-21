-- Conservative legacy migration (Part 7 of the Examinee Records spec).
--
-- Rules this migration follows exactly, and never deviates from:
--   * One examinee row per DISTINCT nonblank legacy `scans.examinee_number`.
--   * NEVER merges by matching or similar names -- two different legacy
--     numbers always become two separate examinee records, even for the
--     exact same name.
--   * Scans with a blank/null `examinee_number` are left unlinked
--     (examinee_id stays null) -- never guessed at.
--   * Never modifies scores, decoded OMR JSON, images, or batch meaning --
--     the only column this touches is the brand-new `scans.examinee_id`
--     (previously always null) and newly-inserted `examinees` rows.
--
-- Idempotent: safe to re-run -- already-migrated legacy IDs and
-- already-linked scans are skipped on a second run.

-- One examinee per distinct nonblank legacy examinee_number. When multiple
-- scans share a legacy number (e.g. QTM + TAT + AT all still tagged with
-- the same pre-migration number), the earliest scan's name fields seed the
-- new record -- later scans under the same number only ever affect linkage
-- (below), never the examinee's stored name.
insert into public.examinees (
  temporary_examinee_id, first_name, middle_name, last_name, status,
  created_by_uid, updated_by_uid
)
select distinct on (s.examinee_number)
  s.examinee_number,
  coalesce(s.first_name, ''),
  s.middle_name,
  coalesce(s.last_name, ''),
  'active',
  '',
  ''
from public.scans s
where s.examinee_number is not null
  and btrim(s.examinee_number) <> ''
  and not exists (
    select 1 from public.examinees e
    where e.temporary_examinee_id = s.examinee_number
  )
order by s.examinee_number, s.created_at asc;

-- Link every not-yet-linked scan whose legacy examinee_number exactly
-- matches an examinee's temporary_examinee_id. Exact string match only --
-- no fuzzy/name-based linking.
update public.scans s
set examinee_id = e.id
from public.examinees e
where s.examinee_id is null
  and s.examinee_number is not null
  and btrim(s.examinee_number) <> ''
  and e.temporary_examinee_id = s.examinee_number;
