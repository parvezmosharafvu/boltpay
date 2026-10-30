-- 0110: moderator system removed. Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); a uuid := gen_random_uuid(); o uuid := gen_random_uuid(); pid uuid;
begin
  assert to_regclass('public.moderator_assignments') is null, 'assignments table gone';
  assert not exists (select 1 from pg_proc where pronamespace='public'::regnamespace
    and (proname ~ '^staff_' or proname in ('is_moderator','handles_creator','admin_assign_creator','admin_list_staff'))), 'moderator fns gone';
  insert into auth.users(id, email) values (u,'nm-u@example.invalid'),(a,'nm-a@example.invalid'),(o,'nm-o@example.invalid');
  update profiles set role='admin' where id=a;
  begin update profiles set role='moderator' where id=u; raise exception 'moderator role allowed';
  exception when check_violation then null; end;
  perform set_config('test.uid', a::text, true);
  begin perform admin_set_role(u,'moderator'); raise exception 'set_role moderator allowed';
  exception when others then if sqlerrm like '%allowed' then raise; end if; end;
  insert into payments(id,user_id,backend,lnd_r_hash,amount_sats,expires_at,amount_requested,status)
    values (gen_random_uuid(),u,'lnd',md5(random()::text)||md5(random()::text),1000,now()+interval '1 hour',10,'new') returning id into pid;
  update payments set status='settled', amount_settled=10, settled_at=now() where id=pid;
  perform mark_payment(pid, 'ok');                          -- admin can mark
  perform set_config('test.uid', u::text, true);
  perform unmark_payment(pid);                              -- owner can unmark
  perform set_config('test.uid', o::text, true);
  begin perform mark_payment(pid); raise exception 'stranger marked';
  exception when others then if sqlerrm = 'stranger marked' then raise; end if; end;
  raise notice 'no-moderator regression OK';
end $$;
rollback;
