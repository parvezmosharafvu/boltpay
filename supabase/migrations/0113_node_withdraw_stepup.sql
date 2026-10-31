-- 0113: step-up codes for owner-only node withdraw spends.
--
-- The node-withdraw edge function makes a random 6-digit code, sends it to
-- the admin Telegram, and stores only HMAC(code, request_hash). request_hash
-- is a SHA-256 of the canonical spend (action, destination, amount, fee
-- rate, fee limit), so a code only works for that exact spend.
--   * expires 5 minutes after it is issued
--   * at most 5 wrong attempts, then it is burned
--   * works once; a new request replaces any older unused code
--   * every issue / success / failure goes to audit_log
-- Service role only; no client grants.

create table if not exists public.node_withdraw_stepups (
  id           bigserial primary key,
  actor_id     uuid not null references auth.users(id),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  code_hash    text not null check (code_hash ~ '^[0-9a-f]{64}$'),
  attempts     int  not null default 0,
  expires_at   timestamptz not null default now() + interval '5 minutes',
  used_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists node_withdraw_stepups_actor on public.node_withdraw_stepups(actor_id, created_at desc);
alter table public.node_withdraw_stepups enable row level security;
revoke all on public.node_withdraw_stepups from public, anon, authenticated;

create or replace function public.system_node_withdraw_stepup_issue(p_actor uuid, p_request_hash text, p_code_hash text)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_owner text; v_id bigint; v_exp timestamptz;
begin
  if (select value from app_settings where key = 'node_withdraw_enabled') is distinct from 'true'::jsonb then
    raise exception 'node withdraw is disabled';
  end if;
  select value #>> '{}' into v_owner from app_settings where key = 'node_withdraw_owner_id';
  if v_owner is null or p_actor is null or v_owner <> p_actor::text
     or not exists (select 1 from profiles where id = p_actor and role = 'admin') then
    raise exception 'Not authorized';
  end if;
  perform pg_advisory_xact_lock(hashtext('node_withdraw_stepup'));
  -- one live code at a time
  update node_withdraw_stepups set used_at = now() where actor_id = p_actor and used_at is null;
  insert into node_withdraw_stepups(actor_id, request_hash, code_hash)
  values (p_actor, p_request_hash, p_code_hash) returning id, expires_at into v_id, v_exp;
  insert into audit_log(actor_id, actor_email, action, subject_type, subject_id, new_value)
  values (p_actor, (select email from profiles where id = p_actor), 'node_withdraw.stepup_issue',
          'node_withdraw_stepup', v_id::text, jsonb_build_object('request_hash', p_request_hash, 'expires_at', v_exp));
  return v_exp;
end;
$$;
revoke all on function public.system_node_withdraw_stepup_issue(uuid, text, text) from public, anon, authenticated;
grant execute on function public.system_node_withdraw_stepup_issue(uuid, text, text) to service_role;

-- Returns true once for the right code + request; false otherwise (and
-- counts the attempt). Never raises on a wrong code, so attempts persist.
create or replace function public.system_node_withdraw_stepup_consume(p_actor uuid, p_request_hash text, p_code_hash text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare r node_withdraw_stepups; v_ok boolean; v_reason text;
begin
  perform pg_advisory_xact_lock(hashtext('node_withdraw_stepup'));
  select * into r from node_withdraw_stepups
   where actor_id = p_actor and used_at is null
   order by created_at desc, id desc limit 1 for update;

  if r.id is null then v_ok := false; v_reason := 'no live code';
  elsif r.expires_at <= now() then
    update node_withdraw_stepups set used_at = now() where id = r.id;
    v_ok := false; v_reason := 'expired';
  elsif r.attempts >= 5 then
    update node_withdraw_stepups set used_at = now() where id = r.id;
    v_ok := false; v_reason := 'too many attempts';
  elsif r.request_hash <> coalesce(p_request_hash, '') or r.code_hash <> coalesce(p_code_hash, '') then
    update node_withdraw_stepups
       set attempts = attempts + 1,
           used_at = case when attempts + 1 >= 5 then now() else null end
     where id = r.id;
    v_ok := false;
    v_reason := case when r.request_hash <> coalesce(p_request_hash, '') then 'request mismatch' else 'wrong code' end;
  else
    update node_withdraw_stepups set used_at = now() where id = r.id;
    v_ok := true; v_reason := 'ok';
  end if;

  insert into audit_log(actor_id, actor_email, action, subject_type, subject_id, new_value)
  values (p_actor, (select email from profiles where id = p_actor),
          case when v_ok then 'node_withdraw.stepup_ok' else 'node_withdraw.stepup_fail' end,
          'node_withdraw_stepup', coalesce(r.id::text, ''),
          jsonb_build_object('reason', v_reason, 'request_hash', p_request_hash));
  return v_ok;
end;
$$;
revoke all on function public.system_node_withdraw_stepup_consume(uuid, text, text) from public, anon, authenticated;
grant execute on function public.system_node_withdraw_stepup_consume(uuid, text, text) to service_role;
