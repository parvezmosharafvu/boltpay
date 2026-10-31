-- 0115: admin-set withdraw fee (owner decision, Oct 31 2026).
-- Fee = amount x withdraw_fee_percent/100 + withdraw_fee_fixed_usd, rounded to
-- cents, charged on top of any link extra fee. It is snapshotted on the
-- withdrawal row when the creator requests it: the balance still drops by
-- amount_requested, the creator is paid amount_after_fee, and fee_usd is
-- platform revenue. Additive: existing rows (pending included) keep fee 0.
-- Defaults are 0 % and $0, so nothing changes until an admin sets a fee.

alter table withdrawals add column if not exists fee_fixed_usd numeric(12,2) not null default 0;
alter table withdrawals add column if not exists fee_usd numeric(12,2) not null default 0;

insert into app_settings(key, value) values
  ('withdraw_fee_percent', '0'::jsonb),
  ('withdraw_fee_fixed_usd', '0'::jsonb)
on conflict (key) do nothing;

-- Range guard for any write path (RPC or a direct admin upsert).
create or replace function validate_withdraw_fee_setting()
returns trigger language plpgsql set search_path = public as $$
declare v numeric;
begin
  begin
    v := (new.value #>> '{}')::numeric;
  exception when others then
    raise exception 'Withdraw fee must be a number';
  end;
  if v is null then raise exception 'Withdraw fee must be a number'; end if;
  if new.key = 'withdraw_fee_percent' and (v < 0 or v > 50) then
    raise exception 'Withdraw fee %% must be between 0 and 50';
  end if;
  if new.key = 'withdraw_fee_fixed_usd' and (v < 0 or v > 1000) then
    raise exception 'Fixed withdraw fee must be between $0 and $1000';
  end if;
  return new;
end $$;
drop trigger if exists trg_validate_withdraw_fee on app_settings;
create trigger trg_validate_withdraw_fee
  before insert or update on app_settings
  for each row when (new.key in ('withdraw_fee_percent', 'withdraw_fee_fixed_usd'))
  execute function validate_withdraw_fee_setting();

-- Audit, same pattern as 0111.
create or replace function audit_withdraw_fee_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and old.value is not distinct from new.value then
    return new;
  end if;
  perform record_audit('withdraw_fee', 'app_settings', new.key,
    case when tg_op = 'UPDATE' then old.value else null end, new.value, null);
  return new;
end $$;
revoke all on function audit_withdraw_fee_change() from public, anon, authenticated;
drop trigger if exists trg_audit_withdraw_fee on app_settings;
create trigger trg_audit_withdraw_fee
  after insert or update on app_settings
  for each row when (new.key in ('withdraw_fee_percent', 'withdraw_fee_fixed_usd'))
  execute function audit_withdraw_fee_change();

-- Current settings, readable by any signed-in creator (for the Cashout preview).
create or replace function get_withdraw_fee()
returns table(percent numeric, fixed_usd numeric)
language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::numeric from app_settings where key = 'withdraw_fee_percent'), 0),
         coalesce((select (value #>> '{}')::numeric from app_settings where key = 'withdraw_fee_fixed_usd'), 0);
$$;
revoke all on function get_withdraw_fee() from public, anon;
grant execute on function get_withdraw_fee() to authenticated, service_role;

-- Admin save (both values in one call, one audit row per changed key).
create or replace function admin_set_withdraw_fee(p_percent numeric, p_fixed_usd numeric)
returns table(percent numeric, fixed_usd numeric)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent is null or p_percent < 0 or p_percent > 50 then
    raise exception 'Withdraw fee %% must be between 0 and 50';
  end if;
  if p_fixed_usd is null or p_fixed_usd < 0 or p_fixed_usd > 1000 then
    raise exception 'Fixed withdraw fee must be between $0 and $1000';
  end if;
  insert into app_settings(key, value, updated_at) values
    ('withdraw_fee_percent', to_jsonb(round(p_percent, 2)), now()),
    ('withdraw_fee_fixed_usd', to_jsonb(round(p_fixed_usd, 2)), now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
  return query select * from get_withdraw_fee();
end $$;
revoke all on function admin_set_withdraw_fee(numeric, numeric) from public, anon;
grant execute on function admin_set_withdraw_fee(numeric, numeric) to authenticated;

-- Pure quote used by every request path.
create or replace function withdraw_fee_quote(p_amount numeric)
returns table(percent numeric, fixed_usd numeric, fee_usd numeric, receive_usd numeric)
language sql stable security definer set search_path = public as $$
  select f.percent, f.fixed_usd,
         round(round(p_amount, 2) * f.percent / 100 + f.fixed_usd, 2),
         round(p_amount, 2) - round(round(p_amount, 2) * f.percent / 100 + f.fixed_usd, 2)
  from get_withdraw_fee() f;
$$;
revoke all on function withdraw_fee_quote(numeric) from public, anon;
grant execute on function withdraw_fee_quote(numeric) to authenticated, service_role;

create or replace function public.request_withdrawal(p_amount numeric, p_method text, p_destination text)
 returns withdrawals
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_available numeric;
  v_q record;
  v_row withdrawals;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  -- Serialise concurrent requests from the same creator.
  perform 1 from profiles where id = v_uid for update;
  if p_amount is null or p_amount < 5 then
    raise exception 'Minimum withdrawal is $5';
  end if;
  if p_method is null or p_method not in ('lightning','usdt_bep20') then
    raise exception 'Invalid withdrawal method';
  end if;
  if p_destination is null or length(trim(p_destination)) = 0 then
    raise exception 'Destination account is required';
  end if;
  if length(trim(p_destination)) > 500 then
    raise exception 'Destination is too long';
  end if;
  select b.available into v_available from get_balance_for(v_uid) b;
  if p_amount > v_available then
    raise exception 'Insufficient balance. Available: $%', round(v_available, 2);
  end if;
  select * into v_q from withdraw_fee_quote(p_amount);
  if v_q.fee_usd >= round(p_amount, 2) then
    raise exception 'Withdraw fee ($%) is not less than the amount. Please withdraw more. · উইথড্র ফি পরিমাণের চেয়ে কম নয়। আরও বেশি তুলুন।', v_q.fee_usd;
  end if;
  insert into withdrawals (
    user_id, amount_requested, fee_percent, fee_fixed_usd, fee_usd, amount_after_fee,
    method, destination, status
  )
  values (
    v_uid, p_amount, v_q.percent, v_q.fixed_usd, v_q.fee_usd, v_q.receive_usd,
    p_method, trim(p_destination), 'pending'
  )
  returning * into v_row;
  return v_row;
end;
$function$;

create or replace function public.system_queue_withdrawal(p_user_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_profile profiles;
  v_available numeric;
  v_destination text;
  v_method text;
  v_q record;
  v_id uuid;
begin
  select * into v_profile from profiles where id = p_user_id for update;
  if not found or coalesce(v_profile.auto_withdraw_enabled, false) = false then
    return null;
  end if;

  v_method := coalesce(v_profile.default_withdrawal_method, 'usdt_bep20');
  if v_method = 'lightning' then
    return null;
  end if;
  if v_method not in ('bkash','nagad','binance','usdt_bep20','bank') then
    return null;
  end if;

  v_destination := coalesce(
    nullif(trim(coalesce(v_profile.default_withdrawal_destination, '')), ''),
    case v_method
      when 'bkash'      then v_profile.wallet_bkash
      when 'nagad'      then v_profile.wallet_nagad
      when 'binance'    then v_profile.wallet_binance_id
      when 'usdt_bep20' then v_profile.wallet_usdt_bep20
      when 'bank'       then v_profile.wallet_bank
    end
  );
  if v_destination is null or length(trim(v_destination)) = 0 then
    return null;
  end if;

  select b.available into v_available from get_balance_for(p_user_id) b;
  if v_available is null or v_available < 5 then
    return null;
  end if;
  select * into v_q from withdraw_fee_quote(v_available);
  if v_q.fee_usd >= round(v_available, 2) then
    return null;
  end if;

  insert into withdrawals (
    user_id, amount_requested, fee_percent, fee_fixed_usd, fee_usd, amount_after_fee,
    method, destination, status, admin_note
  )
  values (
    p_user_id, v_available, v_q.percent, v_q.fixed_usd, v_q.fee_usd, v_q.receive_usd,
    v_method, trim(v_destination), 'pending', 'Auto-queued on settlement'
  )
  returning id into v_id;
  return v_id;
end;
$function$;

-- Browser sessions may not edit the fee snapshot either.
create or replace function public.guard_withdrawal_updates()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if auth.uid() is null then
    return new;  -- service role / definer functions
  end if;
  if new.user_id          is distinct from old.user_id
  or new.amount_requested is distinct from old.amount_requested
  or new.fee_percent      is distinct from old.fee_percent
  or new.fee_fixed_usd    is distinct from old.fee_fixed_usd
  or new.fee_usd          is distinct from old.fee_usd
  or new.amount_after_fee is distinct from old.amount_after_fee
  or new.destination      is distinct from old.destination
  then
    raise exception 'Withdrawal amounts and destination cannot be edited';
  end if;
  if old.status in ('paid', 'processing') and new.status is distinct from old.status then
    raise exception 'A paid or processing withdrawal cannot be reopened';
  end if;
  return new;
end; $$;

-- Admin "Fee earned": withdraw fees on paid withdrawals (added to the card).
create or replace function admin_withdraw_fee_stats(p_start timestamptz default null, p_end timestamptz default null)
returns numeric language plpgsql stable security definer set search_path to 'public' as $$
declare v numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  select coalesce(sum(w.fee_usd), 0) into v
  from withdrawals w
  where w.status = 'paid'
    and (p_start is null or coalesce(w.processed_at, w.requested_at) >= p_start)
    and (p_end   is null or coalesce(w.processed_at, w.requested_at) <= p_end);
  return v;
end $$;
revoke all on function admin_withdraw_fee_stats(timestamptz, timestamptz) from public, anon;
grant execute on function admin_withdraw_fee_stats(timestamptz, timestamptz) to authenticated;
