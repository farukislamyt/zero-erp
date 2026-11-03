-- =============================================================================
-- ZERO ERP — PERMANENT ORGANIZATION CREATOR / ADMINISTRATOR
-- =============================================================================
-- The original creator membership is the one and only Administrator for the
-- lifetime of the organization. This is an additive migration: no tables,
-- columns, foreign keys, or existing business data are changed.
--
-- Existing organizations must already have their original creator membership
-- active as their sole Administrator. This migration fails closed otherwise.
-- =============================================================================

begin;

-- Never guess or silently replace the founder when upgrading existing data.
do $preflight$
begin
  if exists (
    select 1
    from public.organizations o
    left join public.organization_users ou
      on ou.organization_id = o.id
     and ou.created_at = o.created_at
    group by o.id
    having count(ou.id) <> 1
  ) then
    raise exception
      'Migration blocked: every organization must have exactly one original creator membership. Reconcile creator history before retrying.';
  end if;

  if exists (
    select 1
    from public.organizations o
    where not exists (
      select 1
      from public.organization_users ou
      join public.roles r
        on r.id = ou.role_id
       and r.organization_id = ou.organization_id
      where ou.organization_id = o.id
        and ou.created_at = o.created_at
        and ou.is_active
        and r.is_system_role
        and r.name = 'Administrator'
        and r.status = 'active'
    )
  ) then
    raise exception
      'Migration blocked: the original creator must be the active Administrator of every organization. Restore the original creator as Administrator before retrying.';
  end if;

  if exists (
    select 1
    from public.organization_users ou
    join public.roles r
      on r.id = ou.role_id
     and r.organization_id = ou.organization_id
    where ou.is_active
      and r.is_system_role
      and r.name = 'Administrator'
    group by ou.organization_id
    having count(*) <> 1
  ) then
    raise exception
      'Migration blocked: an organization has multiple active Administrators. Reconcile the data before retrying.';
  end if;

  if exists (
    select 1
    from public.organization_users ou
    join public.roles r
      on r.id = ou.role_id
     and r.organization_id = ou.organization_id
    join public.organizations o on o.id = ou.organization_id
    where r.is_system_role
      and r.name = 'Administrator'
      and (
        ou.created_at is distinct from o.created_at
        or ou.user_id is null
      )
  ) then
    raise exception
      'Migration blocked: an Administrator membership is not bound to the organization creator record. Reconcile the data before retrying.';
  end if;
end;
$preflight$;

-- The original creator membership is immutable in every mutable field.
-- Its timestamp remains anchored to organizations.created_at.
create or replace function public.guard_organization_creator_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_created_at timestamptz;
  v_is_admin_role boolean := false;
  v_company_creation_allowed boolean :=
    coalesce(pg_catalog.current_setting('app.allow_company_creation', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    select o.created_at
      into v_org_created_at
    from public.organizations o
    where o.id = new.organization_id;

    if v_org_created_at is not null
       and new.created_at = v_org_created_at then
      select coalesce(r.is_system_role and r.name = 'Administrator', false)
        into v_is_admin_role
      from public.roles r
      where r.id = new.role_id
        and r.organization_id = new.organization_id;

      if not v_company_creation_allowed
         or not v_is_admin_role
         or not new.is_active
         or new.user_id is distinct from (select auth.uid()) then
        raise exception using errcode = '42501',
          message = 'Only the authenticated company-creation workflow may establish the original active Administrator membership.';
      end if;

      if exists (
        select 1
        from public.organization_users ou
        where ou.organization_id = new.organization_id
          and ou.created_at = v_org_created_at
      ) then
        raise exception using errcode = '23505',
          message = 'This organization already has its permanent creator membership.';
      end if;
    else
      -- Keep ordinary membership timestamps away from the reserved creator
      -- anchor, including when transaction-stable now() returns the same value.
      if v_org_created_at is not null then
        new.created_at := greatest(
          pg_catalog.clock_timestamp(),
          v_org_created_at + interval '1 microsecond'
        );
      end if;
    end if;

    return new;
  end if;

  select o.created_at
    into v_org_created_at
  from public.organizations o
  where o.id = old.organization_id;

  if tg_op = 'UPDATE'
     and (
       new.organization_id is distinct from old.organization_id
       or new.user_id is distinct from old.user_id
       or new.created_at is distinct from old.created_at
     ) then
    raise exception using errcode = '42501',
      message = 'Membership organization, user, and creation timestamp are immutable.';
  end if;

  if v_org_created_at is not null
     and old.created_at = v_org_created_at then
    if tg_op = 'DELETE' then
      raise exception using errcode = '42501',
        message = 'The original creator Administrator membership can never be deleted.';
    end if;

    -- Reject every UPDATE, including attempts to change role, active state,
    -- updated_at, or any future column added to the membership table.
    raise exception using errcode = '42501',
      message = 'The original creator Administrator membership is permanently immutable.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists organization_users_guard_creator_record
  on public.organization_users;
create trigger organization_users_guard_creator_record
before insert or update or delete on public.organization_users
for each row
execute function public.guard_organization_creator_membership();

-- A user may acquire the Administrator role only in the single INSERT that
-- establishes the creator anchor during create_organization_with_admin().
-- All later Administrator INSERT/UPDATE/DELETE attempts are rejected.
create or replace function public.guard_administrator_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_is_admin boolean := false;
  v_old_is_admin boolean := false;
  v_org_created_at timestamptz;
  v_company_creation_allowed boolean :=
    coalesce(pg_catalog.current_setting('app.allow_company_creation', true), '') = 'on';
begin
  if tg_op <> 'DELETE' then
    select coalesce(r.is_system_role and r.name = 'Administrator', false)
      into v_new_is_admin
    from public.roles r
    where r.id = new.role_id
      and r.organization_id = new.organization_id;
  end if;

  if tg_op <> 'INSERT' then
    select coalesce(r.is_system_role and r.name = 'Administrator', false)
      into v_old_is_admin
    from public.roles r
    where r.id = old.role_id
      and r.organization_id = old.organization_id;
  end if;

  if tg_op = 'INSERT' then
    if v_new_is_admin then
      select o.created_at
        into v_org_created_at
      from public.organizations o
      where o.id = new.organization_id;

      if not v_company_creation_allowed
         or not new.is_active
         or new.created_at is distinct from v_org_created_at
         or new.user_id is distinct from (select auth.uid()) then
        raise exception using errcode = '42501',
          message = 'Only the original authenticated creator may receive the Administrator role during organization creation.';
      end if;

      if exists (
        select 1
        from public.organization_users ou
        join public.roles r
          on r.id = ou.role_id
         and r.organization_id = ou.organization_id
        where ou.organization_id = new.organization_id
          and r.is_system_role
          and r.name = 'Administrator'
      ) then
        raise exception using errcode = '23505',
          message = 'This organization already has its permanent Administrator.';
      end if;
    end if;

    return new;
  end if;

  if tg_op = 'UPDATE' then
    if v_old_is_admin or v_new_is_admin then
      raise exception using errcode = '42501',
        message = 'Administrator membership cannot be changed, replaced, deactivated, or reassigned.';
    end if;
    return new;
  end if;

  if v_old_is_admin then
    raise exception using errcode = '42501',
      message = 'Administrator membership cannot be deleted.';
  end if;

  return old;
end;
$$;

drop trigger if exists organization_users_guard_last_admin
  on public.organization_users;
create trigger organization_users_guard_last_admin
before insert or update or delete on public.organization_users
for each row
execute function public.guard_administrator_membership();

-- Protect the system Administrator role itself: it cannot be renamed,
-- deactivated, deleted, or created outside the organization bootstrap RPC.
create or replace function public.guard_system_administrator_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_creation_allowed boolean :=
    coalesce(pg_catalog.current_setting('app.allow_company_creation', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    if new.is_system_role and new.name = 'Administrator'
       and (not v_company_creation_allowed or (select auth.uid()) is null) then
      raise exception using errcode = '42501',
        message = 'The system Administrator role can only be created by the authenticated organization-creation workflow.';
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if (old.is_system_role and old.name = 'Administrator')
       or (new.is_system_role and new.name = 'Administrator') then
      raise exception using errcode = '42501',
        message = 'The system Administrator role is permanent and immutable.';
    end if;
    return new;
  end if;

  if old.is_system_role and old.name = 'Administrator' then
    raise exception using errcode = '42501',
      message = 'The system Administrator role cannot be deleted.';
  end if;
  return old;
end;
$$;

drop trigger if exists roles_guard_system_administrator
  on public.roles;
create trigger roles_guard_system_administrator
before insert or update or delete on public.roles
for each row
execute function public.guard_system_administrator_role();

revoke all on function public.guard_organization_creator_membership()
  from public, anon, authenticated;
revoke all on function public.guard_administrator_membership()
  from public, anon, authenticated;
revoke all on function public.guard_system_administrator_role()
  from public, anon, authenticated;

-- Keep the existing creation contract and bootstrap behavior, but remove the
-- Administrator-transfer bypass. The creation flag is scoped to this one
-- transaction and is required by the three database guards above.
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
  v_created_at timestamptz;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'Authentication is required to create an organization.';
  end if;

  perform 1
  from auth.users u
  where u.id = v_user_id
  for update;

  if not found then
    raise exception using errcode = '42501',
      message = 'Authenticated user was not found.';
  end if;

  if exists (
    select 1
    from public.organization_users ou
    join public.organizations o
      on o.id = ou.organization_id
     and ou.created_at = o.created_at
    where ou.user_id = v_user_id
  ) then
    raise exception using errcode = '23505',
      message = 'This account has already created a company. Each account may create only one company.';
  end if;

  if exists (
    select 1
    from public.organization_users ou
    where ou.user_id = v_user_id
      and ou.is_active
  ) then
    raise exception using errcode = '23505',
      message = 'Deactivate your current company membership before creating a new company.';
  end if;

  if p_name is null
     or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 160 then
    raise exception using errcode = '22023',
      message = 'Organization name must contain between 1 and 160 characters.';
  end if;

  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    raise exception using errcode = '22023',
      message = 'Currency must be a three-letter uppercase ISO currency code.';
  end if;

  if p_timezone is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names tz
       where tz.name = pg_catalog.btrim(p_timezone)
     ) then
    raise exception using errcode = '22023',
      message = 'Timezone must be a valid PostgreSQL timezone name.';
  end if;

  v_created_at := pg_catalog.clock_timestamp();

  insert into public.organizations (name, currency, timezone, created_at)
  values (
    pg_catalog.btrim(p_name),
    p_currency,
    pg_catalog.btrim(p_timezone),
    v_created_at
  )
  returning id into v_organization_id;

  perform pg_catalog.set_config('app.allow_company_creation', 'on', true);

  insert into public.roles (organization_id, name, status, is_system_role)
  values (v_organization_id, 'Administrator', 'active', true)
  returning id into v_role_id;

  insert into public.role_permissions (role_id, permission_id)
  select v_role_id, p.id
  from public.permissions p
  on conflict (role_id, permission_id) do nothing;

  insert into public.organization_users (
    organization_id,
    user_id,
    role_id,
    is_active,
    created_at
  )
  values (
    v_organization_id,
    v_user_id,
    v_role_id,
    true,
    v_created_at
  );

  perform pg_catalog.set_config('app.allow_company_creation', 'off', true);

  -- Preserve the existing default chart-of-accounts bootstrap behavior.
  perform public.seed_default_chart_of_accounts(v_organization_id);

  return v_organization_id;
end;
$$;

revoke all on function public.create_organization_with_admin(text,text,text)
  from public, anon;
grant execute on function public.create_organization_with_admin(text,text,text)
  to authenticated;

-- Retire the old handover API completely. Dropping the function also removes
-- its EXECUTE grants so clients cannot invoke it after this migration.
drop function if exists public.transfer_organization_administrator(uuid,uuid);

comment on function public.is_organization_creator(uuid,uuid) is
  'True only for the immutable original creator membership anchored to organizations.created_at.';
comment on function public.create_organization_with_admin(text,text,text) is
  'Creates an organization and permanently binds its sole Administrator role to the authenticated original creator. Administrator transfer is not supported.';

commit;
