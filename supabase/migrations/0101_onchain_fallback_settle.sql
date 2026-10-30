-- 0101: on-chain fallback settlement for LND invoices (owner pt297u).
-- When lnd_onchain_fallback is on, each invoice also gets its own LND
-- address. lnd-watcher / payment-status check that address on a public
-- explorer and, once a confirmed payment of at least amount_sats minus 0.5%
-- arrives, call this function. Same credit as Lightning: amount_settled =
-- amount_requested. Idempotent under a row lock; a row already settled
-- (e.g. paid by Lightning first) returns false and changes nothing.
-- An invoice that expired on Lightning can still settle on-chain for 3 days.
alter table payments add column if not exists onchain_txid text;
alter table payments add column if not exists onchain_received_sats bigint;

create or replace function system_settle_onchain_payment(p_id uuid, p_txid text, p_received_sats bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay payments;
begin
  select * into v_pay from payments where id = p_id and backend = 'lnd' for update;
  if not found or v_pay.btc_address is null then
    return false;
  end if;
  if v_pay.status not in ('new','pending','expired') then
    return false;
  end if;
  if v_pay.status = 'expired' and v_pay.expires_at < now() - interval '3 days' then
    return false;
  end if;
  if p_txid !~ '^[0-9a-f]{64}$' then
    raise exception 'bad txid';
  end if;
  if p_received_sats is null
     or p_received_sats < v_pay.amount_sats - floor(v_pay.amount_sats * 0.005) then
    raise exception 'on-chain payment % underpaid: % sat < % sat', v_pay.id, p_received_sats, v_pay.amount_sats;
  end if;
  update payments
     set status = 'settled',
         amount_settled = amount_requested,
         settled_at = now(),
         paid_at = now(),
         onchain_txid = p_txid,
         onchain_received_sats = p_received_sats
   where id = v_pay.id;
  return true;
end;
$$;
revoke all on function system_settle_onchain_payment(uuid, text, bigint) from public, anon, authenticated;
grant execute on function system_settle_onchain_payment(uuid, text, bigint) to service_role;

-- Turn the fallback on (reversible: set it back to false).
insert into app_settings(key, value) values ('lnd_onchain_fallback', 'true'::jsonb)
on conflict (key) do update set value = 'true'::jsonb, updated_at = now();
