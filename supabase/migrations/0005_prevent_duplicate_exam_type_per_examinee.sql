-- One examinee may have at most one scan per exam type (QTM / TAT / AT), but
-- may have all three. This is the database-level backstop for the app's own
-- client-side duplicate check (see GuidanceWebExamineeRecordsService.
-- linkScanToExaminee): it closes the race where two sessions link two scans
-- of the same exam type to the same examinee at once (the loser gets 23505,
-- which the app translates to a friendly message).
--
-- Partial: unlinked scans (examinee_id IS NULL) are unconstrained, so any
-- number of unlinked scans of the same exam type can exist.
--
-- PREREQUISITE: no examinee may currently hold two scans of the same
-- exam_code, or this CREATE fails. Verify first:
--   select examinee_id, exam_code, count(*)
--   from public.scans where examinee_id is not null
--   group by examinee_id, exam_code having count(*) > 1;   -- expect no rows
--
-- Does not touch the scans primary key, ux_scans_batch_examinee, any other
-- index, RLS, or any data. NOT executed automatically -- apply by hand after
-- review.
CREATE UNIQUE INDEX IF NOT EXISTS ux_scans_examinee_exam_code
ON public.scans (examinee_id, exam_code)
WHERE examinee_id IS NOT NULL;
