-- Per-link markup (0103, locked by 0105). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
-- 0104: isolate from the conversion fee (own test: conversion_fee_regression.sql)
update app_settings set value = '0'::jsonb where key = 'conversion_fee_percent';
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); o uuid := gen_random_uuid(); a uuid := gen_random_uuid();
        lid uuid; r record; n int; bad boolean;
begin
  insert into auth.users(id, email) values (u, 'lm-test@example.invalid'), (o, 'lm-other@example.invalid'), (a, 'lm-admin@example.invalid');
  update profiles set account_status = 'active', max_payment_links = 50 where id in (u, o);
  update profiles set role = 'admin' where id = a;
  assert (select value from app_settings where key='link_markup_enabled') = 'true'::jsonb, 'flag on (0105)';

  perform set_config('test.uid', u::text, true);
  -- no % given: null, falls back
  perform create_link_variants('Lm Plain', array['kebab','pascal']);
  select * into r from system_lnd_link_for_invoice('lm-plain');
  assert r.link_cost_percent is null, 'null link pct';
  -- with % for the whole group
  perform create_link_variants('Lm Twelve', array['kebab','pascal'], 12.345);
  select count(*) into n from payment_links where display_name = 'Lm Twelve' and cost_percent = 12.35;
  assert n = 2, format('both variants get pct, got %s', n);
  select * into r from system_lnd_link_for_invoice('LmTwelve');
  assert r.link_cost_percent = 12.35 and r.profile_cost_percent = 0, 'lookup returns pct';
  -- out of range rejected
  bad := false;
  begin perform create_link_variants('Lm Big', array['kebab'], 60); exception when others then bad := true; end;
  assert bad, 'above max rejected';
  select id into lid from payment_links where slug = 'lm-twelve';
  -- 0105: creator cannot change it after creation (rpc or direct update)
  bad := false;
  begin perform set_link_markup(lid, 7); exception when others then bad := true; end;
  assert bad, 'creator rpc edit rejected';
  bad := false;
  begin update payment_links set cost_percent = 1 where id = lid; exception when others then bad := true; end;
  assert bad, 'creator direct edit rejected';
  -- other fields still editable by the owner
  update payment_links set note = 'hi' where id = lid;
  -- non-admin cannot change range/flag
  perform set_config('test.uid', o::text, true);
  bad := false;
  begin perform admin_set_link_markup_enabled(true); exception when others then bad := true; end;
  assert bad, 'non-admin flag rejected';
  -- admin can edit (whole group) and narrow the range
  perform set_config('test.uid', a::text, true);
  perform set_link_markup(lid, 7);
  select count(*) into n from payment_links where display_name = 'Lm Twelve' and cost_percent = 7;
  assert n = 2, 'admin edit applies to group';
  perform admin_set_link_markup_range(5, 15);
  bad := false;
  begin perform set_link_markup(lid, 20); exception when others then bad := true; end;
  assert bad, 'outside new range rejected';
  -- lookup: link % else 0
  select * into r from system_lnd_link_for_invoice('lm-plain');
  assert r.cost_percent = 0, 'null link -> 0';
  select count(*) into n from audit_log where action in ('link_markup_range', 'link.cost_percent_changed');
  assert n >= 2, 'audited';
end $$;
rollback;
