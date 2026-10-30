-- Admin currency control: list withdrawal methods with their payout currency.
-- Return type changes, so the function is dropped and recreated (no data touched).
drop function if exists admin_list_withdrawal_methods();
create function admin_list_withdrawal_methods()
returns table (code text, label_en text, label_bn text, enabled boolean, sort int, updated_at timestamptz, currency text)
language plpgsql security definer stable set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query select w.code, w.label_en, w.label_bn, w.enabled, w.sort, w.updated_at, w.currency
               from withdrawal_methods w order by w.sort;
end $$;
revoke all on function admin_list_withdrawal_methods() from public, anon;
grant execute on function admin_list_withdrawal_methods() to authenticated;
