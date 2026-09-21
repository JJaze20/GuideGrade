// Static checks on supabase/migrations/0007_create_batch_archives.sql. The
// SQL itself is applied by hand against Supabase (there is no migration
// runner), so these tests pin the properties the feature's safety depends on.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File('supabase/migrations/0007_create_batch_archives.sql').readAsStringSync();
  // Executable SQL only (comments stripped) for "must not contain" checks.
  final code = sql
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join('\n')
      .toLowerCase();

  test('creates batch_archives keyed by batch_id with ON DELETE CASCADE to batches(id)', () {
    expect(code, contains('create table if not exists public.batch_archives'));
    expect(code, contains('batch_id text primary key'));
    expect(code, contains('references public.batches(id) on delete cascade'));
    for (final col in ['archived_at', 'archived_by_uid', 'archived_by_name', 'reason']) {
      expect(code, contains(col));
    }
  });

  test('has RLS, Guidance Council select/insert policies only, and no delete/update path (no restore)', () {
    expect(code, contains('alter table public.batch_archives enable row level security'));
    expect(code, contains("auth.jwt() ->> 'user_role') = 'guidance_council'"));
    expect(code, contains('grant select, insert on table public.batch_archives to authenticated'));
    expect(code, isNot(contains('grant delete')));
    expect(code, isNot(contains('grant update')));
    expect(code, isNot(contains('for delete')));
    expect(code, isNot(contains('for update')));
    expect(code, isNot(contains('for all')));
  });

  test('the insert policy requires a truthful actor and a Completed batch (read-only look at batches)', () {
    expect(code, contains("archived_by_uid = (auth.jwt() ->> 'sub')"));
    expect(code, contains("b.status = 'completed'".replaceAll('completed', 'Completed').toLowerCase()));
  });

  test('never writes batches or scans (mobile-owned data untouched)', () {
    expect(code, isNot(contains('update public.batches')));
    expect(code, isNot(contains('insert into public.batches')));
    expect(code, isNot(contains('delete from public.batches')));
    expect(code, isNot(contains('alter table public.batches')));
    expect(code, isNot(contains('alter table public.scans')));
    expect(code, isNot(contains('update public.scans')));
    expect(code, isNot(contains('delete from public.scans')));
  });

  test('adds batch_archived to the audit action CHECK, preserving every existing action', () {
    for (final action in [
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
      'batch_archived',
    ]) {
      expect(code, contains("'$action'"), reason: action);
    }
    // entity_type's CHECK is not touched.
    expect(code, isNot(contains('guidance_activity_entity_type_check')));
    // Refuses to run before 0006 so it cannot drop 'examinee_unlinked'.
    expect(code, contains('run 0006_audit_examinee_unlink.sql first'));
  });

  test('records batch_archived with the existing actor pattern, atomically (no exception swallowing)', () {
    expect(code, contains('create or replace function public.audit_batch_archive()'));
    expect(code, contains('after insert on public.batch_archives'));
    expect(code, contains("coalesce(claims ->> 'sub', 'system')"));
    expect(code, contains("claims ->> 'email'"));
    for (final col in ['batch_code', 'exam_code', 'scan_count', 'reason', 'actor_name']) {
      expect(code, contains(col), reason: col);
    }
    expect(code, isNot(contains('exception when')));
    expect(code, isNot(contains('security definer')));
  });

  test('does not add restore auditing or touch the existing delete audit', () {
    expect(code, isNot(contains('batch_restored')));
    expect(code, isNot(contains('audit_batch_delete')));
    expect(code, isNot(contains('audit_scan_delete')));
    expect(code, isNot(contains('trg_audit_scan_delete')));
  });
}
