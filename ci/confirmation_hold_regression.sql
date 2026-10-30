-- Confirmation hold (0087). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
do $$
declare u uuid := gen_random_uuid(); pid uuid; b0 numeric; b1 numeric;
begin
  insert into auth.users(id, email) values (u, 'hold-test@example.invalid');
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 50, 50, 'new') returning id into pid;
  update payments set status='settled', amount_settled=50, settled_at=now() where id=pid;
  select available into b0 from get_balance_for(u);
  assert b0 = 50, format('null confirmation must count as before: %s', b0);
  update payments set confirmation='held' where id=pid;
  select available into b1 from get_balance_for(u);
  assert b1 = 0, 'held payment must not be withdrawable';
  update payments set confirmation='confirmed' where id=pid;
  select available into b1 from get_balance_for(u);
  assert b1 = 50, 'confirmed payment counts';
  update payments set confirmation='rejected' where id=pid;
  select available into b1 from get_balance_for(u);
  assert b1 = 0, 'rejected payment excluded';
end $$;
rollback;
