-- Connects an examination event (a scan) to the canonical applicant record
-- it belongs to. Nullable: most historical scans predate this relationship
-- and stay unlinked until 0003's conservative migration links them by exact
-- legacy Examinee Number. Never removes, renames, or alters any existing
-- `scans` column (examinee_number/first_name/middle_name/last_name and all
-- score/result/decoded/image/batch fields are untouched historical data).
alter table public.scans
  add column if not exists examinee_id uuid references public.examinees(id);

create index if not exists scans_examinee_id_idx on public.scans (examinee_id);
