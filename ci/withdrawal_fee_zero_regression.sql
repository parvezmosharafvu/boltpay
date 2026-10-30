do $$
declare d text;
begin
  d := pg_get_functiondef('public.request_withdrawal(numeric,text,text)'::regprocedure);
  assert d not like '%withdrawal_fee_percent%', 'request_withdrawal must not read the fee';
  d := pg_get_functiondef('public.system_queue_withdrawal(uuid)'::regprocedure);
  assert d not like '%withdrawal_fee_percent%', 'system_queue_withdrawal must not read the fee';
end $$;
