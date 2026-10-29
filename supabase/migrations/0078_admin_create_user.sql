-- 0078: Admin "Create User". The auth account itself is created by the
-- admin-create-user edge function (service role); this function then
-- approves the new profile and writes the audit line, running as the
-- calling admin so auth.uid() / record_audit name the real actor.
-- Self-registration + approval (0070) is unchanged.
create or replace function admin_finalize_created_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_email text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  update profiles set account_status = 'active'
   where id = p_user_id and role <> 'admin'
   returning email into v_email;
  if not found then raise exception 'User not found'; end if;
  perform record_audit('admin_create_user', 'profile', p_user_id::text, null,
    jsonb_build_object('email', v_email, 'account_status', 'active'), 'Created by admin');
end $$;
revoke all on function admin_finalize_created_user(uuid) from public, anon;
grant execute on function admin_finalize_created_user(uuid) to authenticated;
