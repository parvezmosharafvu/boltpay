-- 0112: Owner-only node withdrawal — schema, flags and guard functions.
--
-- Nothing here moves money. This adds the bookkeeping the future
-- node-withdraw edge function will call around its LND request:
--   * app_settings flags     node_withdraw_enabled      = false (OFF)
--                            node_withdraw_daily_cap_sat = 50000 (rolling 24h)
--                            node_withdraw_max_fee_sat   = 2000
--                            node_withdraw_owner_id      = null (no owner => nobody)
--   * node_withdrawals       one row per send attempt; no client access
--   * system_lnd_withdraw_config()   Vault reader for the URI-scoped
--                            withdraw macaroon (secret 'lnd_withdraw_macaroon').
--                            Never admin.macaroon. Secrets are added to Vault
--                            separately and never live in the repo.
--   * system_node_withdraw_reserve() flag + owner + daily cap + idempotency,
--                            inserts a 'reserved' row and an audit_log entry
--   * system_node_withdraw_finish()  marks sent / failed, audit_log entry
-- All functions are SECURITY DEFINER and executable by service_role only.
--
-- Revert:
--   drop function if exists public.system_node_withdraw_finish(bigint, text, text, bigint, text);
--   drop function if exists public.system_node_withdraw_reserve(uuid, text, text, bigint, bigint, text);
--   drop function if exists public.system_lnd_withdraw_config();
--   drop table if exists public.node_withdrawals;
--   delete from app_settings where key like 'node_withdraw_%';

insert into app_settings (key, value) values
  ('node_withdraw_enabled',       'false'::jsonb),
  ('node_withdraw_daily_cap_sat', '50000'::jsonb),
  ('node_withdraw_max_fee_sat',   '2000'::jsonb),
  ('node_withdraw_owner_id',      'null'::jsonb)
on conflict (key) do nothing;

create table if not exists public.node_withdrawals (
  id            bigserial primary key,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  actor_id      uuid not null references profiles(id),
  kind          text not null check (kind in ('onchain', 'lightning')),
  destination   text not null check (length(destination) between 14 and 2000),
  amount_sat    bigint not null check (amount_sat > 0),
  fee_limit_sat bigint not null check (fee_limit_sat >= 0),
  fee_sat       bigint check (fee_sat >= 0),
  status        text not null default 'reserved' check (status in ('reserved', 'sent', 'failed')),
  reference     text,          -- txid or payment hash; never a preimage or secret
  error         text,
  request_key   text not null unique check (length(request_key) between 8 and 128)
);
create index if not exists idx_node_withdrawals_created on public.node_withdrawals(created_at desc);

alter table public.node_withdrawals enable row level security;
revoke all on table public.node_withdrawals from public, anon, authenticated;
revoke all on sequence public.node_withdrawals_id_seq from public, anon, authenticated;

create or replace function public.system_lnd_withdraw_config()
returns table (rest_url text, macaroon text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query select
    (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'lnd_rest_url' limit 1),
    (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'lnd_withdraw_macaroon' limit 1);
end;
$$;
revoke all on function public.system_lnd_withdraw_config() from public, anon, authenticated;
grant execute on function public.system_lnd_withdraw_config() to service_role;

-- Reserve room under the daily cap before calling LND. Idempotent on
-- p_request_key: a retry with the same key returns the same row id.
create or replace function public.system_node_withdraw_reserve(
  p_actor uuid, p_kind text, p_destination text,
  p_amount_sat bigint, p_fee_limit_sat bigint, p_request_key text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_enabled boolean; v_owner text; v_cap bigint; v_max_fee bigint;
  v_used bigint; v_id bigint; v_email text;
begin
  -- One reservation at a time, so two requests cannot both fit under the cap.
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

  select (value #>> '{}')::bigint into v_cap from app_settings where key = 'node_withdraw_daily_cap_sat';
  select coalesce(sum(amount_sat + coalesce(fee_sat, fee_limit_sat)), 0) into v_used
    from node_withdrawals
   where status in ('reserved', 'sent') and created_at > now() - interval '24 hours';
  if v_used + p_amount_sat + p_fee_limit_sat > coalesce(v_cap, 0) then
    raise exception 'daily cap exceeded';
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

-- Record the outcome. Only a 'reserved' row can move, and only once.
create or replace function public.system_node_withdraw_finish(
  p_id bigint, p_status text, p_reference text, p_fee_sat bigint, p_error text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_row node_withdrawals;
begin
  if p_status not in ('sent', 'failed') then raise exception 'bad status'; end if;
  update node_withdrawals
     set status = p_status, reference = p_reference, fee_sat = p_fee_sat,
         error = left(p_error, 500), updated_at = now()
   where id = p_id and status = 'reserved'
  returning * into v_row;
  if v_row.id is null then return false; end if;

  insert into audit_log(actor_id, actor_email, action, subject_type, subject_id, new_value)
  select v_row.actor_id, pr.email, 'node_withdraw.' || p_status, 'node_withdrawal', v_row.id::text,
         jsonb_build_object('reference', p_reference, 'fee_sat', p_fee_sat, 'amount_sat', v_row.amount_sat)
    from profiles pr where pr.id = v_row.actor_id;
  return true;
end;
$$;
revoke all on function public.system_node_withdraw_finish(bigint, text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.system_node_withdraw_finish(bigint, text, text, bigint, text) to service_role;
