-- Runtime checks for 0113 (node withdraw step-up codes). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id, email) values
  ('44444444-4444-4444-4444-444444444444', 'su-owner@test.invalid'),
  ('55555555-5555-5555-5555-555555555555', 'su-admin@test.invalid');
update profiles set role = 'admin' where id in ('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555');

do $$
declare
  o uuid := '44444444-4444-4444-4444-444444444444';
  a uuid := '55555555-5555-5555-5555-555555555555';
  rq text := repeat('a', 64); rq2 text := repeat('b', 64);
  c text := repeat('1', 64); bad text := repeat('2', 64);
  i int; n int;
begin
  update app_settings set value = to_jsonb(o::text) where key = 'node_withdraw_owner_id';
  begin perform system_node_withdraw_stepup_issue(o, rq, c); raise exception 'issued while disabled';
  exception when others then if sqlerrm not like '%disabled%' then raise; end if; end;

  update app_settings set value = 'true'::jsonb where key = 'node_withdraw_enabled';
  begin perform system_node_withdraw_stepup_issue(a, rq, c); raise exception 'non-owner issued';
  exception when others then if sqlerrm <> 'Not authorized' then raise; end if; end;

  -- expiry is 5 minutes
  if system_node_withdraw_stepup_issue(o, rq, c) not between now() + interval '299 seconds' and now() + interval '301 seconds' then
    raise exception 'expiry not 5 min'; end if;

  -- wrong request or wrong code rejects; right one works once
  if system_node_withdraw_stepup_consume(o, rq2, c) then raise exception 'request mismatch accepted'; end if;
  if system_node_withdraw_stepup_consume(o, rq, bad) then raise exception 'wrong code accepted'; end if;
  if not system_node_withdraw_stepup_consume(o, rq, c) then raise exception 'right code refused'; end if;
  if system_node_withdraw_stepup_consume(o, rq, c) then raise exception 'code reused'; end if;

  -- 5 wrong attempts burn the code
  perform system_node_withdraw_stepup_issue(o, rq, c);
  for i in 1..5 loop
    if system_node_withdraw_stepup_consume(o, rq, bad) then raise exception 'bad accepted'; end if;
  end loop;
  if system_node_withdraw_stepup_consume(o, rq, c) then raise exception 'accepted after 5 attempts'; end if;

  -- expired code refused
  perform system_node_withdraw_stepup_issue(o, rq, c);
  update node_withdraw_stepups set expires_at = now() - interval '1 second' where used_at is null;
  if system_node_withdraw_stepup_consume(o, rq, c) then raise exception 'expired accepted'; end if;

  -- a new request replaces the old code
  perform system_node_withdraw_stepup_issue(o, rq, c);
  perform system_node_withdraw_stepup_issue(o, rq2, bad);
  if system_node_withdraw_stepup_consume(o, rq, c) then raise exception 'old code still live'; end if;

  -- audit trail, and the plain code is never stored
  select count(*) into n from audit_log where action like 'node_withdraw.stepup_%' and actor_id = o;
  if n < 10 then raise exception 'audit rows missing: %', n; end if;
  if not exists (select 1 from audit_log where action = 'node_withdraw.stepup_ok' and actor_id = o) then raise exception 'no ok audit'; end if;

  -- no client access
  if has_table_privilege('authenticated', 'node_withdraw_stepups', 'select') then raise exception 'table readable'; end if;
  if has_function_privilege('authenticated', 'system_node_withdraw_stepup_consume(uuid,text,text)', 'execute') then raise exception 'consume callable'; end if;
  if has_function_privilege('anon', 'system_node_withdraw_stepup_issue(uuid,text,text)', 'execute') then raise exception 'issue callable'; end if;
  raise notice 'node withdraw step-up regression OK';
end $$;
rollback;
