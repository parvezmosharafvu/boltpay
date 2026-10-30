-- The owner retired the "Global switches" card. These settings are now
-- fixed in code, whatever the old app_settings / profiles rows say
-- (the rows are left in place as history):
--   * Buyer-typed amount is always shown, for every creator.
--   * Small settled payments are never hidden.
--   * Withdrawal requests are always accepted (Lightning and USDT BEP20,
--     both paid out manually by an admin from the queue).
-- Balance logic is untouched.

create or replace function public.should_show_buyer_amount(p_creator_id uuid)
 returns boolean
 language sql
 stable
 set search_path to 'public'
as $function$
  select true;
$function$;

create or replace function public.small_payment_threshold()
 returns numeric
 language sql
 stable
 set search_path to 'public'
as $function$
  select -1::numeric;  -- nothing is ever <= -1, so the filter is a no-op
$function$;

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
