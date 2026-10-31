-- Runtime checks for 0111 (owner-only node withdraw). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id, email) values
  ('44444444-4444-4444-4444-444444444444', 'nw-owner@test.invalid'),
  ('55555555-5555-5555-5555-555555555555', 'nw-admin@test.invalid');
update profiles set role = 'admin', email = 'nw-owner@test.invalid' where id = '44444444-4444-4444-4444-444444444444';
update profiles set role = 'admin', email = 'nw-admin@test.invalid' where id = '55555555-5555-5555-5555-555555555555';

do $$
declare
  o uuid := '44444444-4444-4444-4444-444444444444';
  a uuid := '55555555-5555-5555-5555-555555555555';
  addr text := 'bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq';
  v_id bigint; v_id2 bigint; n int;
begin
  -- Defaults: OFF, low cap, no owner
  if (select value from app_settings where key = 'node_withdraw_enabled') <> 'false'::jsonb then raise exception 'flag not off'; end if;
  if (select value from app_settings where key = 'node_withdraw_daily_cap_sat') <> '50000'::jsonb then raise exception 'cap'; end if;
  if (select value from app_settings where key = 'node_withdraw_max_fee_sat') <> '2000'::jsonb then raise exception 'max fee'; end if;
  if (select value from app_settings where key = 'node_withdraw_owner_id') <> 'null'::jsonb then raise exception 'owner set'; end if;

  -- Flag off => refused even for the owner
  update app_settings set value = to_jsonb(o::text) where key = 'node_withdraw_owner_id';
  begin
    perform system_node_withdraw_reserve(o, 'onchain', addr, 1000, 100, 'key-off-0001');
    raise exception 'reserved while disabled';
  exception when others then if sqlerrm <> 'node withdraw is disabled' then raise; end if;
  end;

  update app_settings set value = 'true'::jsonb where key = 'node_withdraw_enabled';

  -- Another admin is not the owner
  begin
    perform system_node_withdraw_reserve(a, 'onchain', addr, 1000, 100, 'key-admin-001');
    raise exception 'non-owner reserved';
  exception when others then if sqlerrm <> 'Not authorized' then raise; end if;
  end;

  -- Fee limit above max
  begin
    perform system_node_withdraw_reserve(o, 'onchain', addr, 1000, 2001, 'key-fee-00001');
    raise exception 'fee above max accepted';
  exception when others then if sqlerrm not like 'fee limit%' then raise; end if;
  end;

  -- Owner reserve works, writes audit, and is idempotent
  v_id := system_node_withdraw_reserve(o, 'onchain', addr, 30000, 1000, 'key-ok-000001');
  v_id2 := system_node_withdraw_reserve(o, 'onchain', addr, 30000, 1000, 'key-ok-000001');
  if v_id <> v_id2 then raise exception 'not idempotent'; end if;
  select count(*) into n from node_withdrawals; if n <> 1 then raise exception 'rows %', n; end if;
  select count(*) into n from audit_log where action = 'node_withdraw.reserve' and subject_id = v_id::text;
  if n <> 1 then raise exception 'audit rows %', n; end if;

  -- Same key, different details => refused
  begin
    perform system_node_withdraw_reserve(o, 'onchain', addr, 30001, 1000, 'key-ok-000001');
    raise exception 'key reuse accepted';
  exception when others then if sqlerrm not like 'request_key reused%' then raise; end if;
  end;

  -- Daily cap: 31000 used, 20000 + 1000 more would make 52000 > 50000
  begin
    perform system_node_withdraw_reserve(o, 'lightning', 'lnbc200u1pexampleinvoice', 20000, 1000, 'key-cap-00001');
    raise exception 'cap not enforced';
  exception when others then if sqlerrm <> 'daily cap exceeded' then raise; end if;
  end;

  -- A failed send frees its room under the cap
  if not system_node_withdraw_finish(v_id, 'failed', null, null, 'test') then raise exception 'finish failed'; end if;
  if system_node_withdraw_finish(v_id, 'sent', 'x', 1, null) then raise exception 'finished twice'; end if;
  v_id2 := system_node_withdraw_reserve(o, 'lightning', 'lnbc200u1pexampleinvoice', 20000, 1000, 'key-cap-00001');
  if not system_node_withdraw_finish(v_id2, 'sent', repeat('ab', 32), 3, null) then raise exception 'sent'; end if;
  select count(*) into n from audit_log where subject_type = 'node_withdrawal';
  if n <> 4 then raise exception 'audit total %', n; end if;

  -- Client roles have no access
  if has_table_privilege('anon', 'node_withdrawals', 'select') then raise exception 'anon reads'; end if;
  if has_table_privilege('authenticated', 'node_withdrawals', 'select') then raise exception 'auth reads'; end if;
  if has_table_privilege('authenticated', 'node_withdrawals', 'insert') then raise exception 'auth writes'; end if;
  if has_function_privilege('authenticated', 'system_lnd_withdraw_config()', 'execute') then raise exception 'auth reads config'; end if;
  if has_function_privilege('anon', 'system_lnd_withdraw_config()', 'execute') then raise exception 'anon reads config'; end if;
  if has_function_privilege('authenticated', 'system_node_withdraw_reserve(uuid,text,text,bigint,bigint,text)', 'execute') then raise exception 'auth reserves'; end if;
  if has_function_privilege('authenticated', 'system_node_withdraw_finish(bigint,text,text,bigint,text)', 'execute') then raise exception 'auth finishes'; end if;
  if not has_function_privilege('service_role', 'system_node_withdraw_reserve(uuid,text,text,bigint,bigint,text)', 'execute') then raise exception 'service cannot reserve'; end if;
end $$;
rollback;
select 'Node withdraw 0111 runtime checks passed' as result;
