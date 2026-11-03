-- =============================================================================
-- ZERO ERP — ORGANIZATION OWNERSHIP AND MEMBERSHIP SECURITY
-- =============================================================================
-- Keeps the existing table/column structure. This migration hardens the
-- existing organization_users/roles records and removes invitation workflows.
--
-- Founder identity is recorded by the original Administrator membership row:
-- its created_at is the same transaction timestamp as organizations.created_at.
-- The founder row is never deleted and its identity/timestamp never changes.
-- During an Administrator handover it is deactivated (not deleted), so it
-- remains a permanent company-creation record while releasing the user to join
-- another company. No new table or column is introduced.
-- =============================================================================

begin;

-- Fail closed rather than silently choosing which tenant membership/admin to
-- deactivate when upgrading a database that already violates the new policy.
do $preflight$
begin
  if exists (
    select 1 from public.organization_users
    where is_active
    group by user_id
    having count(*) > 1
  ) then
    raise exception 'Migration blocked: one or more users have active memberships in multiple companies. Resolve those memberships before retrying.';
  end if;

  if exists (
    select 1
    from public.organization_users ou
    join public.roles r
      on r.id = ou.role_id and r.organization_id = ou.organization_id
    where ou.is_active and r.is_system_role and r.name = 'Administrator'
    group by ou.organization_id
    having count(*) > 1
  ) then
    raise exception 'Migration blocked: one or more companies have multiple active Administrators. Select the intended Administrator before retrying.';
  end if;

  if exists (
    select 1
    from public.organizations o
    where not exists (
      select 1
      from public.organization_users ou
      where ou.organization_id = o.id
        and ou.created_at = o.created_at
    )
  ) then
    raise exception 'Migration blocked: at least one company has no identifiable original Administrator membership timestamp. Founder history must be reconciled before retrying.';
  end if;
end;
$preflight$;

-- Refuse to silently bootstrap a company that has lost its active admin.
do $admin_preflight$
begin
  if exists (
    select 1 from public.organizations o
    where not exists (
      select 1
      from public.organization_users ou
      join public.roles r
        on r.id = ou.role_id and r.organization_id = ou.organization_id
      where ou.organization_id = o.id
        and ou.is_active
        and r.is_system_role
        and r.name = 'Administrator'
        and r.status = 'active'
    )
  ) then
    raise exception 'Migration blocked: at least one company has no active Administrator. Restore or designate its intended Administrator before retrying.';
  end if;
end;
$admin_preflight$;

-- One active company membership per Auth user. Inactive historical rows remain.
create unique index if not exists organization_users_one_active_company_per_user
  on public.organization_users (user_id)
  where is_active = true;

-- The creator is identified by the initial membership timestamp. This helper
-- deliberately does not depend on the member's current role or active state.
create or replace function public.is_organization_creator(
  p_organization_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organizations o
    join public.organization_users ou
      on ou.organization_id = o.id
     and ou.created_at = o.created_at
    where o.id = p_organization_id
      and ou.user_id = p_user_id
  );
$$;

create or replace function public.is_org_administrator(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_users ou
    join public.organizations o
      on o.id = ou.organization_id
     and o.is_active
    join public.roles r
      on r.id = ou.role_id
     and r.organization_id = ou.organization_id
    where ou.organization_id = p_organization_id
      and ou.user_id = (select auth.uid())
      and ou.is_active
      and r.is_system_role
      and r.name = 'Administrator'
      and r.status = 'active'
  );
$$;

revoke all on function public.is_organization_creator(uuid,uuid) from public, anon, authenticated;
revoke all on function public.is_org_administrator(uuid) from public, anon;
grant execute on function public.is_org_administrator(uuid) to authenticated;

-- The original creator record cannot be deleted, moved, reassigned to another
-- Auth user, or have its timestamp/role rewritten. It can only be deactivated
-- by the privileged Administrator-transfer RPC.
create or replace function public.guard_organization_creator_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_created_at timestamptz;
  v_is_creator_record boolean := false;
  v_transfer_allowed boolean :=
    coalesce(pg_catalog.current_setting('app.allow_admin_transfer', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  select o.created_at
    into v_org_created_at
  from public.organizations o
  where o.id = old.organization_id;

  v_is_creator_record := v_org_created_at is not null
    and old.created_at = v_org_created_at;

  if not v_is_creator_record then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    raise exception using errcode = '42501',
      message = 'The original company-creator membership is a permanent audit record and cannot be deleted.';
  end if;

  if new.organization_id is distinct from old.organization_id
     or new.user_id is distinct from old.user_id
     or new.created_at is distinct from old.created_at
     or new.role_id is distinct from old.role_id then
    raise exception using errcode = '42501',
      message = 'The original company-creator membership identity is immutable.';
  end if;

  if old.is_active and not new.is_active and not v_transfer_allowed then
    raise exception using errcode = '42501',
      message = 'The original Administrator can only be deactivated during an Administrator handover.';
  end if;

  if not old.is_active and new.is_active then
    raise exception using errcode = '42501',
      message = 'The permanent company-creator record cannot be reactivated. Add the user with a non-Administrator role if they need to rejoin.';
  end if;

  return new;
end;
$$;

drop trigger if exists organization_users_guard_creator_record on public.organization_users;
create trigger organization_users_guard_creator_record
before update or delete on public.organization_users
for each row execute function public.guard_organization_creator_membership();

-- The founder marker depends on organizations.created_at, so that timestamp
-- must itself be immutable even for trusted server-side maintenance paths.
create or replace function public.guard_organization_created_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.created_at is distinct from old.created_at then
    raise exception using errcode = '42501',
      message = 'Organization creation timestamp is immutable because it anchors the permanent company-creator record.';
  end if;
  return new;
end;
$$;

drop trigger if exists organizations_guard_created_at on public.organizations;
create trigger organizations_guard_created_at
before update of created_at on public.organizations
for each row execute function public.guard_organization_created_at();

revoke all on function public.guard_organization_created_at() from public, anon, authenticated;

-- Enforce exactly one active Administrator per company and permit assigning
-- the system Administrator role only through the create/transfer RPCs.
create or replace function public.guard_administrator_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_is_admin boolean := false;
  v_old_is_admin boolean := false;
  v_active_admins integer := 0;
  v_org_id uuid;
  v_old_id uuid;
  v_needs_admin_claim boolean := false;
  v_transfer_allowed boolean :=
    coalesce(pg_catalog.current_setting('app.allow_admin_transfer', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    v_org_id := new.organization_id;
  elsif tg_op = 'DELETE' then
    v_org_id := old.organization_id;
    v_old_id := old.id;
  else
    v_org_id := new.organization_id;
    v_old_id := old.id;
  end if;

  if tg_op <> 'DELETE' then
    select (r.is_system_role and r.name = 'Administrator')
      into v_new_is_admin
    from public.roles r
    where r.id = new.role_id
      and r.organization_id = new.organization_id;
    v_new_is_admin := coalesce(v_new_is_admin, false);
  end if;

  if tg_op <> 'INSERT' then
    select (r.is_system_role and r.name = 'Administrator')
      into v_old_is_admin
    from public.roles r
    where r.id = old.role_id
      and r.organization_id = old.organization_id;
    v_old_is_admin := coalesce(v_old_is_admin, false);
  end if;

  perform 1 from public.organizations o where o.id = v_org_id for update;

  if tg_op <> 'DELETE' then
    if new.is_active and v_new_is_admin then
      if tg_op = 'INSERT' then
        v_needs_admin_claim := true;
      else
        v_needs_admin_claim :=
          not old.is_active
          or not v_old_is_admin
          or old.organization_id is distinct from new.organization_id
          or old.role_id is distinct from new.role_id;
      end if;
    end if;
  end if;

  if v_needs_admin_claim then
    select count(*) into v_active_admins
    from public.organization_users ou
    join public.roles r
      on r.id = ou.role_id and r.organization_id = ou.organization_id
    where ou.organization_id = new.organization_id
      and ou.is_active
      and r.is_system_role
      and r.name = 'Administrator'
      and (v_old_id is null or ou.id <> v_old_id);

    if v_active_admins > 0 then
      raise exception using errcode = '23505',
        message = 'This organization already has an active Administrator.';
    end if;

    if not v_transfer_allowed then
      raise exception using errcode = '42501',
        message = 'Administrator membership can only be created or assigned by the organization creation or Administrator-transfer workflow.';
    end if;
  end if;

  if tg_op = 'DELETE' then
    if v_old_is_admin and old.is_active then
      select count(*) into v_active_admins
      from public.organization_users ou
      join public.roles r
        on r.id = ou.role_id and r.organization_id = ou.organization_id
      where ou.organization_id = old.organization_id
        and ou.is_active
        and r.is_system_role
        and r.name = 'Administrator'
        and ou.id <> old.id;

      if v_active_admins < 1 and not v_transfer_allowed then
        raise exception using errcode = '23514',
          message = 'An organization must retain an active Administrator.';
      end if;
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if old.is_active and v_old_is_admin
       and (not new.is_active
         or not v_new_is_admin
         or new.organization_id is distinct from old.organization_id
         or new.role_id is distinct from old.role_id) then
      select count(*) into v_active_admins
      from public.organization_users ou
      join public.roles r
        on r.id = ou.role_id and r.organization_id = ou.organization_id
      where ou.organization_id = old.organization_id
        and ou.is_active
        and r.is_system_role
        and r.name = 'Administrator'
        and ou.id <> old.id;

      if v_active_admins < 1 and not v_transfer_allowed then
        raise exception using errcode = '23514',
          message = 'An organization must retain an active Administrator.';
      end if;
    end if;
  end if;

  return new;
end;
$$;
revoke all on function public.guard_organization_creator_membership() from public, anon, authenticated;
revoke all on function public.guard_administrator_membership() from public, anon, authenticated;

-- One company per user for life. The creator membership is retained forever,
-- including after deactivation or Administrator transfer. Locking the Auth
-- user row serializes concurrent creation attempts for the same account.
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
    raise exception using errcode = '42501',
      message = 'Authentication is required to create an organization.';
  end if;

  perform 1 from auth.users u where u.id = v_user_id for update;
  if not found then
    raise exception using errcode = '42501', message = 'Authenticated user was not found.';
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
    select 1 from public.organization_users ou
    where ou.user_id = v_user_id and ou.is_active
  ) then
    raise exception using errcode = '23505',
      message = 'Deactivate your current company membership before creating a new company.';
  end if;

  if p_name is null or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 160 then
    raise exception using errcode = '22023',
      message = 'Organization name must contain between 1 and 160 characters.';
  end if;
  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    raise exception using errcode = '22023',
      message = 'Currency must be a three-letter uppercase ISO currency code.';
  end if;
  if p_timezone is null or not exists (
    select 1 from pg_catalog.pg_timezone_names tz
    where tz.name = pg_catalog.btrim(p_timezone)
  ) then
    raise exception using errcode = '22023',
      message = 'Timezone must be a valid PostgreSQL timezone name.';
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

  perform pg_catalog.set_config('app.allow_admin_transfer', 'on', true);
  insert into public.organization_users (organization_id, user_id, role_id, is_active)
  values (v_organization_id, v_user_id, v_role_id, true);

  -- Preserve the existing bootstrap behavior: initialize the company's
  -- default chart of accounts as part of the same transaction.
  perform public.seed_default_chart_of_accounts(v_organization_id);

  return v_organization_id;
end;
$$;
revoke all on function public.create_organization_with_admin(text,text,text) from public, anon;
grant execute on function public.create_organization_with_admin(text,text,text) to authenticated;

-- Keep the global permission catalogue description aligned with the
-- Administrator-only control-plane policy.
update public.permissions
set description = case permission_key
  when 'users.manage' then 'Administrator-only control-plane permission for organization membership.'
  when 'roles.manage' then 'Administrator-only control-plane permission for organization roles.'
  else description
end
where permission_key in ('users.manage', 'roles.manage');

-- Retire legacy custom-role grants for control-plane permissions. These keys
-- no longer confer any administrative authority to ordinary custom roles.
delete from public.role_permissions rp
using public.roles r, public.permissions p
where rp.role_id = r.id
  and rp.permission_id = p.id
  and not r.is_system_role
  and p.permission_key in ('users.manage', 'roles.manage');

-- All administrative operations are Administrator-exclusive, independent of
-- permissions accidentally granted to an ordinary custom role.
create or replace function public.validate_role_assignment(
  p_organization_id uuid,
  p_role_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can assign member roles.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if not exists (
    select 1 from public.roles r
    where r.organization_id = p_organization_id
      and r.id = p_role_id
      and r.status = 'active'
      and not r.is_system_role
  ) then
    raise exception using errcode = '23503',
      message = 'Select an active custom role belonging to this organization. System roles cannot be assigned through this operation.';
  end if;
end;
$function$;
revoke all on function public.validate_role_assignment(uuid,uuid) from public, anon;
grant execute on function public.validate_role_assignment(uuid,uuid) to authenticated;

-- Add an existing verified Auth user only. No Auth Admin invitation or account
-- creation is performed. An inactive historical membership is reactivated in
-- place, unless it is the permanent creator record.
create or replace function public.add_organization_user_by_email(
  p_organization_id uuid,
  p_email text,
  p_role_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid;
  v_membership_id uuid;
  v_existing_active_org uuid;
  v_is_creator boolean;
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can add members.';
  end if;

  if p_email is null
     or pg_catalog.length(pg_catalog.btrim(p_email)) not between 3 and 254
     or pg_catalog.strpos(pg_catalog.btrim(p_email), '@') < 2 then
    raise exception using errcode = '22023', message = 'A valid user email address is required.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if not exists (
    select 1 from public.roles r
    where r.organization_id = p_organization_id
      and r.id = p_role_id
      and r.status = 'active'
      and not r.is_system_role
  ) then
    raise exception using errcode = '23503',
      message = 'The selected role must be an active custom role in this organization.';
  end if;

  select u.id into v_user_id
  from auth.users u
  where pg_catalog.lower(u.email) = pg_catalog.lower(pg_catalog.btrim(p_email))
    and u.email_confirmed_at is not null
  order by u.created_at
  limit 1;

  if v_user_id is null then
    raise exception using errcode = 'P0002',
      message = 'No verified account exists for this email. Ask the person to sign up for Zero ERP and verify their email before adding them.';
  end if;

  perform 1 from auth.users u where u.id = v_user_id for update;

  select ou.organization_id into v_existing_active_org
  from public.organization_users ou
  where ou.user_id = v_user_id and ou.is_active
  limit 1;

  if v_existing_active_org is not null and v_existing_active_org <> p_organization_id then
    raise exception using errcode = '23505',
      message = 'This user is already an active member of another company. Their current company Administrator must deactivate that membership first.';
  elsif v_existing_active_org = p_organization_id then
    raise exception using errcode = '23514',
      message = 'This user is already an active member of this organization.';
  end if;

  select public.is_organization_creator(p_organization_id, v_user_id)
    into v_is_creator;

  if v_is_creator then
    raise exception using errcode = '23514',
      message = 'The permanent company-creator record cannot be reactivated as a regular membership.';
  end if;

  select ou.id into v_membership_id
  from public.organization_users ou
  where ou.organization_id = p_organization_id
    and ou.user_id = v_user_id
  for update;

  if found then
    update public.organization_users
    set role_id = p_role_id, is_active = true, updated_at = pg_catalog.now()
    where id = v_membership_id;
    return v_membership_id;
  end if;

  insert into public.organization_users (organization_id, user_id, role_id, is_active)
  values (p_organization_id, v_user_id, p_role_id, true)
  returning id into v_membership_id;
  return v_membership_id;
exception
  when unique_violation then
    if exists (
      select 1 from public.organization_users ou
      where ou.user_id = v_user_id and ou.is_active
        and ou.organization_id <> p_organization_id
    ) then
      raise exception using errcode = '23505',
        message = 'This user is already an active member of another company. Their current company Administrator must deactivate that membership first.';
    end if;
    raise exception using errcode = '23505',
      message = 'This user already has a membership record in this organization.';
end;
$function$;
revoke all on function public.add_organization_user_by_email(uuid,text,uuid) from public, anon;
grant execute on function public.add_organization_user_by_email(uuid,text,uuid) to authenticated;

create or replace function public.update_organization_user_role(
  p_organization_id uuid,
  p_membership_id uuid,
  p_role_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can change member roles.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if not exists (
    select 1 from public.roles r
    where r.organization_id = p_organization_id
      and r.id = p_role_id
      and r.status = 'active'
      and not r.is_system_role
  ) then
    raise exception using errcode = '23503',
      message = 'Only an active custom role in this organization can be assigned. Use the Administrator-transfer operation to change the Administrator.';
  end if;

  update public.organization_users
  set role_id = p_role_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_membership_id
    and is_active;
  if not found then
    raise exception using errcode = '23503',
      message = 'Active organization membership was not found.';
  end if;
end;
$function$;
revoke all on function public.update_organization_user_role(uuid,uuid,uuid) from public, anon;
grant execute on function public.update_organization_user_role(uuid,uuid,uuid) to authenticated;

create or replace function public.set_organization_user_active(
  p_organization_id uuid,
  p_membership_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_role_id uuid;
  v_is_system boolean;
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can activate or deactivate members.';
  end if;
  if p_is_active is null then
    raise exception using errcode = '22023', message = 'Member active state is required.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  select ou.role_id, r.is_system_role
    into v_role_id, v_is_system
  from public.organization_users ou
  join public.roles r
    on r.id = ou.role_id and r.organization_id = ou.organization_id
  where ou.organization_id = p_organization_id
    and ou.id = p_membership_id
  for update of ou;
  if not found then
    raise exception using errcode = '23503', message = 'Organization membership was not found.';
  end if;

  if p_is_active and v_is_system then
    raise exception using errcode = '42501',
      message = 'An inactive Administrator membership cannot be reactivated directly. Use the Administrator-transfer operation.';
  end if;

  if p_is_active and not exists (
    select 1 from public.roles r
    where r.organization_id = p_organization_id
      and r.id = v_role_id and r.status = 'active'
  ) then
    raise exception using errcode = '23514',
      message = 'A member cannot be reactivated while their assigned role is inactive.';
  end if;

  update public.organization_users
  set is_active = p_is_active, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_membership_id;
exception when unique_violation then
  raise exception using errcode = '23505',
    message = 'This user already has an active membership in another company. Their current company Administrator must deactivate that membership first.';
end;
$function$;
revoke all on function public.set_organization_user_active(uuid,uuid,boolean) from public, anon;
grant execute on function public.set_organization_user_active(uuid,uuid,boolean) to authenticated;

-- Transfer the single active Administrator to an existing active member.
-- The previous Administrator is deactivated, while the original creator row
-- remains permanently present and immutable. The target must already belong
-- to this company; cross-company membership constraints remain in force.
create or replace function public.transfer_organization_administrator(
  p_organization_id uuid,
  p_new_administrator_membership_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_old_admin_membership_id uuid;
  v_admin_role_id uuid;
  v_target_role_id uuid;
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the current organization Administrator can transfer Administrator authority.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  select ou.id, ou.role_id
    into v_old_admin_membership_id, v_admin_role_id
  from public.organization_users ou
  join public.roles r
    on r.id = ou.role_id and r.organization_id = ou.organization_id
  where ou.organization_id = p_organization_id
    and ou.is_active
    and r.is_system_role
    and r.name = 'Administrator'
  for update of ou;

  if not found then
    raise exception using errcode = '23514',
      message = 'The organization does not have an active Administrator to transfer.';
  end if;

  select ou.role_id into v_target_role_id
  from public.organization_users ou
  join public.roles r
    on r.id = ou.role_id and r.organization_id = ou.organization_id
  where ou.organization_id = p_organization_id
    and ou.id = p_new_administrator_membership_id
    and ou.is_active
    and r.status = 'active'
    and ou.id <> v_old_admin_membership_id
    and not r.is_system_role
  for update of ou;

  if not found then
    raise exception using errcode = '23503',
      message = 'The new Administrator must be a different active member of this organization.';
  end if;

  perform pg_catalog.set_config('app.allow_admin_transfer', 'on', true);

  update public.organization_users
  set is_active = false, updated_at = pg_catalog.now()
  where organization_id = p_organization_id
    and id = v_old_admin_membership_id;

  update public.organization_users
  set role_id = v_admin_role_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id
    and id = p_new_administrator_membership_id;
end;
$function$;
revoke all on function public.transfer_organization_administrator(uuid,uuid) from public, anon;
grant execute on function public.transfer_organization_administrator(uuid,uuid) to authenticated;

-- Custom roles can never acquire Administrator-only control-plane privileges.
create or replace function public.create_custom_role(
  p_organization_id uuid,
  p_name text,
  p_permission_keys text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_role_id uuid;
  v_requested integer;
  v_inserted integer;
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can create custom roles.';
  end if;
  if p_name is null
     or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 100
     or p_permission_keys is null then
    raise exception using errcode = '22023',
      message = 'Role name and permission list are required.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if exists (
    select 1 from unnest(p_permission_keys) as x(permission_key)
    where x.permission_key in ('users.manage', 'roles.manage')
  ) then
    raise exception using errcode = '42501',
      message = 'Member and role administration privileges are reserved exclusively for the system Administrator.';
  end if;

  insert into public.roles(organization_id, name, status, is_system_role)
  values (p_organization_id, pg_catalog.btrim(p_name), 'active', false)
  returning id into v_role_id;

  select count(distinct x.permission_key)
    into v_requested
  from unnest(p_permission_keys) as x(permission_key);

  insert into public.role_permissions(role_id, permission_id)
  select v_role_id, p.id
  from public.permissions p
  where p.permission_key = any(p_permission_keys);

  get diagnostics v_inserted = row_count;
  if v_inserted <> v_requested then
    raise exception using errcode = '22023',
      message = 'One or more permission keys do not exist.';
  end if;
  return v_role_id;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'A role with this name already exists.';
end;
$function$;
revoke all on function public.create_custom_role(uuid,text,text[]) from public, anon;
grant execute on function public.create_custom_role(uuid,text,text[]) to authenticated;

create or replace function public.replace_custom_role_permissions(
  p_organization_id uuid,
  p_role_id uuid,
  p_permission_keys text[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_system boolean;
  v_requested integer;
  v_inserted integer;
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can change role permissions.';
  end if;
  if p_permission_keys is null then
    raise exception using errcode = '22023', message = 'Permission list is required.';
  end if;
  if exists (
    select 1 from unnest(p_permission_keys) as x(permission_key)
    where x.permission_key in ('users.manage', 'roles.manage')
  ) then
    raise exception using errcode = '42501',
      message = 'Member and role administration privileges are reserved exclusively for the system Administrator.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  select r.is_system_role into v_system
  from public.roles r
  where r.organization_id = p_organization_id
    and r.id = p_role_id and r.status = 'active'
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active role was not found.';
  end if;
  if v_system then
    raise exception using errcode = '42501',
      message = 'System Administrator permissions are immutable.';
  end if;

  select count(distinct x.permission_key)
    into v_requested
  from unnest(p_permission_keys) as x(permission_key);

  delete from public.role_permissions where role_id = p_role_id;
  insert into public.role_permissions(role_id, permission_id)
  select p_role_id, p.id
  from public.permissions p
  where p.permission_key = any(p_permission_keys);

  get diagnostics v_inserted = row_count;
  if v_inserted <> v_requested then
    raise exception using errcode = '22023',
      message = 'One or more permission keys do not exist.';
  end if;
end;
$function$;
revoke all on function public.replace_custom_role_permissions(uuid,uuid,text[]) from public, anon;
grant execute on function public.replace_custom_role_permissions(uuid,uuid,text[]) to authenticated;

create or replace function public.update_custom_role(
  p_organization_id uuid,
  p_role_id uuid,
  p_name text,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_system boolean;
begin
  if (select auth.uid()) is null or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can update custom roles.';
  end if;
  if p_name is null
     or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 100
     or p_status is null
     or p_status not in ('active', 'inactive') then
    raise exception using errcode = '22023',
      message = 'Role name or status is invalid.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  select r.is_system_role into v_system
  from public.roles r
  where r.organization_id = p_organization_id and r.id = p_role_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Role was not found in this organization.';
  end if;
  if v_system then
    raise exception using errcode = '42501',
      message = 'System roles cannot be renamed or deactivated.';
  end if;

  if p_status = 'inactive' and exists (
    select 1 from public.organization_users ou
    where ou.organization_id = p_organization_id
      and ou.role_id = p_role_id and ou.is_active
  ) then
    raise exception using errcode = '23514',
      message = 'Reassign or deactivate all active members before deactivating this role.';
  end if;

  update public.roles
  set name = pg_catalog.btrim(p_name), status = p_status
  where organization_id = p_organization_id and id = p_role_id;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'A role with this name already exists.';
end;
$function$;
revoke all on function public.update_custom_role(uuid,uuid,text,text) from public, anon;
grant execute on function public.update_custom_role(uuid,uuid,text,text) to authenticated;

-- Company profile/security settings are also Administrator-exclusive.
create or replace function public.update_organization_profile(
  p_organization_id uuid,
  p_name text,
  p_phone text,
  p_email text,
  p_address text,
  p_city text,
  p_country text,
  p_currency text,
  p_timezone text,
  p_tin text,
  p_bin text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null
     or not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the organization Administrator can update company details.';
  end if;

  if p_name is null
     or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 160
     or p_currency is null
     or p_currency !~ '^[A-Z]{3}$'
     or p_timezone is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names tz
       where tz.name = pg_catalog.btrim(p_timezone)
     ) then
    raise exception using errcode = '22023',
      message = 'Organization name, ISO currency, or timezone is invalid.';
  end if;

  update public.organizations
  set name = pg_catalog.btrim(p_name),
      phone = nullif(pg_catalog.btrim(coalesce(p_phone,'')), ''),
      email = nullif(pg_catalog.btrim(coalesce(p_email,'')), ''),
      address = nullif(pg_catalog.btrim(coalesce(p_address,'')), ''),
      city = nullif(pg_catalog.btrim(coalesce(p_city,'')), ''),
      country = nullif(pg_catalog.btrim(coalesce(p_country,'')), ''),
      currency = p_currency,
      timezone = pg_catalog.btrim(p_timezone),
      tin = nullif(pg_catalog.btrim(coalesce(p_tin,'')), ''),
      bin = nullif(pg_catalog.btrim(coalesce(p_bin,'')), '')
  where id = p_organization_id and is_active;

  if not found then
    raise exception using errcode = '23503',
      message = 'Active organization was not found.';
  end if;
end;
$function$;
revoke all on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) to authenticated;

-- Invitation-only finalization is no longer part of the application contract.
drop function if exists public.complete_organization_invitation(uuid,uuid,uuid,uuid);

commit;
