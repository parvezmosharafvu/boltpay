-- Runtime checks for 0101 (on-chain fallback settle). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id, email) values ('44444444-4444-4444-4444-444444444444', 'oc@test.invalid');
do $$
declare v_id uuid; v_id2 uuid; v_ok boolean; v_tx text := repeat('cd', 32); r payments;
begin
  insert into payments(user_id, backend, lnd_r_hash, amount_sats, amount_requested, status, expires_at, btc_address)
  values ('44444444-4444-4444-4444-444444444444', 'lnd', repeat('01', 32), 14015, 11, 'new', now() + interval '1 hour', 'bc1qtestaddr')
  returning id into v_id;
  begin perform system_settle_onchain_payment(v_id, v_tx, 13944); raise exception 'underpay accepted';
  exception when raise_exception then if sqlerrm = 'underpay accepted' then raise; end if; end;
  begin perform system_settle_onchain_payment(v_id, 'nothex', 14015); raise exception 'bad txid accepted';
  exception when raise_exception then if sqlerrm = 'bad txid accepted' then raise; end if; end;
  v_ok := system_settle_onchain_payment(v_id, v_tx, 13945);  -- within 0.5%
  if not v_ok then raise exception 'tolerance settle failed'; end if;
  select * into r from payments where id = v_id;
  if r.status <> 'settled' or r.amount_settled <> 11 or r.onchain_txid <> v_tx then raise exception 'row %', r.status; end if;
  if system_settle_onchain_payment(v_id, v_tx, 14015) then raise exception 'double credit'; end if;
  -- Lightning-expired row: ok within 3 days, refused after
  insert into payments(user_id, backend, lnd_r_hash, amount_sats, amount_requested, status, expires_at, btc_address)
  values ('44444444-4444-4444-4444-444444444444', 'lnd', repeat('02', 32), 1000, 11, 'expired', now() - interval '4 days', 'bc1qtestaddr2')
  returning id into v_id2;
  if system_settle_onchain_payment(v_id2, v_tx, 1000) then raise exception 'stale expired settled'; end if;
  update payments set expires_at = now() - interval '2 hours' where id = v_id2;
  if not system_settle_onchain_payment(v_id2, v_tx, 1000) then raise exception 'late onchain refused'; end if;
  -- No address: never
  insert into payments(user_id, backend, lnd_r_hash, amount_sats, amount_requested, status, expires_at)
  values ('44444444-4444-4444-4444-444444444444', 'lnd', repeat('03', 32), 1000, 11, 'new', now() + interval '1 hour')
  returning id into v_id2;
  if system_settle_onchain_payment(v_id2, v_tx, 1000) then raise exception 'no-address settled'; end if;
  if has_function_privilege('anon', 'system_settle_onchain_payment(uuid,text,bigint)', 'execute') then raise exception 'anon can execute'; end if;
end $$;
rollback;
