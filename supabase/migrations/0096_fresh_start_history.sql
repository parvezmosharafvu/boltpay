-- 0096: fresh start (owner's final instruction, 2026-10-30).
-- Deletes all payment and withdrawal history and the tables derived from
-- it, so every balance starts at zero. A full export was taken first.
-- Accounts, links, settings, domains, moderators and support messages
-- are NOT touched. The audit log is kept.

do $$
begin
  if exists (select 1 from withdrawals where status in ('pending', 'processing')) then
    raise exception 'Open withdrawals exist; refusing to wipe history';
  end if;
  if exists (select 1 from payments where status in ('new', 'pending') and expires_at > now()) then
    raise exception 'Live invoices in flight; refusing to wipe history';
  end if;
end $$;

delete from payment_events;
delete from payments;
delete from withdrawals;
delete from daily_invoices;
delete from daily_stats;
delete from manual_invoices;

-- Only LND from here on.
alter table payments alter column backend set default 'lnd';
alter table payments drop constraint if exists payments_backend_fields;
alter table payments drop constraint if exists payments_backend_check;
alter table payments add constraint payments_backend_check check (backend = 'lnd');
alter table payments add constraint payments_backend_fields
  check (lnd_r_hash is not null and amount_sats is not null and amount_sats > 0);
