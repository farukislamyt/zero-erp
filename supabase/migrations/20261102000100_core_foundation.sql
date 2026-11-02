-- Zero ERP: tenant, RBAC, accounting setup, and master-data foundation
-- Migration: 20261102000100_core_foundation.sql
-- Apply through Supabase CLI after reviewing against the target project's existing schema.
-- This migration creates the foundational objects only; transaction tables and their RPCs
-- are introduced in subsequent migrations.

begin;

create extension if not exists pgcrypto with schema extensions;

-- Shared timestamp trigger function.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

-- Tenant root.
create table public.organizations (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 160),
  phone text,
  email text,
  address text,
  city text,
  country text,
  currency char(3) not null default 'BDT',
  timezone text not null default 'Asia/Dhaka',
  tin text,
  bin text,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint organizations_currency_format_chk check (currency ~ '^[A-Z]{3}$')
);

create table public.roles (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 100),
  status text not null default 'active' check (status in ('active', 'inactive')),
  is_system_role boolean not null default false,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint roles_org_id_id_uq unique (organization_id, id),
  constraint roles_org_name_uq unique (organization_id, name)
);

-- Global, system-managed permission catalog.
create table public.permissions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  permission_key text not null unique
    check (permission_key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 120),
  description text,
  module text not null check (pg_catalog.length(pg_catalog.btrim(module)) between 1 and 80),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

create table public.organization_users (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint organization_users_org_id_id_uq unique (organization_id, id),
  constraint organization_users_org_user_uq unique (organization_id, user_id),
  constraint organization_users_role_same_org_fk
    foreign key (organization_id, role_id)
    references public.roles (organization_id, id)
    on delete restrict
);

create table public.role_permissions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  constraint role_permissions_role_permission_uq unique (role_id, permission_id)
);

create table public.accounting_periods (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 100),
  start_date date not null,
  end_date date not null,
  status text not null default 'open' check (status in ('open', 'closed')),
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint accounting_periods_date_range_chk check (end_date >= start_date),
  constraint accounting_periods_org_id_id_uq unique (organization_id, id),
  constraint accounting_periods_org_name_uq unique (organization_id, name),
  constraint accounting_periods_closed_state_chk
    check ((status = 'open' and closed_at is null) or status = 'closed')
);

create table public.accounts (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  account_code text not null check (pg_catalog.length(pg_catalog.btrim(account_code)) between 1 and 40),
  account_name text not null check (pg_catalog.length(pg_catalog.btrim(account_name)) between 1 and 160),
  account_type text not null
    check (account_type in ('asset', 'liability', 'equity', 'revenue', 'expense')),
  parent_account_id uuid,
  normal_balance text not null check (normal_balance in ('debit', 'credit')),
  is_control_account boolean not null default false,
  is_system_account boolean not null default false,
  is_postable boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint accounts_org_id_id_uq unique (organization_id, id),
  constraint accounts_org_code_uq unique (organization_id, account_code),
  constraint accounts_parent_same_org_fk
    foreign key (organization_id, parent_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint accounts_not_own_parent_chk check (parent_account_id is distinct from id)
);

create table public.units_of_measure (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 80),
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint units_of_measure_org_id_id_uq unique (organization_id, id),
  constraint units_of_measure_org_name_uq unique (organization_id, name)
);

create table public.contacts (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contact_number text not null check (pg_catalog.length(pg_catalog.btrim(contact_number)) between 1 and 50),
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 180),
  phone text,
  email text,
  address text,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint contacts_org_id_id_uq unique (organization_id, id),
  constraint contacts_org_number_uq unique (organization_id, contact_number)
);

create table public.products (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_code text not null check (pg_catalog.length(pg_catalog.btrim(product_code)) between 1 and 60),
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 180),
  unit_id uuid not null,
  inventory_account_id uuid,
  sales_account_id uuid,
  cogs_account_id uuid,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint products_org_id_id_uq unique (organization_id, id),
  constraint products_org_code_uq unique (organization_id, product_code),
  constraint products_unit_same_org_fk
    foreign key (organization_id, unit_id)
    references public.units_of_measure (organization_id, id)
    on delete restrict,
  constraint products_inventory_account_same_org_fk
    foreign key (organization_id, inventory_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint products_sales_account_same_org_fk
    foreign key (organization_id, sales_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint products_cogs_account_same_org_fk
    foreign key (organization_id, cogs_account_id)
    references public.accounts (organization_id, id)
    on delete restrict
);

create table public.expense_categories (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  category_code text not null check (pg_catalog.length(pg_catalog.btrim(category_code)) between 1 and 40),
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 120),
  expense_account_id uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint expense_categories_org_id_id_uq unique (organization_id, id),
  constraint expense_categories_org_code_uq unique (organization_id, category_code),
  constraint expense_categories_account_same_org_fk
    foreign key (organization_id, expense_account_id)
    references public.accounts (organization_id, id)
    on delete restrict
);

create table public.number_sequences (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  document_type text not null check (pg_catalog.length(pg_catalog.btrim(document_type)) between 1 and 60),
  prefix text not null default '',
  next_number bigint not null default 1 check (next_number > 0),
  padding smallint not null default 5 check (padding between 1 and 18),
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint number_sequences_org_id_id_uq unique (organization_id, id),
  constraint number_sequences_org_type_uq unique (organization_id, document_type)
);

-- Frequently used foreign-key and tenant filters.
create index organization_users_user_active_idx
  on public.organization_users (user_id, is_active);
create index organization_users_role_idx
  on public.organization_users (role_id);
create index roles_org_status_idx on public.roles (organization_id, status);
create index role_permissions_permission_idx on public.role_permissions (permission_id);
create index accounting_periods_org_dates_idx
  on public.accounting_periods (organization_id, start_date, end_date);
create index accounts_org_parent_idx on public.accounts (organization_id, parent_account_id);
create index contacts_org_name_idx on public.contacts (organization_id, name);
create index products_org_name_idx on public.products (organization_id, name);
create index expense_categories_org_name_idx on public.expense_categories (organization_id, name);

-- Maintain updated_at consistently.
create trigger organizations_set_updated_at before update on public.organizations
for each row execute function public.set_updated_at();
create trigger roles_set_updated_at before update on public.roles
for each row execute function public.set_updated_at();
create trigger permissions_set_updated_at before update on public.permissions
for each row execute function public.set_updated_at();
create trigger organization_users_set_updated_at before update on public.organization_users
for each row execute function public.set_updated_at();
create trigger accounting_periods_set_updated_at before update on public.accounting_periods
for each row execute function public.set_updated_at();
create trigger accounts_set_updated_at before update on public.accounts
for each row execute function public.set_updated_at();
create trigger units_of_measure_set_updated_at before update on public.units_of_measure
for each row execute function public.set_updated_at();
create trigger contacts_set_updated_at before update on public.contacts
for each row execute function public.set_updated_at();
create trigger products_set_updated_at before update on public.products
for each row execute function public.set_updated_at();
create trigger expense_categories_set_updated_at before update on public.expense_categories
for each row execute function public.set_updated_at();
create trigger number_sequences_set_updated_at before update on public.number_sequences
for each row execute function public.set_updated_at();

-- Security-definer helpers prevent RLS recursion when policies inspect membership.
-- They intentionally return false for anonymous callers.
create or replace function public.is_active_org_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_users ou
    join public.organizations o on o.id = ou.organization_id
    where ou.organization_id = p_organization_id
      and ou.user_id = (select auth.uid())
      and ou.is_active
      and o.is_active
  );
$$;

create or replace function public.has_org_permission(
  p_organization_id uuid,
  p_permission_key text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_users ou
    join public.roles r
      on r.id = ou.role_id
     and r.organization_id = ou.organization_id
    join public.role_permissions rp on rp.role_id = r.id
    join public.permissions p on p.id = rp.permission_id
    where ou.organization_id = p_organization_id
      and ou.user_id = (select auth.uid())
      and ou.is_active
      and r.status = 'active'
      and p.permission_key = p_permission_key
  );
$$;

revoke all on function public.is_active_org_member(uuid) from public, anon;
revoke all on function public.has_org_permission(uuid, text) from public, anon;
grant execute on function public.is_active_org_member(uuid) to authenticated;
grant execute on function public.has_org_permission(uuid, text) to authenticated;

-- RLS: tenant-owned foundation tables are not accessible by default.
alter table public.organizations enable row level security;
alter table public.organization_users enable row level security;
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.accounting_periods enable row level security;
alter table public.accounts enable row level security;
alter table public.units_of_measure enable row level security;
alter table public.contacts enable row level security;
alter table public.products enable row level security;
alter table public.expense_categories enable row level security;
alter table public.number_sequences enable row level security;

-- Read access is scoped to active membership. Mutations are introduced through
-- permission-checked RPCs in later migrations; no broad client write policies exist.
create policy organizations_select_member
  on public.organizations for select to authenticated
  using (public.is_active_org_member(id));

create policy organization_users_select_member_or_self
  on public.organization_users for select to authenticated
  using (user_id = (select auth.uid()) or public.is_active_org_member(organization_id));

create policy roles_select_member
  on public.roles for select to authenticated
  using (public.is_active_org_member(organization_id));

create policy permissions_select_authenticated
  on public.permissions for select to authenticated
  using (true);

create policy role_permissions_select_member
  on public.role_permissions for select to authenticated
  using (
    exists (
      select 1
      from public.roles r
      where r.id = role_permissions.role_id
        and public.is_active_org_member(r.organization_id)
    )
  );

create policy accounting_periods_select_member
  on public.accounting_periods for select to authenticated
  using (public.is_active_org_member(organization_id));

create policy accounts_select_member
  on public.accounts for select to authenticated
  using (public.is_active_org_member(organization_id));

create policy units_of_measure_select_member
  on public.units_of_measure for select to authenticated
  using (public.is_active_org_member(organization_id));

create policy contacts_select_member
  on public.contacts for select to authenticated
  using (public.is_active_org_member(organization_id));

create policy products_select_member
  on public.products for select to authenticated
  using (public.is_active_org_member(organization_id));

create policy expense_categories_select_member
  on public.expense_categories for select to authenticated
  using (public.is_active_org_member(organization_id));

create policy number_sequences_select_member
  on public.number_sequences for select to authenticated
  using (public.is_active_org_member(organization_id));

-- Remove default privileges from anon and keep writes unavailable to browser roles
-- until permission-checked RPC contracts are implemented.
revoke all on public.organizations, public.organization_users, public.roles,
  public.permissions, public.role_permissions, public.accounting_periods,
  public.accounts, public.units_of_measure, public.contacts, public.products,
  public.expense_categories, public.number_sequences
from anon;

grant select on public.organizations, public.organization_users, public.roles,
  public.permissions, public.role_permissions, public.accounting_periods,
  public.accounts, public.units_of_measure, public.contacts, public.products,
  public.expense_categories, public.number_sequences
to authenticated;

commit;
