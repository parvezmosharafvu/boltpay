-- 0088: idempotency key for withdrawal requests (gap 9).
-- A double-tap / retried POST with the same key can never create a second
-- withdrawal. Additive: existing rows keep request_key = NULL.
alter table withdrawals add column if not exists request_key uuid;
create unique index if not exists withdrawals_request_key_uidx
  on withdrawals(request_key) where request_key is not null;

-- Keyed overload. The 3-arg version is untouched (system paths still use it).
-- A repeated key raises DUPLICATE_REQUEST so the caller can answer "already
-- submitted" without running any payout logic a second time.
create or replace function request_withdrawal(p_amount numeric, p_method text, p_destination text, p_request_key uuid)
 returns withdrawals
 language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_row withdrawals;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_request_key is null then
    return request_withdrawal(p_amount, p_method, p_destination);
  end if;
  -- Same lock the 3-arg version takes: concurrent repeats queue here and
  -- the second one sees the first one's committed row.
  perform 1 from profiles where id = v_uid for update;
  if exists (select 1 from withdrawals where request_key = p_request_key) then
    raise exception 'DUPLICATE_REQUEST';
  end if;
  v_row := request_withdrawal(p_amount, p_method, p_destination);
  update withdrawals set request_key = p_request_key where id = v_row.id
    returning * into v_row;
  return v_row;
end; $function$;

revoke all on function request_withdrawal(numeric,text,text,uuid) from public, anon;
grant execute on function request_withdrawal(numeric,text,text,uuid) to authenticated;
