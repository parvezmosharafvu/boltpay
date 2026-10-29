-- 0083: withdrawal methods priced in BDT or USD, like paycashapp.site (owner, pt254u).
-- The USD ledger (amount_requested, amount_after_fee) is unchanged. Each new
-- withdrawal snapshots payout_currency, payout_rate and payout_amount.
-- Rate: profiles.sell_rate when set (not the old default of 1), else the
-- global app_settings.exchange_rates.sell_rate. buy_rate/sell_rate are reused, nothing removed.
-- Flag app_settings 'withdrawal_bdt_pricing' {"enabled": false}: while off, every
-- withdrawal is USD at rate 1, exactly as before.

alter table withdrawal_methods add column if not exists currency text not null default 'USD';
alter table withdrawal_methods drop constraint if exists withdrawal_methods_currency_chk;
alter table withdrawal_methods add constraint withdrawal_methods_currency_chk check (currency in ('USD','BDT'));
update withdrawal_methods set currency = 'BDT' where code in ('bkash','nagad','bank');

alter table withdrawals add column if not exists payout_currency text not null default 'USD';
alter table withdrawals add column if not exists payout_rate numeric(12,4) not null default 1;
alter table withdrawals add column if not exists payout_amount numeric(18,2);

insert into app_settings(key, value) values ('withdrawal_bdt_pricing', '{"enabled": false}')
on conflict (key) do nothing;

create or replace function withdrawal_rate_for(p_user uuid)
returns numeric language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select nullif(nullif(sell_rate, 0), 1) from profiles where id = p_user),
    (select nullif((value->>'sell_rate')::numeric, 0) from app_settings where key = 'exchange_rates'),
    1)
$$;
revoke all on function withdrawal_rate_for(uuid) from public, anon, authenticated;

create or replace function withdrawal_payout_snapshot()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_on boolean; v_cur text;
begin
  select coalesce((value->>'enabled')::boolean, false) into v_on
    from app_settings where key = 'withdrawal_bdt_pricing';
  select currency into v_cur from withdrawal_methods where code = new.method;
  if coalesce(v_on, false) and v_cur = 'BDT' then
    new.payout_currency := 'BDT';
    new.payout_rate := withdrawal_rate_for(new.user_id);
  else
    new.payout_currency := 'USD';
    new.payout_rate := 1;
  end if;
  new.payout_amount := round(coalesce(new.amount_after_fee, new.amount_requested) * new.payout_rate, 2);
  return new;
end $$;
revoke all on function withdrawal_payout_snapshot() from public, anon, authenticated;
drop trigger if exists withdrawal_payout_snapshot on withdrawals;
create trigger withdrawal_payout_snapshot before insert on withdrawals
  for each row execute function withdrawal_payout_snapshot();

drop function if exists list_enabled_withdrawal_methods();
create function list_enabled_withdrawal_methods()
returns table (code text, label_en text, label_bn text, currency text)
language sql security definer stable set search_path = public
as $$ select code, label_en, label_bn, currency from withdrawal_methods
      where enabled and auth.uid() is not null order by sort $$;
revoke all on function list_enabled_withdrawal_methods() from public, anon;
grant execute on function list_enabled_withdrawal_methods() to authenticated;

-- The creator's own BDT rate, or null while the flag is off.
create or replace function get_my_withdrawal_rate()
returns numeric language sql stable security definer set search_path = public
as $$
  select case when auth.uid() is not null and coalesce((select (value->>'enabled')::boolean
           from app_settings where key = 'withdrawal_bdt_pricing'), false)
         then withdrawal_rate_for(auth.uid()) end
$$;
revoke all on function get_my_withdrawal_rate() from public, anon;
grant execute on function get_my_withdrawal_rate() to authenticated;

create or replace function admin_set_withdrawal_method_currency(p_code text, p_currency text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_old text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  select currency into v_old from withdrawal_methods where code = p_code for update;
  if not found then raise exception 'Unknown method'; end if;
  update withdrawal_methods set currency = p_currency, updated_at = now() where code = p_code;
  perform record_audit('withdrawal_method_currency', 'withdrawal_method', p_code,
    jsonb_build_object('currency', v_old), jsonb_build_object('currency', p_currency), null);
end $$;
revoke all on function admin_set_withdrawal_method_currency(text, text) from public, anon;
grant execute on function admin_set_withdrawal_method_currency(text, text) to authenticated;
