-- 0121: daily settled link drill-down regression, in rollback transaction.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid language sql stable
as $uid$ select nullif(current_setting('test.uid', true), '')::uuid $uid$;

do $$
declare
  admin_id uuid := gen_random_uuid();
  creator_id uuid := gen_random_uuid();
  link_a uuid;
  link_b uuid;
  p1 uuid;
  p2 uuid;
  p3 uuid;
  p_outside uuid;
  p_open uuid;
  d date := ((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date - 1;
  start_at timestamptz;
  end_at timestamptz;
  r record;
  n int;
  settled numeric;
  blocked boolean := false;
begin
  start_at := (d::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka';
  end_at := start_at + interval '24 hours';
  insert into auth.users(id,email) values
    (admin_id,'daily-links-admin@example.invalid'),
    (creator_id,'daily-links-creator@example.invalid');
  update profiles set role='admin' where id=admin_id;
  insert into payment_links(user_id,slug,display_name) values
    (creator_id,'DailyLinksA','Daily Links A') returning id into link_a;
  insert into payment_links(user_id,slug,display_name) values
    (creator_id,'DailyLinksB','Daily Links B') returning id into link_b;

  insert into payments(user_id,payment_link_id,backend,lnd_r_hash,amount_sats,amount_requested,status,expires_at)
    values (creator_id,link_a,'lnd',md5(random()::text)||md5(random()::text),1000,25.25,'new',now()+interval '1 hour')
    returning id into p1;
  insert into payments(user_id,payment_link_id,backend,lnd_r_hash,amount_sats,amount_requested,status,expires_at)
    values (creator_id,link_a,'lnd',md5(random()::text)||md5(random()::text),1000,10.00,'new',now()+interval '1 hour')
    returning id into p2;
  insert into payments(user_id,payment_link_id,backend,lnd_r_hash,amount_sats,amount_requested,status,expires_at)
    values (creator_id,link_b,'lnd',md5(random()::text)||md5(random()::text),1000,12.10,'new',now()+interval '1 hour')
    returning id into p3;
  insert into payments(user_id,payment_link_id,backend,lnd_r_hash,amount_sats,amount_requested,status,expires_at)
    values (creator_id,link_b,'lnd',md5(random()::text)||md5(random()::text),1000,99.00,'new',now()+interval '1 hour')
    returning id into p_outside;
  insert into payments(user_id,payment_link_id,backend,lnd_r_hash,amount_sats,amount_requested,status,expires_at)
    values (creator_id,link_a,'lnd',md5(random()::text)||md5(random()::text),1000,77.00,'new',now()+interval '1 hour')
    returning id into p_open;

  update payments set status='settled', settled_at=start_at, amount_settled=25.25 where id=p1;
  update payments set status='settled', settled_at=end_at-interval '1 second', amount_settled=10.00 where id=p2;
  update payments set status='settled', settled_at=start_at+interval '1 hour', amount_settled=12.10 where id=p3;
  update payments set status='settled', settled_at=end_at, amount_settled=99.00 where id=p_outside;

  -- A soft-deleted link must still appear in historic financial records.
  update payment_links set deleted_at=now() where id=link_a;
  perform set_config('test.uid',admin_id::text,true);

  select count(*),coalesce(sum(v.total_settled),0) into n,settled
  from admin_daily_settled_link_details(d) v;
  assert n=2, format('expected 2 links, got %s',n);
  assert settled=47.35, format('expected 47.35, got %s',settled);

  select * into r from admin_daily_settled_link_details(d) where link_id=link_a;
  assert r.payment_count=2 and r.total_settled=35.25, 'link A count and sum';
  assert jsonb_array_length(r.payments)=2, 'link A individual payment amount rows';
  assert exists(select 1 from jsonb_array_elements(r.payments) e where (e->>'amount')::numeric=25.25), 'link A first amount';
  assert exists(select 1 from jsonb_array_elements(r.payments) e where (e->>'amount')::numeric=10), 'link A second amount';
  assert r.slug='DailyLinksA', 'deleted link retains slug';

  select * into r from admin_daily_settled_link_details(d) where link_id=link_b;
  assert r.payment_count=1 and r.total_settled=12.10, 'link B count and sum';
  assert jsonb_array_length(r.payments)=1, 'link B individual payment row';

  perform set_config('test.uid',creator_id::text,true);
  begin
    perform admin_daily_settled_link_details(d);
  exception when others then
    blocked := sqlerrm='Not authorized';
  end;
  assert blocked, 'creator was able to read admin-only link breakdown';
end $$;
rollback;
