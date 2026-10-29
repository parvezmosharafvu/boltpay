-- 0080: Admin "Payment Methods", like paycashapp.site /admin/payment-methods.
-- Table-driven list of withdrawal methods. Defaults: lightning + usdt_bep20
-- enabled; legacy bkash/nagad/binance/bank disabled. Disabled methods are
-- hidden in the creator dashboard and rejected for NEW withdrawal rows.
-- Never shown on public pages. Existing withdrawals are untouched.
create table if not exists withdrawal_methods (
  code text primary key check (code in ('lightning','usdt_bep20','binance','bkash','nagad','bank')),
  label_en text not null,
  label_bn text not null,
  enabled boolean not null default false,
  sort int not null default 100,
  updated_at timestamptz not null default now()
);
insert into withdrawal_methods (code, label_en, label_bn, enabled, sort) values
  ('lightning',  'Lightning',      'লাইটনিং',        true,  10),
  ('usdt_bep20', 'USDT BEP20',     'USDT BEP20',     true,  20),
  ('binance',    'Binance Pay ID', 'বাইন্যান্স পে',     false, 30),
  ('bkash',      'bKash',          'বিকাশ',           false, 40),
  ('nagad',      'Nagad',          'নগদ',             false, 50),
  ('bank',       'Bank',           'ব্যাংক',           false, 60)
on conflict (code) do nothing;
alter table withdrawal_methods enable row level security;
revoke all on withdrawal_methods from anon, authenticated;

-- Signed-in creators only (not anon): the enabled list for the dashboard.
create or replace function list_enabled_withdrawal_methods()
returns table (code text, label_en text, label_bn text)
language sql security definer stable set search_path = public
as $$ select code, label_en, label_bn from withdrawal_methods
      where enabled and auth.uid() is not null order by sort $$;

create or replace function admin_list_withdrawal_methods()
returns table (code text, label_en text, label_bn text, enabled boolean, sort int, updated_at timestamptz)
language plpgsql security definer stable set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query select w.code, w.label_en, w.label_bn, w.enabled, w.sort, w.updated_at
               from withdrawal_methods w order by w.sort;
end $$;

create or replace function admin_set_withdrawal_method(p_code text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public
as $$
declare v_old boolean;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  select enabled into v_old from withdrawal_methods where code = p_code for update;
  if not found then raise exception 'Unknown method'; end if;
  update withdrawal_methods set enabled = p_enabled, updated_at = now() where code = p_code;
  perform record_audit('withdrawal_method_set', 'withdrawal_method', p_code,
    jsonb_build_object('enabled', v_old), jsonb_build_object('enabled', p_enabled), null);
end $$;

create or replace function enforce_withdrawal_method_enabled()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from withdrawal_methods where code = new.method and enabled) then
    raise exception 'Withdrawal method % is not available', new.method;
  end if;
  return new;
end $$;
drop trigger if exists withdrawals_method_enabled on withdrawals;
create trigger withdrawals_method_enabled before insert on withdrawals
  for each row execute function enforce_withdrawal_method_enabled();

revoke all on function list_enabled_withdrawal_methods() from public, anon;
revoke all on function admin_list_withdrawal_methods() from public, anon;
revoke all on function admin_set_withdrawal_method(text, boolean) from public, anon;
revoke all on function enforce_withdrawal_method_enabled() from public, anon, authenticated;
grant execute on function list_enabled_withdrawal_methods() to authenticated;
grant execute on function admin_list_withdrawal_methods() to authenticated;
grant execute on function admin_set_withdrawal_method(text, boolean) to authenticated;
