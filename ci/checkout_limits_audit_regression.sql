-- 0111: checkout limit changes are audited. Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
do $$
declare n0 int; n1 int;
begin
  select count(*) into n0 from audit_log where action = 'checkout_limit';
  insert into app_settings(key, value) values ('lnd_pay_min_usd', '10')
    on conflict (key) do update set value = excluded.value;
  insert into app_settings(key, value) values ('lnd_pay_min_usd', '12')
    on conflict (key) do update set value = excluded.value;
  insert into app_settings(key, value) values ('lnd_pay_min_usd', '12')
    on conflict (key) do update set value = excluded.value;   -- unchanged: no row
  insert into app_settings(key, value) values ('some_other_key', '1')
    on conflict (key) do update set value = excluded.value;   -- not audited
  select count(*) into n1 from audit_log where action = 'checkout_limit';
  assert n1 - n0 = 2, format('expected 2 audit rows, got %s', n1 - n0);
  assert exists (select 1 from audit_log where action='checkout_limit' and subject_id='lnd_pay_min_usd'
    and old_value = '10'::jsonb and new_value = '12'::jsonb), 'old/new recorded';
  raise notice 'checkout limits audit regression OK';
end $$;
rollback;
