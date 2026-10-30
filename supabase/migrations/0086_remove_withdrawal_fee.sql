-- Owner decision (Oct 30 2026): no withdrawal fee. New withdrawals record
-- fee_percent = 0 and amount_after_fee = amount_requested.
-- Archive kept: profiles.withdrawal_fee_percent and every existing
-- withdrawals row (pending ones included) are left exactly as they are.
-- The default for new accounts goes 2 -> 0 (the previous value is in this comment).

create or replace function public.request_withdrawal(p_amount numeric, p_method text, p_destination text)
 returns withdrawals
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_available numeric;
  v_row withdrawals;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if coalesce((select (value)::text from app_settings
               where key = 'manual_withdrawals_enabled'), 'true') <> 'true' then
    raise exception 'Withdrawal requests are temporarily paused. Please try again later.';
  end if;

  -- Serialise concurrent requests from the same creator.
  perform 1 from profiles where id = v_uid for update;
  if p_amount is null or p_amount < 5 then
    raise exception 'Minimum withdrawal is $5';
  end if;
  if p_method is null or p_method not in
    ('bkash','nagad','binance','lightning','usdt_bep20','bank') then
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
  insert into withdrawals (
    user_id, amount_requested, fee_percent, amount_after_fee,
    method, destination, status
  )
  values (
    v_uid, p_amount, 0, round(p_amount, 2),
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

  insert into withdrawals (
    user_id, amount_requested, fee_percent, amount_after_fee,
    method, destination, status, admin_note
  )
  values (
    p_user_id, v_available, 0, round(v_available, 2),
    v_method, trim(v_destination), 'pending', 'Auto-queued on settlement'
  )
  returning id into v_id;
  return v_id;
end;
$function$;

update app_settings set value = '{"percent": 0}'::jsonb
 where key = 'default_withdrawal_fee_percent';
