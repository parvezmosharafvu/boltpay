-- Per-link markup (0103). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); o uuid := gen_random_uuid(); a uuid := gen_random_uuid();
        lid uuid; r record; n int; bad boolean;
begin
  insert into auth.users(id, email) values (u, 'lm-test@example.invalid'), (o, 'lm-other@example.invalid'), (a, 'lm-admin@example.invalid');
  update profiles set account_status = 'active', max_payment_links = 50 where id in (u, o);
  update profiles set role = 'admin' where id = a;
  assert (select value from app_settings where key='link_markup_enabled') = 'false'::jsonb, 'flag defaults off';

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
  -- edit applies to whole group; clear with null
  select id into lid from payment_links where slug = 'lm-twelve';
  perform set_link_markup(lid, 7);
  select count(*) into n from payment_links where display_name = 'Lm Twelve' and cost_percent = 7;
  assert n = 2, 'edit applies to group';
  perform set_link_markup(lid, null);
  select count(*) into n from payment_links where display_name = 'Lm Twelve' and cost_percent is null;
  assert n = 2, 'clear';
  -- other user cannot edit
  perform set_config('test.uid', o::text, true);
  bad := false;
  begin perform set_link_markup(lid, 5); exception when others then bad := true; end;
  assert bad, 'non-owner rejected';
  -- non-admin cannot change range/flag
  bad := false;
  begin perform admin_set_link_markup_enabled(true); exception when others then bad := true; end;
  assert bad, 'non-admin flag rejected';
  -- admin narrows range; creator then limited
  perform set_config('test.uid', a::text, true);
  perform admin_set_link_markup_range(5, 15);
  perform set_config('test.uid', u::text, true);
  bad := false;
  begin perform set_link_markup(lid, 20); exception when others then bad := true; end;
  assert bad, 'outside new range rejected';
  perform set_link_markup(lid, 15);
  select count(*) into n from audit_log where action in ('link_markup_range', 'link.cost_percent_changed');
  assert n >= 2, 'audited';
end $$;
rollback;
