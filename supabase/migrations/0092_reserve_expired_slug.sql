-- Reserve 'expired' (used by /pay/i/<id>/expired). Same function as 0064 plus one name.
create or replace function validate_link_slug()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.slug := trim(new.slug);

  if new.slug !~ '^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$' then
    raise exception 'Link name must be 4-50 characters: letters, numbers and hyphens only';
  end if;

  -- Reserved names are matched case-insensitively: /Admin must be
  -- blocked just as firmly as /admin.
  if lower(new.slug) in (
    'index','login','register','dashboard','admin','404','config','theme',
    'assets','favicon','invoice-boltpay-v2','api','u','static','public',
    'well-known','robots','sitemap','moderator','expired'
  ) then
    raise exception 'That link name is reserved';
  end if;

  return new;
end;
$$;
