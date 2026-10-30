-- Custom domains (0093). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
do $$
declare u uuid := gen_random_uuid(); v uuid := gen_random_uuid(); info jsonb;
begin
  assert (select value from app_settings where key='custom_domains_enabled') = 'false'::jsonb, 'flag defaults to false';
  insert into auth.users(id, email) values (u, 'cd-owner@example.invalid'), (v, 'cd-other@example.invalid');
  update profiles set display_name = 'Rose Store' where id = u;
  insert into payment_links(user_id, slug) values (u, 'cdowner1'), (v, 'cdother1');
  insert into site_domains(hostname, purpose) values ('platform.example.invalid', 'both');
  insert into site_domains(hostname, purpose, kind, owner_id, status, is_active)
    values ('pay.rose.example.invalid', 'both', 'custom', u, 'pending', false);
  -- Not active yet: no branding, every slug allowed (unchanged behaviour).
  assert domain_info('pay.rose.example.invalid') is null, 'pending domain must not brand';
  assert custom_domain_allows_slug('pay.rose.example.invalid', 'cdother1'), 'pending domain does not restrict';
  update site_domains set status='active', is_active=true where hostname='pay.rose.example.invalid';
  info := domain_info('PAY.rose.example.invalid');
  assert info->>'brand_name' = 'Rose Store', format('brand from display name: %s', info);
  assert custom_domain_allows_slug('pay.rose.example.invalid', 'cdowner1'), 'own link allowed';
  assert not custom_domain_allows_slug('pay.rose.example.invalid', 'cdother1'), 'other user link blocked';
  assert custom_domain_allows_slug('platform.example.invalid', 'cdother1'), 'platform host unchanged';
  assert custom_domain_allows_slug('unknown.example.invalid', 'cdother1'), 'unknown host unchanged';
  assert domain_info('platform.example.invalid') is null, 'platform host has no white-label info';
  begin
    insert into site_domains(hostname, kind, status) values ('noowner.example.invalid', 'custom', 'pending');
    raise exception 'custom domain without owner must fail';
  exception when check_violation then null;
  end;
end $$;
rollback;
