-- One BDT rate per user (taka per USD) plus a global fallback, replacing the
-- buy_rate/sell_rate pair. profiles.buy_rate/sell_rate and the
-- app_settings 'exchange_rates' row are kept untouched as an archive.
-- Rates below 50 are not real BDT rates (e.g. the 1.067 / 1 seeds) and
-- migrate to NULL, shown as "BDT rate not set".
alter table profiles add column if not exists bdt_rate numeric(10,3)
  check (bdt_rate is null or bdt_rate >= 50);
update profiles set bdt_rate = sell_rate where bdt_rate is null and sell_rate >= 50;

insert into app_settings(key, value)
select 'bdt_rate', jsonb_build_object('rate',
  (select case when (value->>'sell_rate')::numeric >= 50 then (value->>'sell_rate')::numeric end
     from app_settings where key = 'exchange_rates'))
on conflict (key) do nothing;

-- The user's rate, else the global fallback, else NULL (not set).
create or replace function withdrawal_rate_for(p_user uuid)
returns numeric language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select bdt_rate from profiles where id = p_user),
    (select nullif(value->>'rate', '')::numeric from app_settings where key = 'bdt_rate'))
$$;
revoke all on function withdrawal_rate_for(uuid) from public, anon, authenticated;

-- A BDT payout with no rate is refused rather than guessed.
create or replace function withdrawal_payout_snapshot()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_on boolean; v_cur text; v_rate numeric;
begin
  select coalesce((value->>'enabled')::boolean, false) into v_on
    from app_settings where key = 'withdrawal_bdt_pricing';
  select currency into v_cur from withdrawal_methods where code = new.method;
  if coalesce(v_on, false) and v_cur = 'BDT' then
    v_rate := withdrawal_rate_for(new.user_id);
    if v_rate is null then
      raise exception 'BDT rate not set for your account. Please contact support. · আপনার অ্যাকাউন্টে BDT রেট সেট করা নেই। সাপোর্টে যোগাযোগ করুন।'
        using errcode = 'P0001';
    end if;
    new.payout_currency := 'BDT';
    new.payout_rate := v_rate;
  else
    new.payout_currency := 'USD';
    new.payout_rate := 1;
  end if;
  new.payout_amount := round(coalesce(new.amount_after_fee, new.amount_requested) * new.payout_rate, 2);
  return new;
end $$;
revoke all on function withdrawal_payout_snapshot() from public, anon, authenticated;

-- {bdtRate}: the creator's own effective rate (NULL = not set).
create or replace function get_my_withdrawal_rate()
returns numeric language sql stable security definer set search_path = public
as $$ select case when auth.uid() is not null then withdrawal_rate_for(auth.uid()) end $$;
revoke all on function get_my_withdrawal_rate() from public, anon;
grant execute on function get_my_withdrawal_rate() to authenticated;

create or replace function admin_set_bdt_rate(p_user_id uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = public
as $$
declare v_old numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_rate is not null and (p_rate < 50 or p_rate > 1000) then raise exception 'BDT rate must be between 50 and 1000'; end if;
  select bdt_rate into v_old from profiles where id = p_user_id for update;
  if not found then raise exception 'Unknown user'; end if;
  update profiles set bdt_rate = p_rate where id = p_user_id;
  perform record_audit('bdt_rate', 'profile', p_user_id::text,
    jsonb_build_object('bdt_rate', v_old), jsonb_build_object('bdt_rate', p_rate), null);
end $$;
revoke all on function admin_set_bdt_rate(uuid, numeric) from public, anon;
grant execute on function admin_set_bdt_rate(uuid, numeric) to authenticated;

create or replace function admin_set_global_bdt_rate(p_rate numeric)
returns void language plpgsql security definer set search_path = public
as $$
declare v_old jsonb;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_rate is not null and (p_rate < 50 or p_rate > 1000) then raise exception 'BDT rate must be between 50 and 1000'; end if;
  select value into v_old from app_settings where key = 'bdt_rate';
  insert into app_settings(key, value) values ('bdt_rate', jsonb_build_object('rate', p_rate))
    on conflict (key) do update set value = excluded.value;
  perform record_audit('bdt_rate_global', 'app_settings', 'bdt_rate',
    v_old, jsonb_build_object('rate', p_rate), null);
end $$;
revoke all on function admin_set_global_bdt_rate(numeric) from public, anon;
grant execute on function admin_set_global_bdt_rate(numeric) to authenticated;
