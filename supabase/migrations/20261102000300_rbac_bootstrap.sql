-- Zero ERP: permission catalog, organization bootstrap, and Administrator safeguards
-- Migration: 20261102000300_rbac_bootstrap.sql
-- Depends on 20261102000100_core_foundation.sql.

begin;

insert into public.permissions (permission_key, name, description, module)
values
  ('organization.read', 'View organization', 'View organization profile and settings.', 'organization'),
  ('organization.update', 'Update organization', 'Update organization profile and settings.', 'organization'),
  ('users.read', 'View members', 'View organization memberships.', 'users'),
  ('users.manage', 'Manage members', 'Invite, deactivate, and assign roles to members.', 'users'),
  ('roles.read', 'View roles', 'View organization roles and their permissions.', 'roles'),
  ('roles.manage', 'Manage roles', 'Create and update organization-specific custom roles.', 'roles'),
  ('accounting_periods.read', 'View accounting periods', 'View accounting periods.', 'accounting'),
  ('accounting_periods.manage', 'Manage accounting periods', 'Create and close accounting periods.', 'accounting'),
  ('accounts.read', 'View chart of accounts', 'View accounts and account hierarchy.', 'accounting'),
  ('accounts.manage', 'Manage chart of accounts', 'Create and update chart of accounts.', 'accounting'),
  ('journal_entries.read', 'View journal entries', 'View journal entries and lines.', 'accounting'),
  ('journal_entries.create', 'Create journal entries', 'Create draft journal entries.', 'accounting'),
  ('journal_entries.post', 'Post journal entries', 'Post balanced journal entries.', 'accounting'),
  ('journal_entries.reverse', 'Reverse journal entries', 'Create controlled reversals of posted entries.', 'accounting'),
  ('contacts.read', 'View contacts', 'View customers, suppliers, and other contacts.', 'contacts'),
  ('contacts.manage', 'Manage contacts', 'Create and update contacts.', 'contacts'),
  ('products.read', 'View products', 'View products and units.', 'inventory'),
  ('products.manage', 'Manage products', 'Create and update products and account mappings.', 'inventory'),
  ('inventory.read', 'View inventory', 'View stock balances and movements.', 'inventory'),
  ('inventory.adjust', 'Adjust inventory', 'Post authorized inventory adjustments.', 'inventory'),
  ('purchases.read', 'View purchases', 'View purchase invoices and returns.', 'purchases'),
  ('purchases.create', 'Create purchases', 'Create and update draft purchase documents.', 'purchases'),
  ('purchases.post', 'Post purchases', 'Post purchases and related stock/accounting effects.', 'purchases'),
  ('purchases.returns.post', 'Post purchase returns', 'Post purchase returns.', 'purchases'),
  ('sales.read', 'View sales', 'View sales invoices and returns.', 'sales'),
  ('sales.create', 'Create sales', 'Create and update draft sales documents.', 'sales'),
  ('sales.post', 'Post sales', 'Post sales and related stock/accounting effects.', 'sales'),
  ('sales.returns.post', 'Post sales returns', 'Post sales returns.', 'sales'),
  ('expenses.read', 'View expenses', 'View expense records.', 'expenses'),
  ('expenses.manage', 'Manage expenses', 'Create and update draft expenses.', 'expenses'),
  ('expenses.post', 'Post expenses', 'Post expenses to the ledger.', 'expenses'),
  ('payments.read', 'View payments', 'View payments and allocations.', 'payments'),
  ('payments.manage', 'Manage payments', 'Create payments and manage draft allocations.', 'payments'),
  ('payments.post', 'Post payments', 'Post payments and allocation effects.', 'payments'),
  ('reports.read', 'View reports', 'View organization financial and operational reports.', 'reports')
on conflict (permission_key) do update
set name = excluded.name,
    description = excluded.description,
    module = excluded.module;

-- New permissions are assigned to existing system Administrator roles as part of
-- the same migration, so deployments do not leave a protected admin role incomplete.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.is_system_role and r.name = 'Administrator'
on conflict (role_id, permission_id) do nothing;

create or replace function public.create_organization_with_admin(
  p_name text,
  p_currency text default 'BDT',
  p_timezone text default 'Asia/Dhaka'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_organization_id uuid;
  v_role_id uuid;
begin
  v_user_id := (select auth.uid());

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication is required to create an organization.';
  end if;

  if p_name is null or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 160 then
    raise exception using
      errcode = '22023',
      message = 'Organization name must contain between 1 and 160 characters.';
  end if;

  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    raise exception using
      errcode = '22023',
      message = 'Currency must be a three-letter uppercase ISO currency code.';
  end if;

  if p_timezone is null or pg_catalog.length(pg_catalog.btrim(p_timezone)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Timezone is required.';
  end if;

  insert into public.organizations (name, currency, timezone)
  values (pg_catalog.btrim(p_name), p_currency, p_timezone)
  returning id into v_organization_id;

  insert into public.roles (organization_id, name, status, is_system_role)
  values (v_organization_id, 'Administrator', 'active', true)
  returning id into v_role_id;

  insert into public.role_permissions (role_id, permission_id)
  select v_role_id, p.id
  from public.permissions p
  on conflict (role_id, permission_id) do nothing;

  insert into public.organization_users (organization_id, user_id, role_id, is_active)
  values (v_organization_id, v_user_id, v_role_id, true);

  return v_organization_id;
end;
$$;

revoke all on function public.create_organization_with_admin(text, text, text) from public, anon;
grant execute on function public.create_organization_with_admin(text, text, text) to authenticated;

create or replace function public.guard_system_role_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.is_system_role then
    if tg_op = 'DELETE' then
      raise exception using errcode = '42501', message = 'System roles cannot be deleted.';
    end if;

    if new.is_system_role is distinct from true
       or new.name is distinct from old.name
       or new.organization_id is distinct from old.organization_id
       or new.status is distinct from 'active' then
      raise exception using errcode = '42501', message = 'System roles cannot be renamed, moved, or deactivated.';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger roles_guard_system_role
before update or delete on public.roles
for each row execute function public.guard_system_role_mutation();

create or replace function public.guard_administrator_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_active_admin boolean := false;
  v_remaining_admins integer;
begin
  select exists (
    select 1
    from public.roles r
    where r.id = old.role_id
      and r.organization_id = old.organization_id
      and r.is_system_role
      and r.name = 'Administrator'
  ) into v_is_active_admin;

  if not old.is_active or not v_is_active_admin then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.is_active
     and new.role_id = old.role_id
     and new.organization_id = old.organization_id then
    return new;
  end if;

  select pg_catalog.count(*)
  into v_remaining_admins
  from public.organization_users ou
  join public.roles r
    on r.id = ou.role_id
   and r.organization_id = ou.organization_id
  where ou.organization_id = old.organization_id
    and ou.is_active
    and r.is_system_role
    and r.name = 'Administrator'
    and ou.id <> old.id;

  if v_remaining_admins < 1 then
    raise exception using
      errcode = '23514',
      message = 'An organization must retain at least one active Administrator.';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger organization_users_guard_last_admin
before update or delete on public.organization_users
for each row execute function public.guard_administrator_membership();

create or replace function public.guard_system_role_permissions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_protected_role boolean;
begin
  select exists (
    select 1
    from public.roles r
    where r.id = old.role_id
      and r.is_system_role
      and r.name = 'Administrator'
  ) or (
    tg_op = 'UPDATE' and exists (
      select 1
      from public.roles r
      where r.id = new.role_id
        and r.is_system_role
        and r.name = 'Administrator'
    )
  )
  into v_protected_role;

  if coalesce(v_protected_role, false) then
    raise exception using
      errcode = '42501',
      message = 'Administrator permissions cannot be removed or reassigned.';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger role_permissions_guard_admin
before update or delete on public.role_permissions
for each row execute function public.guard_system_role_permissions();

revoke all on function public.guard_system_role_mutation() from public, anon, authenticated;
revoke all on function public.guard_administrator_membership() from public, anon, authenticated;
revoke all on function public.guard_system_role_permissions() from public, anon, authenticated;

commit;
