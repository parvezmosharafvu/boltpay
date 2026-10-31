-- 0117 (owner decision pt337u, Oct 31 2026):
-- 1) Cashout: creators withdraw their available balance in display (base-only)
--    dollars. request_withdrawal_display() converts the display amount to the
--    real ledger amount server-side (ratio = display earned / real earned, the
--    same ratio get_my_display_totals uses) and calls request_withdrawal(),
--    which still validates against the real available balance.
-- 2) The old per-creator platform commission system is gone: no global
--    platform_commission flag, no per-profile commission_enabled / flat /
--    cost_percent / withdrawal_fee_percent overrides. Everyone uses the global
--    defaults; creators always keep the link extra fee. Columns are kept
--    (still referenced by older functions / ledger-backup) but neutralised.
-- 3) Conversion fee mode default = buyer (setting + fallbacks).
-- Values changed here are backed up in fee_reset_backup_0117 / settings_backup_0117.

-- ---------- backups ----------
create table if not exists fee_reset_backup_0117 as
  select id, email, display_name, cost_percent, commission_enabled, commission_type,
         commission_flat_usd, withdrawal_fee_percent, now() as backed_up_at
  from profiles
  where coalesce(cost_percent, 0) <> 0 or commission_enabled is not null
     or coalesce(commission_type, 'percent') <> 'percent' or coalesce(commission_flat_usd, 0) <> 0
     or coalesce(withdrawal_fee_percent, 0) <> 0;
alter table fee_reset_backup_0117 enable row level security;
revoke all on fee_reset_backup_0117 from public, anon, authenticated;

create table if not exists settings_backup_0117 as
  select key, value, now() as backed_up_at from app_settings
  where key in ('platform_commission_enabled', 'default_withdrawal_fee_percent', 'conversion_fee_mode');
alter table settings_backup_0117 enable row level security;
revoke all on settings_backup_0117 from public, anon, authenticated;

-- ---------- 2) reset everyone to the global defaults ----------
update profiles set cost_percent = 0, commission_enabled = null, commission_type = 'percent',
                    commission_flat_usd = 0, withdrawal_fee_percent = 0
 where id in (select id from fee_reset_backup_0117);
alter table profiles alter column withdrawal_fee_percent set default 0;
alter table profiles alter column cost_percent set default 0;
update app_settings set value = '{"percent": 0}'::jsonb where key = 'default_withdrawal_fee_percent';
delete from app_settings where key = 'platform_commission_enabled';

-- Per-creator fee setters are retired (global defaults only).
create or replace function public.admin_set_cost_percent(p_user_id uuid, p_percent numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin raise exception 'Per-creator fees were removed; global defaults apply'; end $$;
create or replace function public.set_my_cost_percent(p_percent numeric)
returns numeric language plpgsql security definer set search_path to 'public' as $$
begin raise exception 'Per-creator fees were removed; global defaults apply'; end $$;
create or replace function public.admin_update_creator_fee(p_creator_id uuid, p_fee_percent numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin raise exception 'Per-creator fees were removed; global defaults apply'; end $$;

-- Settlement: no commission branch. Platform gets only the conversion fee
-- (buyer part as charged + creator part on base + extra fee); creator keeps the extra fee.
create or replace function payments_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_fee numeric; v_bfee numeric;
begin
  if tg_op = 'INSERT' then
    new.commission_active := false;
    new.commission_flat_usd := null;
    if new.conversion_fee_mode is null then
      -- non-checkout insert: nothing was charged to the buyer, so the creator part applies
      new.conversion_fee_mode := 'creator';
      new.conversion_fee_percent := conversion_fee_percent();
      new.buyer_fee_percent := 0;
      new.buyer_fee_usd := 0;
    else
      if new.conversion_fee_mode not in ('creator','buyer','split') then
        raise exception 'bad conversion_fee_mode';
      end if;
      new.conversion_fee_percent := coalesce(new.conversion_fee_percent, 0);
      new.buyer_fee_percent := coalesce(new.buyer_fee_percent, 0);
      new.buyer_fee_usd := coalesce(new.buyer_fee_usd, 0);
    end if;
    if coalesce(new.buyer_amount, 0) > 0 and coalesce(new.amount_requested, 0) - new.buyer_fee_usd > 0 then
      new.commission_percent := round(greatest((new.amount_requested - new.buyer_fee_usd) / new.buyer_amount - 1, 0) * 100, 3);
    else
      new.commission_percent := 0;
    end if;
    new.commission_usd := 0;
  end if;
  if new.status = 'settled' and new.amount_settled is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'settled'
          or old.amount_settled is distinct from new.amount_settled) then
    v_bfee := least(coalesce(new.buyer_fee_usd, 0), new.amount_settled);
    v_fee := round((new.amount_settled - v_bfee) * coalesce(new.conversion_fee_percent, 0) / 100, 2);
    new.commission_usd := least(v_bfee + v_fee, new.amount_settled);
  end if;
  return new;
end $$;
revoke all on function payments_commission_snapshot() from public, anon, authenticated;

-- ---------- 3) fee mode default = buyer ----------
insert into app_settings(key, value) values ('conversion_fee_mode', '"buyer"'::jsonb)
on conflict (key) do update set value = excluded.value;
create or replace function conversion_fee_mode()
returns text language sql stable security definer set search_path = public
as $$ select coalesce((select value #>> '{}' from app_settings where key = 'conversion_fee_mode'), 'buyer'); $$;

-- ---------- 1) Cashout in display dollars ----------
alter table withdrawals add column if not exists display_amount numeric(18,2);

create or replace function display_ratio_for(p_uid uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select case when b.earned > 0 and d.s > 0 then least(d.s / b.earned, 1) else 1 end
  from get_balance_for(p_uid) b,
       (select coalesce(sum(display_net_usd), 0) s from payments
         where user_id = p_uid and status = 'settled' and amount_settled >= small_payment_threshold()
           and (confirmation is null or confirmation = 'confirmed')) d;
$$;
revoke all on function display_ratio_for(uuid) from public, anon, authenticated;

-- Cashout figures for the signed-in creator, display dollars only.
create or replace function get_my_cashout()
returns table(available numeric, ratio numeric, fee_percent numeric, fee_fixed_display numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_r numeric; v_av numeric; f record;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  v_r := display_ratio_for(v_uid);
  select greatest(b.available, 0) into v_av from get_balance_for(v_uid) b;
  select * into f from get_withdraw_fee();
  return query select round(v_av * v_r, 2), v_r, f.percent, round(f.fixed_usd * v_r, 2);
end $$;
revoke all on function get_my_cashout() from public, anon;
grant execute on function get_my_cashout() to authenticated;

-- Display amount (or withdraw all) -> real amount -> request_withdrawal().
create or replace function request_withdrawal_display(
  p_display numeric, p_all boolean, p_method text, p_destination text, p_request_key uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_r numeric; v_av numeric; v_real numeric; v_disp numeric; v_row withdrawals;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  perform 1 from profiles where id = v_uid for update;
  v_r := display_ratio_for(v_uid);
  select greatest(b.available, 0) into v_av from get_balance_for(v_uid) b;
  if coalesce(p_all, false) then
    v_real := v_av;
    v_disp := round(v_av * v_r, 2);
  else
    if p_display is null or p_display <= 0 then raise exception 'Enter an amount'; end if;
    v_disp := round(p_display, 2);
    if v_disp > round(v_av * v_r, 2) then
      raise exception 'Insufficient balance. Available: $%', round(v_av * v_r, 2);
    end if;
    v_real := case when v_disp = round(v_av * v_r, 2) then v_av else round(v_disp / v_r, 8) end;
    v_real := least(v_real, v_av);
  end if;
  if v_disp < 5 then raise exception 'Minimum withdrawal is $5'; end if;
  v_row := request_withdrawal(v_real, p_method, p_destination, p_request_key);
  update withdrawals set display_amount = v_disp where id = v_row.id returning * into v_row;
  return jsonb_build_object(
    'id', v_row.id, 'display_amount', v_disp,
    'display_fee', round(v_row.fee_usd * v_disp / nullif(v_row.amount_requested, 0), 2),
    'display_receive', v_disp - round(v_row.fee_usd * v_disp / nullif(v_row.amount_requested, 0), 2));
end $$;
revoke all on function request_withdrawal_display(numeric, boolean, text, text, uuid) from public, anon;
grant execute on function request_withdrawal_display(numeric, boolean, text, text, uuid) to authenticated;
