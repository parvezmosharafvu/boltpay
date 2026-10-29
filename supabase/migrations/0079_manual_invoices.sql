-- 0079: Admin "Create Invoice" (manual invoices), like paycashapp.site
-- /admin/invoices/new. A manual invoice is a record shown to the admin and
-- the creator; it does NOT move money or change any balance.
create table if not exists manual_invoices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  invoice_date date not null default (now() at time zone 'Asia/Dhaka')::date,
  description text not null check (length(btrim(description)) between 1 and 500),
  amount_usd numeric(12,2) not null check (amount_usd > 0 and amount_usd <= 1000000),
  status text not null default 'open' check (status in ('open','paid','void')),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists manual_invoices_user_idx on manual_invoices(user_id, invoice_date desc);
alter table manual_invoices enable row level security;
-- No direct table access; everything goes through the functions below.
revoke all on manual_invoices from anon, authenticated;

create or replace function admin_create_manual_invoice(
  p_user_id uuid, p_amount_usd numeric, p_description text, p_invoice_date date default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if not exists (select 1 from profiles where id = p_user_id) then raise exception 'User not found'; end if;
  insert into manual_invoices (user_id, invoice_date, description, amount_usd, created_by)
  values (p_user_id, coalesce(p_invoice_date, (now() at time zone 'Asia/Dhaka')::date),
          btrim(p_description), round(p_amount_usd, 2), auth.uid())
  returning id into v_id;
  perform record_audit('manual_invoice_create', 'manual_invoice', v_id::text, null,
    jsonb_build_object('user_id', p_user_id, 'amount_usd', round(p_amount_usd, 2), 'description', btrim(p_description)), null);
  return v_id;
end $$;

create or replace function admin_set_manual_invoice_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_old text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_status not in ('open','paid','void') then raise exception 'Bad status'; end if;
  select status into v_old from manual_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  update manual_invoices set status = p_status, updated_at = now() where id = p_id;
  perform record_audit('manual_invoice_status', 'manual_invoice', p_id::text,
    jsonb_build_object('status', v_old), jsonb_build_object('status', p_status), null);
end $$;

create or replace function admin_list_manual_invoices(p_limit int default 100)
returns table (id uuid, user_id uuid, email text, display_name text, invoice_date date,
               description text, amount_usd numeric, status text, created_at timestamptz)
language plpgsql security definer stable set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select m.id, m.user_id, p.email, p.display_name, m.invoice_date, m.description, m.amount_usd, m.status, m.created_at
  from manual_invoices m join profiles p on p.id = m.user_id
  order by m.created_at desc limit least(greatest(coalesce(p_limit,100),1),500);
end $$;

create or replace function my_manual_invoices()
returns table (id uuid, invoice_date date, description text, amount_usd numeric, status text, created_at timestamptz)
language plpgsql security definer stable set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  return query
  select m.id, m.invoice_date, m.description, m.amount_usd, m.status, m.created_at
  from manual_invoices m where m.user_id = auth.uid() and m.status <> 'void'
  order by m.created_at desc limit 200;
end $$;

revoke all on function admin_create_manual_invoice(uuid, numeric, text, date) from public, anon;
revoke all on function admin_set_manual_invoice_status(uuid, text) from public, anon;
revoke all on function admin_list_manual_invoices(int) from public, anon;
revoke all on function my_manual_invoices() from public, anon;
grant execute on function admin_create_manual_invoice(uuid, numeric, text, date) to authenticated;
grant execute on function admin_set_manual_invoice_status(uuid, text) to authenticated;
grant execute on function admin_list_manual_invoices(int) to authenticated;
grant execute on function my_manual_invoices() to authenticated;
