-- 0118: remove the node withdraw daily cap (owner decision).
--
-- Redefines system_node_withdraw_reserve without the rolling 24h cap check
-- and deletes the now-unused node_withdraw_daily_cap_sat setting.
-- Unchanged: node_withdraw_enabled flag, owner + admin check, the
-- node_withdraw_max_fee_sat guard, request_key idempotency, audit_log, the
-- step-up code (0113) and service_role-only grants.

create or replace function public.system_node_withdraw_reserve(
  p_actor uuid, p_kind text, p_destination text,
  p_amount_sat bigint, p_fee_limit_sat bigint, p_request_key text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_enabled boolean; v_owner text; v_max_fee bigint; v_id bigint; v_email text;
begin
  -- One reservation at a time, so a retried request_key cannot insert twice.
  perform pg_advisory_xact_lock(hashtext('node_withdraw_reserve'));

  select id into v_id from node_withdrawals where request_key = p_request_key;
  if v_id is not null then
    if not exists (select 1 from node_withdrawals where id = v_id and actor_id = p_actor
                   and kind = p_kind and destination = p_destination and amount_sat = p_amount_sat) then
      raise exception 'request_key reused with different details';
    end if;
    return v_id;
  end if;

  select (value = 'true'::jsonb) into v_enabled from app_settings where key = 'node_withdraw_enabled';
  if not coalesce(v_enabled, false) then raise exception 'node withdraw is disabled'; end if;

  select value #>> '{}' into v_owner from app_settings where key = 'node_withdraw_owner_id';
  if v_owner is null or p_actor is null or v_owner <> p_actor::text then
    raise exception 'Not authorized';
  end if;
  if not exists (select 1 from profiles where id = p_actor and role = 'admin') then
    raise exception 'Not authorized';
  end if;

  if p_kind not in ('onchain', 'lightning') then raise exception 'bad kind'; end if;
  if p_amount_sat is null or p_amount_sat <= 0 then raise exception 'bad amount'; end if;

  select (value #>> '{}')::bigint into v_max_fee from app_settings where key = 'node_withdraw_max_fee_sat';
  if p_fee_limit_sat is null or p_fee_limit_sat < 0 or p_fee_limit_sat > coalesce(v_max_fee, 0) then
    raise exception 'fee limit above node_withdraw_max_fee_sat';
  end if;

  insert into node_withdrawals(actor_id, kind, destination, amount_sat, fee_limit_sat, request_key)
  values (p_actor, p_kind, p_destination, p_amount_sat, p_fee_limit_sat, p_request_key)
  returning id into v_id;

  select email into v_email from profiles where id = p_actor;
  insert into audit_log(actor_id, actor_email, action, subject_type, subject_id, new_value)
  values (p_actor, v_email, 'node_withdraw.reserve', 'node_withdrawal', v_id::text,
          jsonb_build_object('kind', p_kind, 'destination', p_destination,
                             'amount_sat', p_amount_sat, 'fee_limit_sat', p_fee_limit_sat));
  return v_id;
end;
$$;
revoke all on function public.system_node_withdraw_reserve(uuid, text, text, bigint, bigint, text) from public, anon, authenticated;
grant execute on function public.system_node_withdraw_reserve(uuid, text, text, bigint, bigint, text) to service_role;

delete from public.app_settings where key = 'node_withdraw_daily_cap_sat';
