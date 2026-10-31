-- 0120: Enforce one outgoing Lightning reservation per payment hash, regardless
-- of requestKey, to prevent duplicate sends across separate browser sessions.
-- Fail closed, never re-use a hash even when previous status is FAILED.
-- The legacy on-chain reserve RPC is unchanged and on-chain send stays paused.
alter table public.node_withdrawals
  add column if not exists payment_hash text
  constraint node_withdrawals_payment_hash_format
  check (payment_hash is null or payment_hash ~ '^[0-9a-f]{64}$');
create unique index if not exists node_withdrawals_unique_lightning_hash
  on public.node_withdrawals(payment_hash) where payment_hash is not null;
-- Existing historical rows, if any, must be backfilled/reconciled manually
-- before enabling outgoing transfers. The feature remains OFF.

create or replace function public.system_node_withdraw_reserve_payment(
  p_actor uuid, p_kind text, p_destination text,
  p_amount_sat bigint, p_fee_limit_sat bigint, p_request_key text, p_payment_hash text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_enabled boolean; v_owner text; v_max_fee bigint; v_id bigint; v_email text;
begin
  -- A payment hash is globally unique per outgoing Lightning invoice.
  if p_kind <> 'lightning' or p_payment_hash !~ '^[0-9a-f]{64}
  perform pg_advisory_xact_lock(hashtext('node_withdraw_reserve'));

  -- Always refuse a reused key before any LND send. Returning the prior
  -- reservation would let the Edge Function send a SECOND payment under
  -- the same id, even if the earlier attempt already moved funds.
  select id into v_id from node_withdrawals
  where request_key = p_request_key or payment_hash = p_payment_hash;
  if v_id is not null then
    raise exception 'duplicate payment hash or request_key: prior outcome must be reconciled; do not retry';
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

  insert into node_withdrawals(actor_id, kind, destination, amount_sat, fee_limit_sat, request_key, payment_hash)
  values (p_actor, p_kind, p_destination, p_amount_sat, p_fee_limit_sat, p_request_key, p_payment_hash)
  returning id into v_id;

  select email into v_email from profiles where id = p_actor;
  insert into audit_log(actor_id, actor_email, action, subject_type, subject_id, new_value)
  values (p_actor, v_email, 'node_withdraw.reserve', 'node_withdrawal', v_id::text,
          jsonb_build_object('kind', p_kind, 'destination', p_destination,
                             'amount_sat', p_amount_sat, 'fee_limit_sat', p_fee_limit_sat));
  return v_id;
end;
$$;
revoke all on function public.system_node_withdraw_reserve_payment(uuid, text, text, bigint, bigint, text, text) from public, anon, authenticated;
grant execute on function public.system_node_withdraw_reserve_payment(uuid, text, text, bigint, bigint, text, text) to service_role;

 then
    raise exception 'bad Lightning payment hash';
  end if;
  -- One reservation at a time, so both request-key and hash races are serialized.
  perform pg_advisory_xact_lock(hashtext('node_withdraw_reserve'));

  -- Always refuse a reused key before any LND send. Returning the prior
  -- reservation would let the Edge Function send a SECOND payment under
  -- the same id, even if the earlier attempt already moved funds.
  select id into v_id from node_withdrawals where request_key = p_request_key;
  if v_id is not null then
    raise exception 'duplicate request_key: prior outcome must be reconciled; do not retry';
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
revoke all on function public.system_node_withdraw_reserve_payment(uuid, text, text, bigint, bigint, text, text) from public, anon, authenticated;
grant execute on function public.system_node_withdraw_reserve_payment(uuid, text, text, bigint, bigint, text, text) to service_role;

