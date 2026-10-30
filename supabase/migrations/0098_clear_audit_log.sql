-- 0098: clear the old audit log rows (owner's instruction, 2026-10-30:
-- "Delete and clear all"). All 130 rows were exported first to
-- backups/full-history-2026-10-30/audit_log.json and the daily DB backup ran.
-- The table, its grants and record_audit() are kept, so new audit rows keep
-- being written. DELETE (not TRUNCATE) so no grants or sequences change.
delete from public.audit_log;
