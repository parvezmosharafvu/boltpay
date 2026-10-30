-- Runtime checks for 0067 (LND backend). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
-- 0104: isolate from the conversion fee (own test: conversion_fee_regression.sql)
update app_settings set value = '0'::jsonb where key = 'conversion_fee_percent';
select '33333333-3333-3333-3333-333333333333'::uuid as creator_id \gset
insert into auth.users(id, email) values (:'creator_id', 'lnd-creator@test.invalid');
update profiles set email = 'lnd-creator@test.invalid', role = 'creator' where id = :'creator_id';
insert into payment_links(user_id, slug, display_name, is_active) values (:'creator_id', 'LndTestLink', 'Lnd Test', true);

do $$
declare v_flag jsonb; v_backend text; v_n int; v_hash text := repeat('ab', 32); v_ok boolean; v_status text;
begin
  -- Flags default OFF / conservative
  select value into v_flag from app_settings where key = 'lnd_checkout_enabled';
  if v_flag is distinct from 'false'::jsonb then raise exception 'lnd_checkout_enabled is not false'; end if;
  select value into v_flag from app_settings where key = 'lnd_onchain_fallback';
  -- 0101 turns the on-chain fallback on (owner pt297u)
  if v_flag is distinct from 'true'::jsonb then raise exception 'lnd_onchain_fallback is not true'; end if;
  if (select value from app_settings where key = 'lnd_pay_min_usd') <> '10'::jsonb then raise exception 'min'; end if;
  if (select value from app_settings where key = 'lnd_pay_max_usd') <> '1000'::jsonb then raise exception 'max'; end if;
  if (select value from app_settings where key = 'lnd_invoice_expiry_sec') <> '3600'::jsonb then raise exception 'expiry'; end if;

  -- Links default to lnd
  select checkout_backend into v_backend from payment_links where slug = 'LndTestLink';
  if v_backend <> 'lnd' then raise exception 'link backend default is %', v_backend; end if;

  -- An LND row without its hash is rejected
  begin
    insert into payments(user_id, backend, amount_requested, status, expires_at)
    values ('33333333-3333-3333-3333-333333333333', 'lnd', 10, 'new', now() + interval '1 hour');
    raise exception 'lnd row without hash accepted';
  exception when check_violation then null;
  end;

  -- Valid LND row
  insert into payments(user_id, backend, lnd_r_hash, amount_sats, amount_requested, status, expires_at)
  values ('33333333-3333-3333-3333-333333333333', 'lnd', v_hash, 10000, 10.5, 'new', now() + interval '1 hour');

  -- Underpaid is refused
  begin
    perform system_settle_lnd_payment(v_hash, 9999000);
    raise exception 'underpay accepted';
  exception when others then
    if sqlerrm = 'underpay accepted' then raise; end if;
  end;

  -- Settles once, second call is a no-op
  v_ok := system_settle_lnd_payment(v_hash, 10000000);
  if not v_ok then raise exception 'first settle returned false'; end if;
  v_ok := system_settle_lnd_payment(v_hash, 10000000);
  if v_ok then raise exception 'second settle returned true'; end if;
  select status into v_status from payments where lnd_r_hash = v_hash;
  if v_status <> 'settled' then raise exception 'status %', v_status; end if;
  if (select amount_settled from payments where lnd_r_hash = v_hash) <> 10.5 then raise exception 'amount_settled'; end if;

  -- A settled row is never expired
  if system_expire_lnd_payment(v_hash) then raise exception 'settled row expired'; end if;

  -- Expired row cannot be settled
  insert into payments(user_id, backend, lnd_r_hash, amount_sats, amount_requested, status, expires_at)
  values ('33333333-3333-3333-3333-333333333333', 'lnd', repeat('cd', 32), 5000, 5, 'new', now());
  if not system_expire_lnd_payment(repeat('cd', 32)) then raise exception 'expire failed'; end if;
  if system_settle_lnd_payment(repeat('cd', 32), 5000000) then raise exception 'expired row settled'; end if;

  -- Settle ignores an unknown hash
  if system_settle_lnd_payment(repeat('ef', 32), 1) then raise exception 'unknown hash settled'; end if;

  -- Client roles cannot call the system functions or read payment_events
  if has_function_privilege('anon', 'system_settle_lnd_payment(text,bigint)', 'execute') then raise exception 'anon can settle'; end if;
  if has_function_privilege('authenticated', 'system_settle_lnd_payment(text,bigint)', 'execute') then raise exception 'auth can settle'; end if;
  if has_function_privilege('anon', 'system_lnd_link_for_invoice(text)', 'execute') then raise exception 'anon can lookup'; end if;
  if has_table_privilege('anon', 'payment_events', 'select') then raise exception 'anon reads events'; end if;
  if has_table_privilege('authenticated', 'payment_events', 'insert') then raise exception 'auth writes events'; end if;
end $$;
rollback;
select 'LND 0067 runtime checks passed' as result;
