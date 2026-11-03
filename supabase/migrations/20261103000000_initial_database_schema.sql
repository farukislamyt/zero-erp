-- =============================================================================
-- ZERO ERP — INITIAL DATABASE SCHEMA
-- =============================================================================
-- Canonical one-file bootstrap schema for a new, empty Supabase database.
-- Apply once to a NEW / EMPTY Supabase PostgreSQL project after Supabase Auth is
-- available. This file is not an incremental migration for an existing database.
-- It intentionally uses one transaction so a failed bootstrap rolls back fully.
-- Project defaults: BDT currency; Asia/Dhaka timezone.
-- =============================================================================

begin;


-- ============================================================================
-- CORE FOUNDATION
-- ============================================================================


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
  organization_id uuid not null references public.organizations(id) on delete restrict,
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
  organization_id uuid not null references public.organizations(id) on delete restrict,
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

create table public.accounts (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
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

create or replace function public.prevent_account_hierarchy_cycle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.parent_account_id is null then return new; end if;
  if exists (
    with recursive ancestors(id, parent_account_id, path, cycle) as (
      select a.id, a.parent_account_id, array[a.id], false
      from public.accounts a
      where a.organization_id = new.organization_id and a.id = new.parent_account_id
      union all
      select p.id, p.parent_account_id, ancestors.path || p.id, p.id = any(ancestors.path)
      from ancestors join public.accounts p
        on p.organization_id = new.organization_id and p.id = ancestors.parent_account_id
      where not ancestors.cycle
    ) select 1 from ancestors where id = new.id or cycle
  ) then
    raise exception using errcode = '23514', message = 'Account hierarchy cannot contain a cycle.';
  end if;
  return new;
end;
$function$;
revoke all on function public.prevent_account_hierarchy_cycle() from public, anon, authenticated;
create trigger accounts_prevent_hierarchy_cycle
before insert or update of organization_id, parent_account_id on public.accounts
for each row execute function public.prevent_account_hierarchy_cycle();

create table public.units_of_measure (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 80),
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint units_of_measure_org_id_id_uq unique (organization_id, id),
  constraint units_of_measure_org_name_uq unique (organization_id, name)
);

create table public.contacts (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
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
  organization_id uuid not null references public.organizations(id) on delete restrict,
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
  organization_id uuid not null references public.organizations(id) on delete restrict,
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
  organization_id uuid not null references public.organizations(id) on delete restrict,
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
    join public.organizations o
      on o.id = ou.organization_id and o.is_active
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
alter table public.accounts enable row level security;
alter table public.units_of_measure enable row level security;
alter table public.contacts enable row level security;
alter table public.products enable row level security;
alter table public.expense_categories enable row level security;
alter table public.number_sequences enable row level security;

-- Read access requires active membership plus the module's explicit read permission.
-- Browser writes remain disabled; mutations use permission-checked RPCs.
create policy organizations_select_member
  on public.organizations for select to authenticated
  using (public.has_org_permission(id, 'organization.read'));

create policy organization_users_select_member_or_self
  on public.organization_users for select to authenticated
  using (user_id = (select auth.uid()) or public.has_org_permission(organization_id, 'users.read'));

create policy roles_select_member
  on public.roles for select to authenticated
  using (public.has_org_permission(organization_id, 'roles.read'));

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
        and public.has_org_permission(r.organization_id, 'roles.read')
    )
  );


create policy accounts_select_member
  on public.accounts for select to authenticated
  using (public.has_org_permission(organization_id, 'accounts.read'));

create policy units_of_measure_select_member
  on public.units_of_measure for select to authenticated
  using (public.has_org_permission(organization_id, 'products.read'));

create policy contacts_select_member
  on public.contacts for select to authenticated
  using (public.has_org_permission(organization_id, 'contacts.read'));

create policy products_select_member
  on public.products for select to authenticated
  using (public.has_org_permission(organization_id, 'products.read'));

create policy expense_categories_select_member
  on public.expense_categories for select to authenticated
  using (public.has_org_permission(organization_id, 'expenses.read'));

create policy number_sequences_select_member
  on public.number_sequences for select to authenticated
  using (public.has_org_permission(organization_id, 'organization.read'));

-- Remove default privileges from anon and keep writes unavailable to browser roles
-- until permission-checked RPC contracts are implemented.
revoke all on public.organizations, public.organization_users, public.roles,
  public.permissions, public.role_permissions,
  public.accounts, public.units_of_measure, public.contacts, public.products,
  public.expense_categories, public.number_sequences
from anon, authenticated;

grant select on public.organizations, public.organization_users, public.roles,
  public.permissions, public.role_permissions,
  public.accounts, public.units_of_measure, public.contacts, public.products,
  public.expense_categories, public.number_sequences
to authenticated;


-- ============================================================================
-- TRANSACTION SCHEMA
-- ============================================================================

-- Zero ERP: ledger, inventory, purchasing, sales, expenses, and payments
-- All financial and inventory writes remain unavailable to client roles until the
-- posting and allocation RPCs have been implemented and granted explicitly.

create table public.journal_entries (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  entry_number text not null check (pg_catalog.length(pg_catalog.btrim(entry_number)) between 1 and 80),
  entry_date date not null,
  entry_type text not null
    check (entry_type in ('manual', 'purchase', 'purchase_return', 'sale', 'sales_return', 'expense', 'payment', 'reversal', 'opening_balance', 'adjustment')),
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'reversed', 'void')),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  posted_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  reference_type text,
  reference_id uuid,
  description text,
  posted_at timestamptz,
  reversal_of_id uuid,
  reversal_journal_entry_id uuid,
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint journal_entries_org_id_id_uq unique (organization_id, id),
  constraint journal_entries_org_number_uq unique (organization_id, entry_number),
  constraint journal_entries_reversal_same_org_fk
    foreign key (organization_id, reversal_of_id)
    references public.journal_entries (organization_id, id)
    on delete restrict,
  constraint journal_entries_not_self_reversal_chk check (reversal_of_id is distinct from id),
  constraint journal_entries_reversal_entry_same_org_fk
    foreign key (organization_id, reversal_journal_entry_id)
    references public.journal_entries (organization_id, id) on delete restrict,
  constraint journal_entries_reversed_audit_chk
    check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null)),
  constraint journal_entries_posted_timestamp_chk
    check ((status in ('posted', 'reversed') and posted_at is not null) or status in ('draft', 'confirmed', 'void')),
  constraint journal_entries_confirmed_timestamp_chk
    check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint journal_entries_void_timestamp_chk
    check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))
);

create table public.account_transactions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  journal_entry_id uuid not null,
  account_id uuid not null,
  line_number integer not null check (line_number > 0),
  description text,
  debit numeric(20, 4) not null default 0 check (debit >= 0),
  credit numeric(20, 4) not null default 0 check (credit >= 0),
  contact_id uuid,
  created_at timestamptz not null default pg_catalog.now(),
  constraint account_transactions_org_id_id_uq unique (organization_id, id),
  constraint account_transactions_line_uq unique (organization_id, journal_entry_id, line_number),
  constraint account_transactions_journal_same_org_fk
    foreign key (organization_id, journal_entry_id)
    references public.journal_entries (organization_id, id)
    on delete restrict,
  constraint account_transactions_account_same_org_fk
    foreign key (organization_id, account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint account_transactions_contact_same_org_fk
    foreign key (organization_id, contact_id)
    references public.contacts (organization_id, id)
    on delete restrict,
  constraint account_transactions_one_side_chk check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
  )
);

create table public.inventory_transactions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  transaction_number text not null check (pg_catalog.length(pg_catalog.btrim(transaction_number)) between 1 and 80),
  product_id uuid not null,
  transaction_date date not null,
  transaction_type text not null
    check (transaction_type in ('purchase', 'sale', 'purchase_return', 'sales_return', 'adjustment', 'opening_balance')),
  direction text not null check (direction in ('in', 'out')),
  quantity numeric(20, 6) not null check (quantity > 0),
  unit_cost numeric(20, 6) not null default 0 check (unit_cost >= 0),
  total_value numeric(20, 4) not null default 0 check (total_value >= 0),
  reference_type text,
  reference_id uuid,
  unit_cost_before numeric(20, 6) check (unit_cost_before is null or unit_cost_before >= 0),
  average_cost_after numeric(20, 6) check (average_cost_after is null or average_cost_after >= 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint inventory_transactions_org_id_id_uq unique (organization_id, id),
  constraint inventory_transactions_org_number_uq unique (organization_id, transaction_number),
  constraint inventory_transactions_product_same_org_fk
    foreign key (organization_id, product_id)
    references public.products (organization_id, id)
    on delete restrict
);

create table public.inventory_balances (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  product_id uuid not null,
  quantity numeric(20, 6) not null default 0 check (quantity >= 0),
  average_cost numeric(20, 6) not null default 0 check (average_cost >= 0),
  inventory_value numeric(20, 4) not null default 0 check (inventory_value >= 0),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint inventory_balances_org_id_id_uq unique (organization_id, id),
  constraint inventory_balances_product_uq unique (organization_id, product_id),
  constraint inventory_balances_product_same_org_fk
    foreign key (organization_id, product_id)
    references public.products (organization_id, id)
    on delete restrict
);

create table public.purchase (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  invoice_id text not null check (pg_catalog.length(pg_catalog.btrim(invoice_id)) between 1 and 80),
  supplier_id uuid not null,
  invoice_date date not null,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'partially_returned', 'returned', 'void')),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  posted_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  subtotal numeric(20, 4) not null default 0 check (subtotal >= 0),
  discount_amount numeric(20, 4) not null default 0 check (discount_amount >= 0),
  total_amount numeric(20, 4) not null default 0 check (total_amount >= 0),
  payable_account_id uuid not null,
  posted_journal_entry_id uuid,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint purchase_org_id_id_uq unique (organization_id, id),
  constraint purchase_org_invoice_uq unique (organization_id, invoice_id),
  constraint purchase_supplier_same_org_fk
    foreign key (organization_id, supplier_id)
    references public.contacts (organization_id, id)
    on delete restrict,
  constraint purchase_payable_account_same_org_fk
    foreign key (organization_id, payable_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint purchase_discount_limit_chk check (discount_amount <= subtotal),
  constraint purchase_confirmed_timestamp_chk
    check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint purchase_void_timestamp_chk
    check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))
);

create table public.purchase_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  purchase_id uuid not null,
  line_number integer not null check (line_number > 0),
  product_id uuid not null,
  quantity numeric(20, 6) not null check (quantity > 0),
  unit_cost numeric(20, 6) not null check (unit_cost >= 0),
  line_total numeric(20, 4) not null check (line_total >= 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint purchase_items_org_id_id_uq unique (organization_id, id),
  constraint purchase_items_line_uq unique (organization_id, purchase_id, line_number),
  constraint purchase_items_purchase_same_org_fk
    foreign key (organization_id, purchase_id)
    references public.purchase (organization_id, id)
    on delete restrict,
  constraint purchase_items_product_same_org_fk
    foreign key (organization_id, product_id)
    references public.products (organization_id, id)
    on delete restrict
);

create table public.purchase_returns (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  return_number text not null check (pg_catalog.length(pg_catalog.btrim(return_number)) between 1 and 80),
  purchase_id uuid not null,
  supplier_id uuid not null,
  return_date date not null,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed')),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  posted_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  subtotal numeric(20, 4) not null default 0 check (subtotal >= 0),
  discount_amount numeric(20, 4) not null default 0 check (discount_amount >= 0),
  total_amount numeric(20, 4) not null default 0 check (total_amount >= 0),
  payable_account_id uuid not null,
  purchase_return_variance_account_id uuid,
  posted_journal_entry_id uuid,
  reversal_journal_entry_id uuid,
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint purchase_returns_org_id_id_uq unique (organization_id, id),
  constraint purchase_returns_org_number_uq unique (organization_id, return_number),
  constraint purchase_returns_purchase_same_org_fk
    foreign key (organization_id, purchase_id)
    references public.purchase (organization_id, id)
    on delete restrict,
  constraint purchase_returns_supplier_same_org_fk
    foreign key (organization_id, supplier_id)
    references public.contacts (organization_id, id)
    on delete restrict,
  constraint purchase_returns_account_same_org_fk
    foreign key (organization_id, payable_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint purchase_returns_variance_account_same_org_fk
    foreign key (organization_id, purchase_return_variance_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint purchase_returns_discount_limit_chk check (discount_amount <= subtotal),
  constraint purchase_returns_reversal_entry_same_org_fk
    foreign key (organization_id, reversal_journal_entry_id)
    references public.journal_entries (organization_id, id) on delete restrict,
  constraint purchase_returns_reversed_audit_chk
    check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null)),
    constraint purchase_returns_confirmed_timestamp_chk
    check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint purchase_returns_void_timestamp_chk
    check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))
);

create table public.purchase_return_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  purchase_return_id uuid not null,
  line_number integer not null check (line_number > 0),
  purchase_item_id uuid not null,
  product_id uuid not null,
  quantity numeric(20, 6) not null check (quantity > 0),
  unit_cost numeric(20, 6) not null check (unit_cost >= 0),
  line_total numeric(20, 4) not null check (line_total >= 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint purchase_return_items_org_id_id_uq unique (organization_id, id),
  constraint purchase_return_items_line_uq unique (organization_id, purchase_return_id, line_number),
  constraint purchase_return_items_source_item_uq unique (organization_id, purchase_return_id, purchase_item_id),
  constraint purchase_return_items_return_same_org_fk
    foreign key (organization_id, purchase_return_id)
    references public.purchase_returns (organization_id, id)
    on delete restrict,
  constraint purchase_return_items_purchase_item_same_org_fk
    foreign key (organization_id, purchase_item_id)
    references public.purchase_items (organization_id, id)
    on delete restrict,
  constraint purchase_return_items_product_same_org_fk
    foreign key (organization_id, product_id)
    references public.products (organization_id, id)
    on delete restrict
);

create table public.sales (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  invoice_id text not null check (pg_catalog.length(pg_catalog.btrim(invoice_id)) between 1 and 80),
  customer_id uuid not null,
  invoice_date date not null,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'partially_returned', 'returned', 'void')),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  posted_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  subtotal numeric(20, 4) not null default 0 check (subtotal >= 0),
  discount_amount numeric(20, 4) not null default 0 check (discount_amount >= 0),
  total_amount numeric(20, 4) not null default 0 check (total_amount >= 0),
  receivable_account_id uuid not null,
  posted_journal_entry_id uuid,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint sales_org_id_id_uq unique (organization_id, id),
  constraint sales_org_invoice_uq unique (organization_id, invoice_id),
  constraint sales_customer_same_org_fk
    foreign key (organization_id, customer_id)
    references public.contacts (organization_id, id)
    on delete restrict,
  constraint sales_receivable_account_same_org_fk
    foreign key (organization_id, receivable_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint sales_discount_limit_chk check (discount_amount <= subtotal),
  constraint sales_confirmed_timestamp_chk
    check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint sales_void_timestamp_chk
    check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))
);

create table public.sales_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  sales_id uuid not null,
  line_number integer not null check (line_number > 0),
  product_id uuid not null,
  quantity numeric(20, 6) not null check (quantity > 0),
  unit_price numeric(20, 6) not null check (unit_price >= 0),
  line_total numeric(20, 4) not null check (line_total >= 0),
  cogs_unit_cost numeric(20, 6) not null default 0 check (cogs_unit_cost >= 0),
  cogs_total numeric(20, 4) not null default 0 check (cogs_total >= 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint sales_items_org_id_id_uq unique (organization_id, id),
  constraint sales_items_line_uq unique (organization_id, sales_id, line_number),
  constraint sales_items_sales_same_org_fk
    foreign key (organization_id, sales_id)
    references public.sales (organization_id, id)
    on delete restrict,
  constraint sales_items_product_same_org_fk
    foreign key (organization_id, product_id)
    references public.products (organization_id, id)
    on delete restrict
);

create table public.sales_returns (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  return_number text not null check (pg_catalog.length(pg_catalog.btrim(return_number)) between 1 and 80),
  sales_id uuid not null,
  customer_id uuid not null,
  return_date date not null,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed')),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  posted_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  subtotal numeric(20, 4) not null default 0 check (subtotal >= 0),
  discount_amount numeric(20, 4) not null default 0 check (discount_amount >= 0),
  total_amount numeric(20, 4) not null default 0 check (total_amount >= 0),
  receivable_account_id uuid not null,
  posted_journal_entry_id uuid,
  reversal_journal_entry_id uuid,
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint sales_returns_org_id_id_uq unique (organization_id, id),
  constraint sales_returns_org_number_uq unique (organization_id, return_number),
  constraint sales_returns_sales_same_org_fk
    foreign key (organization_id, sales_id)
    references public.sales (organization_id, id)
    on delete restrict,
  constraint sales_returns_customer_same_org_fk
    foreign key (organization_id, customer_id)
    references public.contacts (organization_id, id)
    on delete restrict,
  constraint sales_returns_account_same_org_fk
    foreign key (organization_id, receivable_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint sales_returns_discount_limit_chk check (discount_amount <= subtotal),
  constraint sales_returns_reversal_entry_same_org_fk
    foreign key (organization_id, reversal_journal_entry_id)
    references public.journal_entries (organization_id, id) on delete restrict,
  constraint sales_returns_reversed_audit_chk
    check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null)),
    constraint sales_returns_confirmed_timestamp_chk
    check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint sales_returns_void_timestamp_chk
    check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))
);

create table public.sales_return_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  sales_return_id uuid not null,
  line_number integer not null check (line_number > 0),
  sales_item_id uuid not null,
  product_id uuid not null,
  quantity numeric(20, 6) not null check (quantity > 0),
  unit_price numeric(20, 6) not null check (unit_price >= 0),
  line_total numeric(20, 4) not null check (line_total >= 0),
  cogs_unit_cost numeric(20, 6) not null default 0 check (cogs_unit_cost >= 0),
  cogs_total numeric(20, 4) not null default 0 check (cogs_total >= 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint sales_return_items_org_id_id_uq unique (organization_id, id),
  constraint sales_return_items_line_uq unique (organization_id, sales_return_id, line_number),
  constraint sales_return_items_source_item_uq unique (organization_id, sales_return_id, sales_item_id),
  constraint sales_return_items_return_same_org_fk
    foreign key (organization_id, sales_return_id)
    references public.sales_returns (organization_id, id)
    on delete restrict,
  constraint sales_return_items_sales_item_same_org_fk
    foreign key (organization_id, sales_item_id)
    references public.sales_items (organization_id, id)
    on delete restrict,
  constraint sales_return_items_product_same_org_fk
    foreign key (organization_id, product_id)
    references public.products (organization_id, id)
    on delete restrict
);

create table public.expenses (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  expense_number text not null check (pg_catalog.length(pg_catalog.btrim(expense_number)) between 1 and 80),
  expense_category_id uuid not null,
  contact_id uuid,
  payable_account_id uuid,
  expense_date date not null,
  amount numeric(20, 4) not null check (amount > 0),
  description text,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed')),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  posted_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  posted_journal_entry_id uuid,
  reversal_journal_entry_id uuid,
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint expenses_org_id_id_uq unique (organization_id, id),
  constraint expenses_org_number_uq unique (organization_id, expense_number),
  constraint expenses_category_same_org_fk
    foreign key (organization_id, expense_category_id)
    references public.expense_categories (organization_id, id)
    on delete restrict,
  constraint expenses_contact_same_org_fk
    foreign key (organization_id, contact_id)
    references public.contacts (organization_id, id)
    on delete restrict,
  constraint expenses_account_same_org_fk
    foreign key (organization_id, payable_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint expenses_reversal_entry_same_org_fk
    foreign key (organization_id, reversal_journal_entry_id)
    references public.journal_entries (organization_id, id) on delete restrict,
  constraint expenses_reversed_audit_chk
    check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null)),
    constraint expenses_confirmed_timestamp_chk
    check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint expenses_void_timestamp_chk
    check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))
);

create table public.payments (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  payment_number text not null check (pg_catalog.length(pg_catalog.btrim(payment_number)) between 1 and 80),
  payment_type text not null check (payment_type in ('receipt', 'payment', 'transfer', 'refund')),
  contact_id uuid,
  payment_date date not null,
  amount numeric(20, 4) not null check (amount > 0),
  account_id uuid not null,
  settlement_account_id uuid,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed')),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  posted_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  posted_journal_entry_id uuid,
  reversal_journal_entry_id uuid,
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  description text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint payments_org_id_id_uq unique (organization_id, id),
  constraint payments_org_number_uq unique (organization_id, payment_number),
  constraint payments_contact_same_org_fk
    foreign key (organization_id, contact_id)
    references public.contacts (organization_id, id)
    on delete restrict,
  constraint payments_account_same_org_fk
    foreign key (organization_id, account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint payments_settlement_account_same_org_fk
    foreign key (organization_id, settlement_account_id)
    references public.accounts (organization_id, id)
    on delete restrict,
  constraint payments_reversal_entry_same_org_fk
    foreign key (organization_id, reversal_journal_entry_id)
    references public.journal_entries (organization_id, id) on delete restrict,
  constraint payments_reversed_audit_chk
    check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null)),
    constraint payments_confirmed_timestamp_chk
    check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint payments_void_timestamp_chk
    check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))
);

create table public.payment_allocations (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  payment_id uuid not null,
  document_type text not null
    check (document_type in ('purchase', 'purchase_return', 'sales', 'sales_return', 'expense')),
  document_id uuid not null,
  allocated_amount numeric(20, 4) not null check (allocated_amount > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint payment_allocations_org_id_id_uq unique (organization_id, id),
  constraint payment_allocations_payment_document_uq
    unique (organization_id, payment_id, document_type, document_id),
  constraint payment_allocations_payment_same_org_fk
    foreign key (organization_id, payment_id)
    references public.payments (organization_id, id)
    on delete restrict
);

-- Add document-to-journal references after both sides exist. Composite FKs enforce tenant equality.
alter table public.purchase
  add constraint purchase_posted_journal_same_org_fk
  foreign key (organization_id, posted_journal_entry_id)
  references public.journal_entries (organization_id, id) on delete restrict;
alter table public.purchase_returns
  add constraint purchase_returns_posted_journal_same_org_fk
  foreign key (organization_id, posted_journal_entry_id)
  references public.journal_entries (organization_id, id) on delete restrict;
alter table public.sales
  add constraint sales_posted_journal_same_org_fk
  foreign key (organization_id, posted_journal_entry_id)
  references public.journal_entries (organization_id, id) on delete restrict;
alter table public.sales_returns
  add constraint sales_returns_posted_journal_same_org_fk
  foreign key (organization_id, posted_journal_entry_id)
  references public.journal_entries (organization_id, id) on delete restrict;
alter table public.expenses
  add constraint expenses_posted_journal_same_org_fk
  foreign key (organization_id, posted_journal_entry_id)
  references public.journal_entries (organization_id, id) on delete restrict;
alter table public.payments
  add constraint payments_posted_journal_same_org_fk
  foreign key (organization_id, posted_journal_entry_id)
  references public.journal_entries (organization_id, id) on delete restrict;

-- Index FK columns and common tenant/date/status access paths.
create index journal_entries_org_date_idx on public.journal_entries (organization_id, entry_date desc);
create index journal_entries_org_status_idx on public.journal_entries (organization_id, status);
create unique index journal_entries_one_reversal_per_entry_uq
  on public.journal_entries (organization_id, reversal_of_id) where reversal_of_id is not null;
create index account_transactions_account_idx on public.account_transactions (organization_id, account_id);
create index account_transactions_org_account_contact_idx
  on public.account_transactions (organization_id, account_id, contact_id)
  where contact_id is not null;
create index inventory_transactions_product_date_idx
  on public.inventory_transactions (organization_id, product_id, transaction_date desc);
create index purchase_supplier_date_idx on public.purchase (organization_id, supplier_id, invoice_date desc);
create index purchase_items_product_idx on public.purchase_items (organization_id, product_id);
create index purchase_returns_purchase_idx on public.purchase_returns (organization_id, purchase_id);
create index purchase_return_items_source_idx on public.purchase_return_items (organization_id, purchase_item_id);
create index sales_customer_date_idx on public.sales (organization_id, customer_id, invoice_date desc);
create index sales_items_product_idx on public.sales_items (organization_id, product_id);
create index sales_returns_sales_idx on public.sales_returns (organization_id, sales_id);
create index sales_return_items_source_idx on public.sales_return_items (organization_id, sales_item_id);
create index expenses_org_date_idx on public.expenses (organization_id, expense_date desc);
create index payments_org_date_idx on public.payments (organization_id, payment_date desc);
create index payment_allocations_document_idx
  on public.payment_allocations (organization_id, document_type, document_id);

-- Timestamp maintenance.
create trigger journal_entries_set_updated_at before update on public.journal_entries
for each row execute function public.set_updated_at();
create trigger purchase_set_updated_at before update on public.purchase
for each row execute function public.set_updated_at();
create trigger purchase_items_set_updated_at before update on public.purchase_items
for each row execute function public.set_updated_at();
create trigger purchase_returns_set_updated_at before update on public.purchase_returns
for each row execute function public.set_updated_at();
create trigger purchase_return_items_set_updated_at before update on public.purchase_return_items
for each row execute function public.set_updated_at();
create trigger sales_set_updated_at before update on public.sales
for each row execute function public.set_updated_at();
create trigger sales_items_set_updated_at before update on public.sales_items
for each row execute function public.set_updated_at();
create trigger sales_returns_set_updated_at before update on public.sales_returns
for each row execute function public.set_updated_at();
create trigger sales_return_items_set_updated_at before update on public.sales_return_items
for each row execute function public.set_updated_at();
create trigger expenses_set_updated_at before update on public.expenses
for each row execute function public.set_updated_at();
create trigger payments_set_updated_at before update on public.payments
for each row execute function public.set_updated_at();
create trigger payment_allocations_set_updated_at before update on public.payment_allocations
for each row execute function public.set_updated_at();

-- Enable RLS on every tenant-owned transactional table.
alter table public.journal_entries enable row level security;
alter table public.account_transactions enable row level security;
alter table public.inventory_transactions enable row level security;
alter table public.inventory_balances enable row level security;
alter table public.purchase enable row level security;
alter table public.purchase_items enable row level security;
alter table public.purchase_returns enable row level security;
alter table public.purchase_return_items enable row level security;
alter table public.sales enable row level security;
alter table public.sales_items enable row level security;
alter table public.sales_returns enable row level security;
alter table public.sales_return_items enable row level security;
alter table public.expenses enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;

-- Read policies. No browser-role INSERT/UPDATE/DELETE policies are granted in this phase.
create policy journal_entries_select_member on public.journal_entries
  for select to authenticated using (public.has_org_permission(organization_id, 'journal_entries.read'));
create policy account_transactions_select_member on public.account_transactions
  for select to authenticated using (public.has_org_permission(organization_id, 'journal_entries.read'));
create policy inventory_transactions_select_member on public.inventory_transactions
  for select to authenticated using (public.has_org_permission(organization_id, 'inventory.read'));
create policy inventory_balances_select_member on public.inventory_balances
  for select to authenticated using (public.has_org_permission(organization_id, 'inventory.read'));
create policy purchase_select_member on public.purchase
  for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
create policy purchase_items_select_member on public.purchase_items
  for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
create policy purchase_returns_select_member on public.purchase_returns
  for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
create policy purchase_return_items_select_member on public.purchase_return_items
  for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
create policy sales_select_member on public.sales
  for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
create policy sales_items_select_member on public.sales_items
  for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
create policy sales_returns_select_member on public.sales_returns
  for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
create policy sales_return_items_select_member on public.sales_return_items
  for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
create policy expenses_select_member on public.expenses
  for select to authenticated using (public.has_org_permission(organization_id, 'expenses.read'));
create policy payments_select_member on public.payments
  for select to authenticated using (public.has_org_permission(organization_id, 'payments.read'));
create policy payment_allocations_select_member on public.payment_allocations
  for select to authenticated using (public.has_org_permission(organization_id, 'payments.read'));

revoke all on public.journal_entries, public.account_transactions,
  public.inventory_transactions, public.inventory_balances, public.purchase,
  public.purchase_items, public.purchase_returns, public.purchase_return_items,
  public.sales, public.sales_items, public.sales_returns, public.sales_return_items,
  public.expenses, public.payments, public.payment_allocations from anon, authenticated;

grant select on public.journal_entries, public.account_transactions,
  public.inventory_transactions, public.inventory_balances, public.purchase,
  public.purchase_items, public.purchase_returns, public.purchase_return_items,
  public.sales, public.sales_items, public.sales_returns, public.sales_return_items,
  public.expenses, public.payments, public.payment_allocations to authenticated;


-- ============================================================================
-- RBAC BOOTSTRAP
-- ============================================================================


insert into public.permissions (permission_key, name, description, module)
values
  ('organization.read', 'View organization', 'View organization profile and settings.', 'organization'),
  ('organization.update', 'Update organization', 'Update organization profile and settings.', 'organization'),
  ('users.read', 'View members', 'View organization memberships.', 'users'),
  ('users.manage', 'Manage members', 'Invite, deactivate, and assign roles to members.', 'users'),
  ('roles.read', 'View roles', 'View organization roles and their permissions.', 'roles'),
  ('roles.manage', 'Manage roles', 'Create and update organization-specific custom roles.', 'roles'),
  ('opening_balances.post', 'Post opening balances', 'Post an organization''s one-time general ledger, party, and inventory opening balances.', 'accounting'),
  ('accounts.read', 'View chart of accounts', 'View accounts and account hierarchy.', 'accounting'),
  ('accounts.manage', 'Manage chart of accounts', 'Create and update chart of accounts.', 'accounting'),
  ('journal_entries.read', 'View journal entries', 'View journal entries and lines.', 'accounting'),
  ('journal_entries.create', 'Create journal entries', 'Create draft journal entries.', 'accounting'),
  ('journal_entries.confirm', 'Confirm journal entries', 'Confirm balanced draft journal entries before posting.', 'accounting'),
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
  ('purchases.confirm', 'Confirm purchases', 'Confirm purchase documents before posting.', 'purchases'),
  ('purchases.post', 'Post purchases', 'Post purchases and related stock/accounting effects.', 'purchases'),
  ('purchases.returns.create', 'Create purchase returns', 'Create and update draft purchase return documents.', 'purchases'),
  ('purchases.returns.post', 'Post purchase returns', 'Post purchase returns.', 'purchases'),
  ('purchases.returns.confirm', 'Confirm purchase returns', 'Confirm purchase return documents before posting.', 'purchases'),
  ('sales.read', 'View sales', 'View sales invoices and returns.', 'sales'),
  ('sales.create', 'Create sales', 'Create and update draft sales documents.', 'sales'),
  ('sales.confirm', 'Confirm sales', 'Confirm sales invoices before posting.', 'sales'),
  ('sales.post', 'Post sales', 'Post sales and related stock/accounting effects.', 'sales'),
  ('sales.returns.create', 'Create sales returns', 'Create and update draft sales return documents.', 'sales'),
  ('sales.returns.post', 'Post sales returns', 'Post sales returns.', 'sales'),
  ('sales.returns.confirm', 'Confirm sales returns', 'Confirm sales return documents before posting.', 'sales'),
  ('expenses.read', 'View expenses', 'View expense records.', 'expenses'),
  ('expenses.manage', 'Manage expenses', 'Create and update draft expenses.', 'expenses'),
  ('expenses.confirm', 'Confirm expenses', 'Confirm expense documents before posting.', 'expenses'),
  ('expenses.post', 'Post expenses', 'Post expenses to the ledger.', 'expenses'),
  ('payments.read', 'View payments', 'View payments and allocations.', 'payments'),
  ('payments.manage', 'Manage payments', 'Create payments and manage draft allocations.', 'payments'),
  ('payments.confirm', 'Confirm payments', 'Confirm payments and receipts before posting.', 'payments'),
  ('payments.post', 'Post payments', 'Post payments and allocation effects.', 'payments'),
  ('reports.read', 'View reports', 'View organization financial and operational reports.', 'reports')
on conflict (permission_key) do update
set name = excluded.name,
    description = excluded.description,
    module = excluded.module;


create or replace function public.next_document_number(p_organization_id uuid, p_document_type text)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_permission text;
  v_prefix text;
  v_number bigint;
  v_padding smallint;
begin
  v_permission := case p_document_type
    when 'purchase' then 'purchases.create' when 'sale' then 'sales.create'
    when 'expense' then 'expenses.manage' when 'payment' then 'payments.manage'
    when 'journal_entry' then 'journal_entries.create'
    when 'purchase_return' then 'purchases.returns.create'
    when 'sales_return' then 'sales.returns.create' else null end;
  if auth.uid() is null or v_permission is null
     or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'Not authorized to allocate this document number.';
  end if;
  insert into public.number_sequences(organization_id, document_type, prefix, next_number, padding)
  values (p_organization_id, p_document_type, upper(left(p_document_type, 3)) || '-', 2, 5)
  on conflict (organization_id, document_type) do update
    set next_number = public.number_sequences.next_number + 1, updated_at = pg_catalog.now()
    where public.number_sequences.is_active
  returning prefix, next_number - 1, padding into v_prefix, v_number, v_padding;

  if not found then
    raise exception using errcode = '55000',
      message = 'Document numbering is disabled for this document type in this organization.';
  end if;

  return v_prefix || lpad(v_number::text, v_padding, '0');
end;
$function$;
revoke all on function public.next_document_number(uuid, text) from public, anon;
grant execute on function public.next_document_number(uuid, text) to authenticated;

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

  if p_timezone is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names tz
       where tz.name = pg_catalog.btrim(p_timezone)
     ) then
    raise exception using
      errcode = '22023',
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
  -- Serialize membership removals/role changes per organization so concurrent
  -- requests cannot both remove the final active Administrator.
  perform 1 from public.organizations o where o.id = old.organization_id for update;

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


-- Organization membership administration. This RPC adds only users who already
-- have a verified Supabase Auth account. Unregistered users must sign up and
-- verify their email before a company Administrator can add them.
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
begin
  if (select auth.uid()) is null
     or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'users.manage') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to manage members in this organization.';
  end if;

  if p_email is null
     or pg_catalog.length(pg_catalog.btrim(p_email)) not between 3 and 254
     or pg_catalog.strpos(pg_catalog.btrim(p_email), '@') < 2 then
    raise exception using errcode = '22023', message = 'A valid user email address is required.';
  end if;

  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then raise exception using errcode = '23503', message = 'Active organization was not found.'; end if;

  if not exists (select 1 from public.roles r
    where r.organization_id = p_organization_id and r.id = p_role_id and r.status = 'active') then
    raise exception using errcode = '23503',
      message = 'The selected role must be active and belong to this organization.';
  end if;

  if exists (
    select 1 from public.role_permissions rp
    join public.permissions p on p.id=rp.permission_id
    where rp.role_id=p_role_id
      and not public.has_org_permission(p_organization_id,p.permission_key)
  ) then
    raise exception using errcode='42501',
      message='You cannot assign a role containing permissions you do not hold.';
  end if;

  select u.id into v_user_id from auth.users u
  where pg_catalog.lower(u.email) = pg_catalog.lower(pg_catalog.btrim(p_email))
    and u.email_confirmed_at is not null
  order by u.created_at limit 1;

  if v_user_id is null then
    raise exception using errcode = 'P0002',
      message = 'No verified Supabase Auth user exists for this email. Ask the person to sign up and verify their email before adding them.';
  end if;

  insert into public.organization_users (organization_id, user_id, role_id, is_active)
  values (p_organization_id, v_user_id, p_role_id, true)
  returning id into v_membership_id;
  return v_membership_id;
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'This user is already a member of the organization.';
end;
$function$;

create or replace function public.update_organization_user_role(
  p_organization_id uuid, p_membership_id uuid, p_role_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null
     or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'users.manage') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to manage members in this organization.';
  end if;

  perform 1 from public.organizations o where o.id = p_organization_id and o.is_active for update;
  if not found then raise exception using errcode = '23503', message = 'Active organization was not found.'; end if;

  if not exists (select 1 from public.roles r
    where r.organization_id = p_organization_id and r.id = p_role_id and r.status = 'active') then
    raise exception using errcode = '23503',
      message = 'The selected role must be active and belong to this organization.';
  end if;

  if exists (
    select 1 from public.role_permissions rp
    join public.permissions p on p.id=rp.permission_id
    where rp.role_id=p_role_id
      and not public.has_org_permission(p_organization_id,p.permission_key)
  ) then
    raise exception using errcode='42501',
      message='You cannot assign a role containing permissions you do not hold.';
  end if;

  update public.organization_users set role_id = p_role_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_membership_id;
  if not found then raise exception using errcode = '23503', message = 'Organization membership was not found.'; end if;
end;
$function$;

create or replace function public.set_organization_user_active(
  p_organization_id uuid, p_membership_id uuid, p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_role_id uuid;
begin
  if (select auth.uid()) is null
     or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'users.manage') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to manage members in this organization.';
  end if;
  if p_is_active is null then raise exception using errcode = '22023', message = 'Member active state is required.'; end if;

  perform 1 from public.organizations o where o.id = p_organization_id and o.is_active for update;
  if not found then raise exception using errcode = '23503', message = 'Active organization was not found.'; end if;

  select ou.role_id into v_role_id from public.organization_users ou
  where ou.organization_id = p_organization_id and ou.id = p_membership_id for update;
  if not found then raise exception using errcode = '23503', message = 'Organization membership was not found.'; end if;

  if p_is_active and not exists (select 1 from public.roles r
    where r.organization_id = p_organization_id and r.id = v_role_id and r.status = 'active') then
    raise exception using errcode = '23514',
      message = 'A member cannot be reactivated while their assigned role is inactive.';
  end if;

  update public.organization_users set is_active = p_is_active, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_membership_id;
end;
$function$;

revoke all on function public.add_organization_user_by_email(uuid, text, uuid) from public, anon;
revoke all on function public.update_organization_user_role(uuid, uuid, uuid) from public, anon;
revoke all on function public.set_organization_user_active(uuid, uuid, boolean) from public, anon;
grant execute on function public.add_organization_user_by_email(uuid, text, uuid) to authenticated;
grant execute on function public.update_organization_user_role(uuid, uuid, uuid) to authenticated;
grant execute on function public.set_organization_user_active(uuid, uuid, boolean) to authenticated;

-- ============================================================================
-- MANUAL JOURNAL POSTING RPC
-- ============================================================================

-- Zero ERP: atomic balanced manual journal posting RPC
-- Depends on the core foundation, transaction schema, and RBAC bootstrap above.
-- Browser clients cannot write ledger tables directly; this function is the controlled posting boundary.

create or replace function public.post_manual_journal_entry(
  p_organization_id uuid,
  p_entry_number text,
  p_entry_date date,
  p_description text,
  p_lines jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_journal_entry_id uuid;
  v_line_count integer;
  v_invalid_line_count integer;
  v_debit_total numeric(20, 4);
  v_credit_total numeric(20, 4);
begin
  v_user_id := (select auth.uid());

  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'Authentication is required to post a journal entry.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'journal_entries.create')
     or not public.has_org_permission(p_organization_id, 'journal_entries.post') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to create and post journal entries for this organization.';
  end if;

  if p_entry_number is null
     or pg_catalog.length(pg_catalog.btrim(p_entry_number)) not between 1 and 80 then
    raise exception using errcode = '22023',
      message = 'Entry number must contain between 1 and 80 characters.';
  end if;

  if p_entry_date is null then
    raise exception using errcode = '22023',
      message = 'Entry date is required.';
  end if;

  if p_lines is null or pg_catalog.jsonb_typeof(p_lines) <> 'array' then
    raise exception using errcode = '22023',
      message = 'Journal lines must be provided as a JSON array.';
  end if;

  if pg_catalog.jsonb_array_length(p_lines) < 2 then
    raise exception using errcode = '22023',
      message = 'At least two journal lines are required.';
  end if;

  select
    pg_catalog.count(*)::integer,
    pg_catalog.count(*) filter (
      where x.account_id is null
         or x.debit is null
         or x.credit is null
         or x.debit < 0
         or x.credit < 0
         or not ((x.debit > 0 and x.credit = 0) or (x.credit > 0 and x.debit = 0))
    )::integer,
    coalesce(pg_catalog.sum(x.debit), 0),
    coalesce(pg_catalog.sum(x.credit), 0)
  into v_line_count, v_invalid_line_count, v_debit_total, v_credit_total
  from pg_catalog.jsonb_to_recordset(p_lines) as x(
    account_id uuid,
    description text,
    debit numeric,
    credit numeric,
    contact_id uuid
  );

  if v_line_count <> pg_catalog.jsonb_array_length(p_lines) then
    raise exception using errcode = '22023',
      message = 'Journal lines could not be parsed.';
  end if;

  if v_invalid_line_count > 0 then
    raise exception using errcode = '22023',
      message = 'Each journal line must contain an account, non-negative amounts, and exactly one positive debit or credit.';
  end if;

  if v_debit_total <= 0 or v_debit_total <> v_credit_total then
    raise exception using errcode = '23514',
      message = 'Journal entry is not balanced: total debits must equal total credits and be greater than zero.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_lines) as x(
      account_id uuid,
      description text,
      debit numeric,
      credit numeric,
      contact_id uuid
    )
    left join public.accounts a
      on a.organization_id = p_organization_id
     and a.id = x.account_id
    where a.id is null or not a.is_active or not a.is_postable
  ) then
    raise exception using errcode = '23503',
      message = 'Every journal line must reference an active, postable account in this organization.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_lines) as x(
      account_id uuid,
      description text,
      debit numeric,
      credit numeric,
      contact_id uuid
    )
    left join public.contacts c
      on c.organization_id = p_organization_id
     and c.id = x.contact_id
    where x.contact_id is not null and (c.id is null or not c.is_active)
  ) then
    raise exception using errcode = '23503',
      message = 'Each contact on a journal line must be active and belong to this organization.';
  end if;

  insert into public.journal_entries (
    organization_id,
    entry_number,
    entry_date,
    entry_type,
    status,
    description,
    confirmed_at,
    confirmed_by,
    posted_at,
    posted_by,
    created_by
  )
  values (
    p_organization_id,
    pg_catalog.btrim(p_entry_number),
    p_entry_date,
    'manual',
    'posted',
    nullif(pg_catalog.btrim(coalesce(p_description, '')), ''),
    pg_catalog.now(),
    v_user_id,
    pg_catalog.now(),
    v_user_id,
    v_user_id
  )
  returning id into v_journal_entry_id;

  insert into public.account_transactions (
    organization_id,
    journal_entry_id,
    account_id,
    line_number,
    description,
    debit,
    credit,
    contact_id
  )
  select
    p_organization_id,
    v_journal_entry_id,
    (x.item->>'account_id')::uuid,
    x.ordinality::integer,
    nullif(pg_catalog.btrim(coalesce(x.item->>'description', '')), ''),
    (x.item->>'debit')::numeric,
    (x.item->>'credit')::numeric,
    (x.item->>'contact_id')::uuid
  from pg_catalog.jsonb_array_elements(p_lines) with ordinality as x(item,ordinality);

  return v_journal_entry_id;
end;
$$;

revoke all on function public.post_manual_journal_entry(uuid, text, date, text, jsonb)
  from public, anon, authenticated;


-- ============================================================================
-- PURCHASE POSTING RPC
-- ============================================================================

-- Zero ERP: controlled purchase posting with inventory valuation and ledger effects.
-- Discounts are allocated proportionally to line values; rounding residue goes to the
-- final line so inventory valuation and accounts payable reconcile exactly.

create or replace function public.post_purchase(
  p_organization_id uuid,
  p_purchase_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_purchase public.purchase%rowtype;
  v_supplier_active boolean;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_line_net numeric(20,4);
  v_allocated numeric(20,4) := 0;
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_journal_id uuid;
  v_line record;
  v_last_line integer;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication is required to post a purchase.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'purchases.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post purchases for this organization.';
  end if;

  select p.* into v_purchase
  from public.purchase p
  where p.organization_id = p_organization_id and p.id = p_purchase_id
  for update;

  if not found then
    raise exception using errcode = '23503', message = 'Purchase document was not found in this organization.';
  end if;
  if v_purchase.status <> 'confirmed' or v_purchase.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted purchase can be posted.';
  end if;

  select c.is_active into v_supplier_active
  from public.contacts c
  where c.organization_id = p_organization_id and c.id = v_purchase.supplier_id
  for update;
  if coalesce(v_supplier_active, false) is not true then
    raise exception using errcode = '23503', message = 'Supplier must be active and belong to this organization.';
  end if;

  select count(*)::integer, coalesce(sum(pi.line_total), 0), max(pi.line_number)
  into v_line_count, v_subtotal, v_last_line
  from public.purchase_items pi
  where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id;

  if v_line_count < 1 then
    raise exception using errcode = '23514', message = 'A purchase must contain at least one item.';
  end if;
  if v_subtotal <> v_purchase.subtotal then
    raise exception using errcode = '23514', message = 'Purchase subtotal must equal the sum of item line totals.';
  end if;
  if v_purchase.discount_amount > v_subtotal
     or v_purchase.total_amount <> v_subtotal - v_purchase.discount_amount
     or v_purchase.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Purchase totals are inconsistent or net total is not positive.';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.organization_id = p_organization_id
      and a.id = v_purchase.payable_account_id
      and a.is_active and a.is_postable and a.is_control_account
      and a.account_type = 'liability'
  ) then
    raise exception using errcode = '23503', message = 'Payable account must be an active, postable liability account.';
  end if;

  if exists (
    select 1
    from public.purchase_items pi
    join public.products pr on pr.organization_id = pi.organization_id and pr.id = pi.product_id
    left join public.accounts a on a.organization_id = pr.organization_id and a.id = pr.inventory_account_id
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
      and (not pr.is_active or a.id is null or not a.is_active or not a.is_postable
        or a.account_type <> 'asset'
        or pi.line_total <> round(pi.quantity * pi.unit_cost, 4))
  ) then
    raise exception using errcode = '23514',
      message = 'Each item requires an active product, a postable inventory asset account, and a consistent line total.';
  end if;

  -- Lock stock rows in stable order to reduce deadlocks when purchases overlap.
  for v_line in
    select distinct pi.product_id
    from public.purchase_items pi
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
    order by pi.product_id
  loop
    insert into public.inventory_balances (organization_id, product_id, quantity, average_cost, inventory_value)
    values (p_organization_id, v_line.product_id, 0, 0, 0)
    on conflict (organization_id, product_id) do nothing;

    select b.quantity, b.inventory_value into v_balance_quantity, v_balance_value
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    if v_balance_quantity < 0 or v_balance_value < 0 then
      raise exception using errcode = '23514',
        message = 'Negative inventory balance must be reconciled before purchase posting.';
    end if;
  end loop;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description, posted_at, posted_by, created_by
  )
  values (
    p_organization_id,
    'PUR-' || pg_catalog.replace(p_purchase_id::text, '-', ''),
    v_purchase.invoice_date, 'purchase', 'posted',
    'purchase', p_purchase_id, 'Purchase invoice ' || v_purchase.invoice_id,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  -- Apply proportional discount allocation with final-line rounding adjustment.
  for v_line in
    select pi.id, pi.product_id, pi.quantity, pi.line_total, pi.line_number,
           pr.inventory_account_id
    from public.purchase_items pi
    join public.products pr on pr.organization_id = pi.organization_id and pr.id = pi.product_id
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
    order by pi.line_number
  loop
    if v_line.line_number = v_last_line then
      v_line_net := v_purchase.total_amount - v_allocated;
    else
      v_line_net := round(v_line.line_total * v_purchase.total_amount / v_subtotal, 4);
      v_allocated := v_allocated + v_line_net;
    end if;

    select b.quantity, b.inventory_value into v_balance_quantity, v_balance_value
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    v_new_quantity := v_balance_quantity + v_line.quantity;
    v_new_value := v_balance_value + v_line_net;
    v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity, 6) end;

    update public.inventory_balances
    set quantity = v_new_quantity, inventory_value = v_new_value,
        average_cost = v_new_average, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_line.product_id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'PUR-' || pg_catalog.replace(p_purchase_id::text, '-', '') || '-' || v_line.line_number::text,
      v_line.product_id, v_purchase.invoice_date, 'purchase', 'in', v_line.quantity,
      round(v_line_net / v_line.quantity, 6), v_line_net,
      'purchase', p_purchase_id,
      case when v_balance_quantity = 0 then null else round(v_balance_value / v_balance_quantity, 6) end,
      v_new_average, v_user_id
    );
  end loop;

  -- Ledger debit amounts use the same allocation formula and rounding residue as stock valuation.
  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  select p_organization_id, v_journal_id, g.inventory_account_id,
         row_number() over (order by g.inventory_account_id)::integer,
         'Inventory received - ' || v_purchase.invoice_id, g.debit_amount, 0, v_purchase.supplier_id
  from (
    select pr.inventory_account_id,
           sum(case
             when pi.line_number = v_last_line then
               v_purchase.total_amount - coalesce((
                 select sum(round(pi2.line_total * v_purchase.total_amount / v_subtotal, 4))
                 from public.purchase_items pi2
                 where pi2.organization_id = p_organization_id
                   and pi2.purchase_id = p_purchase_id
                   and pi2.line_number <> v_last_line
               ), 0)
             else round(pi.line_total * v_purchase.total_amount / v_subtotal, 4)
           end) as debit_amount
    from public.purchase_items pi
    join public.products pr on pr.organization_id = pi.organization_id and pr.id = pi.product_id
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
    group by pr.inventory_account_id
  ) g
  where g.debit_amount > 0;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_purchase.payable_account_id,
    (select count(*)::integer + 1
     from public.account_transactions atx
     where atx.organization_id = p_organization_id and atx.journal_entry_id = v_journal_id),
    'Accounts payable - ' || v_purchase.invoice_id, 0, v_purchase.total_amount, v_purchase.supplier_id
  );

  update public.purchase
  set status = 'posted', posted_journal_entry_id = v_journal_id, posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_purchase_id;

  return v_journal_id;
end;
$$;

revoke all on function public.post_purchase(uuid, uuid) from public, anon;
grant execute on function public.post_purchase(uuid, uuid) to authenticated;


-- ============================================================================
-- OPENING BALANCES
-- ============================================================================

-- Zero ERP: one-time opening balances using existing ledger and inventory tables only.
-- No new tables are introduced.

-- A single organization-level opening journal is allowed. Corrections after posting
-- must use the normal reversal/adjustment workflow, not a second opening post.
create unique index journal_entries_one_org_opening_balance_uq
  on public.journal_entries (organization_id)
  where entry_type = 'opening_balance'
    and reference_type = 'organization_opening_balance';

create or replace function public.post_opening_balances(
  p_organization_id uuid,
  p_entry_date date,
  p_account_lines jsonb,
  p_party_balances jsonb,
  p_inventory_lines jsonb,
  p_description text default 'Opening balances'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_journal_entry_id uuid;
  v_debit_total numeric(20,4) := 0;
  v_credit_total numeric(20,4) := 0;
  v_inventory_value numeric(20,4) := 0;
  v_entry_number text;
  v_product record;
begin
  v_user_id := (select auth.uid());

  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'Authentication is required to post opening balances.';
  end if;

  -- Exclusive organization lock serializes initialization against every operational poster.
  perform 1
  from public.organizations o
  where o.id = p_organization_id
    and o.is_active
  for update;

  if not found then
    raise exception using errcode = '23503',
      message = 'Active organization was not found.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'opening_balances.post') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to post opening balances for this organization.';
  end if;

  if p_entry_date is null then
    raise exception using errcode = '22023',
      message = 'Opening balance date is required.';
  end if;

  if p_account_lines is null or pg_catalog.jsonb_typeof(p_account_lines) <> 'array'
     or p_party_balances is null or pg_catalog.jsonb_typeof(p_party_balances) <> 'array'
     or p_inventory_lines is null or pg_catalog.jsonb_typeof(p_inventory_lines) <> 'array' then
    raise exception using errcode = '22023',
      message = 'Account, party, and inventory lines must each be supplied as JSON arrays.';
  end if;

  if exists (
    select 1 from public.journal_entries je
    where je.organization_id = p_organization_id
      and je.entry_type = 'opening_balance'
      and je.reference_type = 'organization_opening_balance'
  ) then
    raise exception using errcode = '23514',
      message = 'Opening balances have already been posted for this organization. Use a reversal or adjustment for corrections.';
  end if;

  if exists (
    select 1 from public.journal_entries je
    where je.organization_id = p_organization_id
      and je.status in ('posted', 'reversed')
      and not (je.entry_type = 'opening_balance'
        and je.reference_type = 'organization_opening_balance')
  ) or exists (
    select 1 from public.inventory_transactions it
    where it.organization_id = p_organization_id
  ) then
    raise exception using errcode = '23514',
      message = 'Opening balances must be initialized before operational ledger or inventory posting. Use controlled adjustments after operations begin.';
  end if;

  -- Validate ordinary GL lines. Accounts also used by party/inventory detail
  -- lines are rejected below to avoid double-counting those control balances.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as x(
      account_id uuid, debit numeric, credit numeric, description text
    )
    where x.account_id is null
       or x.debit is null
       or x.credit is null
       or x.debit < 0
       or x.credit < 0
       or x.debit <> round(x.debit, 4)
       or x.credit <> round(x.credit, 4)
       or not ((x.debit > 0 and x.credit = 0) or (x.credit > 0 and x.debit = 0))
  ) then
    raise exception using errcode = '22023',
      message = 'Each GL line must contain an account, non-negative amounts, and exactly one positive debit or credit.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as x(
      account_id uuid, debit numeric, credit numeric, description text
    )
    left join public.accounts a
      on a.organization_id = p_organization_id
     and a.id = x.account_id
    where a.id is null
       or not a.is_active
       or not a.is_postable
  ) then
    raise exception using errcode = '23503',
      message = 'GL lines must reference active, postable accounts in this organization.';
  end if;

  -- Validate customer/supplier summary balances. Contacts do not carry a
  -- customer-vs-supplier discriminator in the current schema, so party_type
  -- is supplied explicitly by the caller and the contact must belong to this org.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_party_balances) as x(
      contact_id uuid, party_type text, account_id uuid, amount numeric, description text, balance_side text
    )
    where x.contact_id is null
       or x.party_type is null
       or x.party_type not in ('customer', 'supplier')
       or x.account_id is null
       or x.amount is null
       or x.amount <= 0
       or x.amount <> round(x.amount, 4)
       or (x.balance_side is not null and x.balance_side not in ('debit','credit'))
  ) then
    raise exception using errcode = '22023',
      message = 'Each party balance must include a contact, customer/supplier type, control account, and positive amount.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_party_balances) as x(
      contact_id uuid, party_type text, account_id uuid, amount numeric, description text, balance_side text
    )
    left join public.contacts c
      on c.organization_id = p_organization_id
     and c.id = x.contact_id
    left join public.accounts a
      on a.organization_id = p_organization_id
     and a.id = x.account_id
    where c.id is null or not c.is_active
       or a.id is null or not a.is_active or not a.is_postable
       or not a.is_control_account
       or (x.party_type = 'customer' and a.account_type <> 'asset')
       or (x.party_type = 'supplier' and a.account_type <> 'liability')
  ) then
    raise exception using errcode = '23503',
      message = 'Customer balances require an active receivable asset control account; supplier balances require an active payable liability control account. Contacts and accounts must belong to this organization.';
  end if;

  -- Validate inventory lines. One opening line per product keeps the initial
  -- valuation deterministic with the current product-level inventory schema.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    where x.product_id is null
       or x.quantity is null or x.quantity <= 0
       or x.quantity <> round(x.quantity, 6)
       or x.unit_cost is null or x.unit_cost < 0
       or x.unit_cost <> round(x.unit_cost, 6)
  ) then
    raise exception using errcode = '22023',
      message = 'Each inventory line must include a product, positive quantity, and non-negative unit cost.';
  end if;

  if exists (
    select x.product_id
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    group by x.product_id
    having pg_catalog.count(*) > 1
  ) then
    raise exception using errcode = '22023',
      message = 'Duplicate products are not allowed in opening inventory lines; combine their quantities into one line.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    left join public.products pr
      on pr.organization_id = p_organization_id
     and pr.id = x.product_id
    left join public.accounts a
      on a.organization_id = pr.organization_id
     and a.id = pr.inventory_account_id
    where pr.id is null or not pr.is_active
       or a.id is null or not a.is_active or not a.is_postable
       or a.account_type <> 'asset'
  ) then
    raise exception using errcode = '23503',
      message = 'Every opening inventory product must be active and mapped to an active, postable inventory asset account in this organization.';
  end if;

  -- A single account cannot serve both the party control and inventory control
  -- subledgers in the same opening post.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_party_balances) as party(
      contact_id uuid, party_type text, account_id uuid, amount numeric, description text, balance_side text
    )
    join pg_catalog.jsonb_to_recordset(p_inventory_lines) as inv(
      product_id uuid, quantity numeric, unit_cost numeric
    ) on true
    join public.products pr
      on pr.organization_id = p_organization_id
     and pr.id = inv.product_id
    where party.account_id = pr.inventory_account_id
  ) then
    raise exception using errcode = '23514',
      message = 'A party control account cannot also be used as an inventory control account.';
  end if;

  -- AR/AP control balances must be represented by contact-tagged party lines.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as gl(account_id uuid)
    join public.accounts a
      on a.organization_id = p_organization_id and a.id = gl.account_id
    where a.is_control_account and a.account_type in ('asset', 'liability')
  ) then
    raise exception using errcode = '23514',
      message = 'Opening GL lines cannot use receivable/payable control accounts directly. Supply contact-tagged party balances instead.';
  end if;

  -- Prevent a GL line from duplicating a party control or product inventory account.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as gl(account_id uuid)
    where gl.account_id in (
      select party.account_id
      from pg_catalog.jsonb_to_recordset(p_party_balances) as party(
        contact_id uuid, party_type text, account_id uuid, amount numeric, description text, balance_side text
      )
      union
      select pr.inventory_account_id
      from pg_catalog.jsonb_to_recordset(p_inventory_lines) as inv(
        product_id uuid, quantity numeric, unit_cost numeric
      )
      join public.products pr
        on pr.organization_id = p_organization_id
       and pr.id = inv.product_id
    )
  ) then
    raise exception using errcode = '23514',
      message = 'Do not enter a party or inventory control account again in ordinary GL lines; those balances are derived from the detail lines.';
  end if;

  select
    coalesce(pg_catalog.sum(x.debit), 0),
    coalesce(pg_catalog.sum(x.credit), 0)
  into v_debit_total, v_credit_total
  from pg_catalog.jsonb_to_recordset(p_account_lines) as x(
    account_id uuid, debit numeric, credit numeric, description text
  );

  select
    v_debit_total + coalesce(pg_catalog.sum(case
      when coalesce(x.balance_side,case when x.party_type='customer' then 'debit' else 'credit' end)='debit'
      then x.amount else 0 end),0),
    v_credit_total + coalesce(pg_catalog.sum(case
      when coalesce(x.balance_side,case when x.party_type='customer' then 'debit' else 'credit' end)='credit'
      then x.amount else 0 end),0)
  into v_debit_total,v_credit_total
  from pg_catalog.jsonb_to_recordset(p_party_balances) as x(
    contact_id uuid,party_type text,account_id uuid,amount numeric,description text,balance_side text
  );

  select coalesce(pg_catalog.sum(round(x.quantity * x.unit_cost, 4)), 0)
    into v_inventory_value
  from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
    product_id uuid, quantity numeric, unit_cost numeric
  );

  v_debit_total := v_debit_total + v_inventory_value;

  if v_debit_total <= 0 or v_debit_total <> v_credit_total then
    raise exception using errcode = '23514',
      message = pg_catalog.format(
        'Opening balances are not balanced. Debits: %s; credits: %s.',
        v_debit_total, v_credit_total
      );
  end if;

  -- Lock/create product balance rows in stable product order. Opening stock is
  -- an initialization, so pre-existing non-zero stock must be reconciled first.
  for v_product in
    select x.product_id
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    order by x.product_id
  loop
    insert into public.inventory_balances (
      organization_id, product_id, quantity, average_cost, inventory_value
    )
    values (p_organization_id, v_product.product_id, 0, 0, 0)
    on conflict (organization_id, product_id) do nothing;

    perform 1
    from public.inventory_balances b
    where b.organization_id = p_organization_id
      and b.product_id = v_product.product_id
    for update;

    if exists (
      select 1
      from public.inventory_balances b
      where b.organization_id = p_organization_id
        and b.product_id = v_product.product_id
        and (b.quantity <> 0 or b.inventory_value <> 0)
    ) then
      raise exception using errcode = '23514',
        message = 'Opening inventory can only initialize products with zero existing stock. Reconcile existing stock before posting.';
    end if;
  end loop;

  v_entry_number := 'OB-' || pg_catalog.substr(
    pg_catalog.replace(p_organization_id::text, '-', ''), 1, 12
  );

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, v_entry_number, p_entry_date,
    'opening_balance', 'posted', 'organization_opening_balance',
    p_organization_id, nullif(pg_catalog.btrim(coalesce(p_description, '')), ''),
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_entry_id;

  -- Post ordinary GL lines, customer/supplier control balances, and inventory
  -- control balances into the same journal and account ledger.
  with journal_lines as (
    select
      1 as sort_group,
      x.ordinality as sort_order,
      (x.item->>'account_id')::uuid as account_id,
      nullif(pg_catalog.btrim(coalesce(x.item->>'description', '')), '') as description,
      (x.item->>'debit')::numeric as debit,
      (x.item->>'credit')::numeric as credit,
      null::uuid as contact_id
    from pg_catalog.jsonb_array_elements(p_account_lines) with ordinality as x(item,ordinality)

    union all

    select
      2,
      x.ordinality,
      (x.item->>'account_id')::uuid,
      coalesce(nullif(pg_catalog.btrim(coalesce(x.item->>'description', '')), ''),
        case when x.item->>'party_type' = 'customer' then 'Opening receivable' else 'Opening payable' end),
      case when coalesce(x.item->>'balance_side',case when x.item->>'party_type'='customer' then 'debit' else 'credit' end)='debit'
        then (x.item->>'amount')::numeric else 0 end,
      case when coalesce(x.item->>'balance_side',case when x.item->>'party_type'='customer' then 'debit' else 'credit' end)='credit'
        then (x.item->>'amount')::numeric else 0 end,
      (x.item->>'contact_id')::uuid
    from pg_catalog.jsonb_array_elements(p_party_balances) with ordinality as x(item,ordinality)

    union all

    select
      3,
      row_number() over (order by pr.inventory_account_id),
      pr.inventory_account_id,
      'Opening inventory',
      sum(round(x.quantity * x.unit_cost, 4)),
      0::numeric,
      null::uuid
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    join public.products pr
      on pr.organization_id = p_organization_id
     and pr.id = x.product_id
    group by pr.inventory_account_id
    having sum(round(x.quantity * x.unit_cost, 4)) > 0
  )
  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  select
    p_organization_id,
    v_journal_entry_id,
    jl.account_id,
    row_number() over (order by jl.sort_group, jl.sort_order)::integer,
    jl.description,
    jl.debit,
    jl.credit,
    jl.contact_id
  from journal_lines jl
  where jl.debit > 0 or jl.credit > 0;

  -- Initialize product-level stock balances and record auditable stock movements.
  with inventory_totals as (
    select
      x.product_id,
      sum(x.quantity) as quantity,
      sum(round(x.quantity * x.unit_cost, 4)) as inventory_value
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    group by x.product_id
  )
  update public.inventory_balances b
  set quantity = t.quantity,
      inventory_value = t.inventory_value,
      average_cost = case
        when t.quantity = 0 then 0
        else round(t.inventory_value / t.quantity, 6)
      end,
      updated_at = pg_catalog.now()
  from inventory_totals t
  where b.organization_id = p_organization_id
    and b.product_id = t.product_id;

  insert into public.inventory_transactions (
    organization_id, transaction_number, product_id, transaction_date,
    transaction_type, direction, quantity, unit_cost, total_value,
    reference_type, reference_id, unit_cost_before, average_cost_after, created_by
  )
  select
    p_organization_id,
    'OB-' || pg_catalog.substr(pg_catalog.replace(p_organization_id::text, '-', ''), 1, 12)
      || '-' || x.ordinality::text,
    (x.item->>'product_id')::uuid,
    p_entry_date,
    'opening_balance',
    'in',
    (x.item->>'quantity')::numeric,
    (x.item->>'unit_cost')::numeric,
    round((x.item->>'quantity')::numeric * (x.item->>'unit_cost')::numeric, 4),
    'organization_opening_balance',
    p_organization_id,
    null,
    round((x.item->>'unit_cost')::numeric, 6),
    v_user_id
  from pg_catalog.jsonb_array_elements(p_inventory_lines) with ordinality as x(item,ordinality);

  return v_journal_entry_id;
end;
$$;

revoke all on function public.post_opening_balances(uuid, date, jsonb, jsonb, jsonb, text)
  from public, anon;
grant execute on function public.post_opening_balances(uuid, date, jsonb, jsonb, jsonb, text)
  to authenticated;


-- ============================================================================
-- CONTACT PAYMENT AND RECEIPT POSTING RPC
-- ============================================================================

-- Zero ERP: contact-wise receipt/payment posting against existing party control ledgers.
-- No new tables. Opening balances and subsequent activity share account_transactions.

create unique index journal_entries_payment_reference_uq
  on public.journal_entries (organization_id, reference_type, reference_id)
  where entry_type = 'payment'
    and reference_type = 'payment'
    and reference_id is not null;


create or replace function public.post_contact_payment(
  p_organization_id uuid,
  p_payment_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_payment public.payments%rowtype;
  v_cash_account public.accounts%rowtype;
  v_settlement_account public.accounts%rowtype;
  v_outstanding numeric(20,4);
  v_journal_entry_id uuid;
  v_entry_number text;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'payments.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post payments for this organization.';
  end if;

  select * into v_payment
  from public.payments
  where organization_id = p_organization_id and id = p_payment_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Payment was not found in this organization.';
  end if;
  if v_payment.status <> 'confirmed' or v_payment.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted payment can be posted.';
  end if;

  select * into v_cash_account
  from public.accounts
  where organization_id = p_organization_id and id = v_payment.account_id;
  if not found or not v_cash_account.is_active or not v_cash_account.is_postable
     or v_cash_account.account_type <> 'asset' or v_cash_account.is_control_account then
    raise exception using errcode = '23514', message = 'The payment account must be an active, postable cash/bank asset account.';
  end if;

  if v_payment.contact_id is not null then
    perform 1 from public.contacts
    where organization_id = p_organization_id and id = v_payment.contact_id and is_active
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Payment contact must be active and belong to this organization.';
    end if;
  end if;

  v_entry_number := 'PMT-' || pg_catalog.replace(v_payment.id::text, '-', '');

  if v_payment.payment_type = 'transfer' then
    if v_payment.contact_id is not null or v_payment.settlement_account_id is null
       or v_payment.account_id = v_payment.settlement_account_id then
      raise exception using errcode = '22023', message = 'A transfer requires two different cash/bank accounts and no contact.';
    end if;
    select * into v_settlement_account
    from public.accounts
    where organization_id = p_organization_id and id = v_payment.settlement_account_id;
    if not found or not v_settlement_account.is_active or not v_settlement_account.is_postable
       or v_settlement_account.account_type <> 'asset' or v_settlement_account.is_control_account then
      raise exception using errcode = '23514', message = 'Transfer destination must be an active, postable cash/bank asset account.';
    end if;

    insert into public.journal_entries (
      organization_id, entry_number, entry_date,
      entry_type, status, reference_type, reference_id, description,
      posted_at, posted_by, created_by
    )
    values (
      p_organization_id, v_entry_number, v_payment.payment_date,
      'payment', 'posted', 'payment', v_payment.id,
      coalesce(nullif(pg_catalog.btrim(v_payment.description), ''), 'Bank transfer ' || v_payment.payment_number),
      pg_catalog.now(), v_user_id, v_user_id
    )
    returning id into v_journal_entry_id;

    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
    )
    values
      (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 1,
       'Transfer in - ' || v_payment.payment_number, v_payment.amount, 0, null),
      (p_organization_id, v_journal_entry_id, v_payment.account_id, 2,
       'Transfer out - ' || v_payment.payment_number, 0, v_payment.amount, null);

  elsif v_payment.payment_type in ('receipt','payment','refund') then
    if v_payment.contact_id is null or v_payment.settlement_account_id is null
       or v_payment.account_id = v_payment.settlement_account_id then
      raise exception using errcode = '22023', message = 'A contact and a separate receivable/payable control account are required.';
    end if;
    select * into v_settlement_account
    from public.accounts
    where organization_id = p_organization_id and id = v_payment.settlement_account_id;
    if not found or not v_settlement_account.is_active or not v_settlement_account.is_postable
       or not v_settlement_account.is_control_account then
      raise exception using errcode = '23514', message = 'Settlement account must be an active, postable control account.';
    end if;

    if v_payment.payment_type = 'receipt' then
      if v_settlement_account.account_type <> 'asset' then
        raise exception using errcode = '23514', message = 'A receipt requires an accounts receivable asset control account.';
      end if;
      select coalesce(sum(atx.debit - atx.credit),0) into v_outstanding
      from public.account_transactions atx
      join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
      where atx.organization_id = p_organization_id
        and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
        and je.status in ('posted', 'reversed');
      if v_outstanding < v_payment.amount then
        raise exception using errcode = '23514', message = 'Receipt amount exceeds the current customer receivable balance.';
      end if;
    elsif v_payment.payment_type = 'payment' then
      if v_settlement_account.account_type <> 'liability' then
        raise exception using errcode = '23514', message = 'A supplier payment requires an accounts payable liability control account.';
      end if;
      select coalesce(sum(atx.credit - atx.debit),0) into v_outstanding
      from public.account_transactions atx
      join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
      where atx.organization_id = p_organization_id
        and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
        and je.status in ('posted', 'reversed');
      if v_outstanding < v_payment.amount then
        raise exception using errcode = '23514', message = 'Payment amount exceeds the current supplier payable balance.';
      end if;
    elsif v_payment.payment_type = 'refund' then
      if v_settlement_account.account_type = 'asset' then
        select coalesce(sum(atx.debit - atx.credit),0) into v_outstanding
        from public.account_transactions atx
        join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
        where atx.organization_id = p_organization_id
          and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
          and je.status in ('posted', 'reversed');
        if v_outstanding >= 0 or abs(v_outstanding) < v_payment.amount then
          raise exception using errcode = '23514', message = 'Customer refund requires a sufficient credit balance in accounts receivable.';
        end if;
      elsif v_settlement_account.account_type = 'liability' then
        select coalesce(sum(atx.credit - atx.debit),0) into v_outstanding
        from public.account_transactions atx
        join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
        where atx.organization_id = p_organization_id
          and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
          and je.status in ('posted', 'reversed');
        if v_outstanding >= 0 or abs(v_outstanding) < v_payment.amount then
          raise exception using errcode = '23514', message = 'Supplier refund requires a sufficient debit balance in accounts payable.';
        end if;
      else
        raise exception using errcode = '23514', message = 'Refund settlement must be an accounts receivable or payable control account.';
      end if;
    end if;

    insert into public.journal_entries (
      organization_id, entry_number, entry_date,
      entry_type, status, reference_type, reference_id, description,
      posted_at, posted_by, created_by
    )
    values (
      p_organization_id, v_entry_number, v_payment.payment_date,
      'payment', 'posted', 'payment', v_payment.id,
      coalesce(nullif(pg_catalog.btrim(v_payment.description), ''),
        case v_payment.payment_type
          when 'receipt' then 'Customer receipt ' || v_payment.payment_number
          when 'payment' then 'Supplier payment ' || v_payment.payment_number
          else 'Contact refund ' || v_payment.payment_number
        end),
      pg_catalog.now(), v_user_id, v_user_id
    )
    returning id into v_journal_entry_id;

    if v_payment.payment_type = 'receipt' then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 1, 'Receipt ' || v_payment.payment_number, v_payment.amount, 0, null),
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 2, 'Receivable settled - ' || v_payment.payment_number, 0, v_payment.amount, v_payment.contact_id);
    elsif v_payment.payment_type = 'payment' then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 1, 'Payable settled - ' || v_payment.payment_number, v_payment.amount, 0, v_payment.contact_id),
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 2, 'Payment ' || v_payment.payment_number, 0, v_payment.amount, null);
    elsif v_settlement_account.account_type = 'asset' then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 1, 'Customer refund ' || v_payment.payment_number, v_payment.amount, 0, v_payment.contact_id),
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 2, 'Refund paid ' || v_payment.payment_number, 0, v_payment.amount, null);
    else
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 1, 'Supplier refund received ' || v_payment.payment_number, v_payment.amount, 0, null),
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 2, 'Supplier refund credited ' || v_payment.payment_number, 0, v_payment.amount, v_payment.contact_id);
    end if;
  else
    raise exception using errcode = '22023', message = 'Unsupported payment type.';
  end if;


  perform public.validate_payment_allocations(p_organization_id,p_payment_id);

  update public.payments
  set status = 'posted', posted_journal_entry_id = v_journal_entry_id,
      posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_payment_id;

  return v_journal_entry_id;
end;
$function$;

revoke all on function public.post_contact_payment(uuid, uuid)
  from public, anon;
grant execute on function public.post_contact_payment(uuid, uuid)
  to authenticated;


-- ============================================================================
-- SALES POSTING RPC
-- ============================================================================

-- Zero ERP: atomic sales posting with contact-wise receivables, revenue, COGS and stock effects.
-- Revenue discounts are allocated proportionally; the final line receives rounding residue.
-- COGS is calculated server-side from the locked weighted-average inventory balance.

create unique index journal_entries_sales_reference_uq
  on public.journal_entries (organization_id, reference_type, reference_id)
  where entry_type = 'sale' and reference_type = 'sale' and reference_id is not null;

create or replace function public.post_sales(
  p_organization_id uuid,
  p_sales_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_sales public.sales%rowtype;
  v_customer_active boolean;
  v_receivable public.accounts%rowtype;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_allocated_revenue numeric(20,4) := 0;
  v_line_revenue numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_line_cost numeric(20,4);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_journal_id uuid;
  v_line record;
  v_last_line integer;
  v_line_number integer := 0;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication is required to post a sales invoice.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'sales.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post sales for this organization.';
  end if;

  select s.* into v_sales
  from public.sales s
  where s.organization_id = p_organization_id and s.id = p_sales_id
  for update;

  if not found then
    raise exception using errcode = '23503', message = 'Sales invoice was not found in this organization.';
  end if;
  if v_sales.status <> 'confirmed' or v_sales.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted sales invoice can be posted.';
  end if;

  select c.is_active into v_customer_active
  from public.contacts c
  where c.organization_id = p_organization_id and c.id = v_sales.customer_id
  for update;
  if coalesce(v_customer_active, false) is not true then
    raise exception using errcode = '23503', message = 'Customer must be active and belong to this organization.';
  end if;

  select a.* into v_receivable
  from public.accounts a
  where a.organization_id = p_organization_id and a.id = v_sales.receivable_account_id;
  if not found or not v_receivable.is_active or not v_receivable.is_postable
     or not v_receivable.is_control_account or v_receivable.account_type <> 'asset' then
    raise exception using errcode = '23503',
      message = 'Receivable account must be an active, postable asset control account.';
  end if;

  select count(*)::integer, coalesce(sum(si.line_total), 0), max(si.line_number)
  into v_line_count, v_subtotal, v_last_line
  from public.sales_items si
  where si.organization_id = p_organization_id and si.sales_id = p_sales_id;

  if v_line_count < 1 then
    raise exception using errcode = '23514', message = 'A sales invoice must contain at least one item.';
  end if;
  if v_subtotal <> v_sales.subtotal then
    raise exception using errcode = '23514', message = 'Sales subtotal must equal the sum of item line totals.';
  end if;
  if v_sales.discount_amount > v_subtotal
     or v_sales.total_amount <> v_subtotal - v_sales.discount_amount
     or v_sales.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Sales totals are inconsistent or net total is not positive.';
  end if;

  if exists (
    select 1
    from public.sales_items si
    join public.products pr on pr.organization_id = si.organization_id and pr.id = si.product_id
    left join public.accounts sa on sa.organization_id = pr.organization_id and sa.id = pr.sales_account_id
    left join public.accounts ia on ia.organization_id = pr.organization_id and ia.id = pr.inventory_account_id
    left join public.accounts ca on ca.organization_id = pr.organization_id and ca.id = pr.cogs_account_id
    where si.organization_id = p_organization_id and si.sales_id = p_sales_id
      and (
        not pr.is_active
        or sa.id is null or not sa.is_active or not sa.is_postable or sa.account_type <> 'revenue'
        or ia.id is null or not ia.is_active or not ia.is_postable or ia.account_type <> 'asset'
        or ca.id is null or not ca.is_active or not ca.is_postable or ca.account_type <> 'expense'
        or si.line_total <> round(si.quantity * si.unit_price, 4)
      )
  ) then
    raise exception using errcode = '23514',
      message = 'Each item requires an active product, valid revenue/inventory/COGS accounts, and a consistent line total.';
  end if;

  -- Lock each product balance in deterministic order and reject insufficient stock.
  for v_line in
    select distinct si.product_id
    from public.sales_items si
    where si.organization_id = p_organization_id and si.sales_id = p_sales_id
    order by si.product_id
  loop
    select b.quantity, b.inventory_value, b.average_cost
    into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    if not found then
      raise exception using errcode = '23514',
        message = 'Opening stock or a prior stock receipt is required before this product can be sold.';
    end if;

    if v_balance_quantity < (
      select coalesce(sum(si.quantity), 0)
      from public.sales_items si
      where si.organization_id = p_organization_id
        and si.sales_id = p_sales_id and si.product_id = v_line.product_id
    ) then
      raise exception using errcode = '23514',
        message = 'Insufficient stock to post this sales invoice.';
    end if;
    if v_balance_quantity < 0 or v_balance_value < 0 then
      raise exception using errcode = '23514',
        message = 'Negative inventory balance must be reconciled before sales posting.';
    end if;
  end loop;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description, posted_at, posted_by, created_by
  )
  values (
    p_organization_id,
    'SAL-' || pg_catalog.replace(p_sales_id::text, '-', ''),
    v_sales.invoice_date, 'sale', 'posted',
    'sale', p_sales_id, 'Sales invoice ' || v_sales.invoice_id,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  -- Allocate net sales revenue to products/accounts; last line absorbs rounding residue.
  for v_line in
    select si.id, si.product_id, si.quantity, si.line_total, si.line_number,
           pr.sales_account_id, pr.inventory_account_id, pr.cogs_account_id
    from public.sales_items si
    join public.products pr on pr.organization_id = si.organization_id and pr.id = si.product_id
    where si.organization_id = p_organization_id and si.sales_id = p_sales_id
    order by si.line_number
  loop
    if v_line.line_number = v_last_line then
      v_line_revenue := v_sales.total_amount - v_allocated_revenue;
    else
      v_line_revenue := round(v_line.line_total * v_sales.total_amount / v_subtotal, 4);
      v_allocated_revenue := v_allocated_revenue + v_line_revenue;
    end if;

    select b.quantity, b.inventory_value, b.average_cost
    into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    v_line_cost := case when v_line.quantity = v_balance_quantity
      then v_balance_value else round(v_line.quantity * v_average_cost, 4) end;
    v_new_quantity := v_balance_quantity - v_line.quantity;
    v_new_value := v_balance_value - v_line_cost;

    if v_new_quantity < 0 or v_new_value < 0 then
      raise exception using errcode = '23514',
        message = 'Sales would create a negative stock quantity or inventory value.';
    end if;

    update public.inventory_balances
    set quantity = v_new_quantity,
        inventory_value = v_new_value,
        average_cost = case when v_new_quantity = 0 then 0 else v_average_cost end,
        updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_line.product_id;

    update public.sales_items
    set cogs_unit_cost = v_average_cost,
        cogs_total = v_line_cost,
        updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_line.id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'SAL-' || pg_catalog.replace(p_sales_id::text, '-', '') || '-' || v_line.line_number::text,
      v_line.product_id, v_sales.invoice_date, 'sale', 'out', v_line.quantity,
      v_average_cost, v_line_cost, 'sale', p_sales_id,
      v_average_cost, case when v_new_quantity = 0 then 0 else v_average_cost end, v_user_id
    );

    -- Revenue line, net of the proportionally allocated invoice discount.
    if v_line_revenue > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number,
        description, debit, credit, contact_id
      )
      values (
        p_organization_id, v_journal_id, v_line.sales_account_id, v_line_number + 1,
        'Sales revenue - ' || v_sales.invoice_id, 0, v_line_revenue, null
      );
      v_line_number := v_line_number + 1;
    end if;

    -- COGS debit and inventory credit are posted per invoice line.
    if v_line_cost > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number,
        description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_id, v_line.cogs_account_id, v_line_number + 1,
         'Cost of goods sold - ' || v_sales.invoice_id, v_line_cost, 0, null),
        (p_organization_id, v_journal_id, v_line.inventory_account_id, v_line_number + 2,
         'Inventory issued - ' || v_sales.invoice_id, 0, v_line_cost, null);
      v_line_number := v_line_number + 2;
    end if;
  end loop;

  -- Receivable debit is the single contact-tagged customer balance line.
  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_sales.receivable_account_id,
    v_line_number + 1, 'Accounts receivable - ' || v_sales.invoice_id,
    v_sales.total_amount, 0, v_sales.customer_id
  );

  update public.sales
  set status = 'posted', posted_journal_entry_id = v_journal_id, posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_sales_id;

  return v_journal_id;
end;
$$;

revoke all on function public.post_sales(uuid, uuid) from public, anon;
grant execute on function public.post_sales(uuid, uuid) to authenticated;



-- ============================================================================
-- TRANSACTION DOCUMENT LIFECYCLE RPCS
-- ============================================================================





create or replace function public.reverse_journal_entry(
  p_organization_id uuid,
  p_journal_entry_id uuid,
  p_reversal_date date,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_original public.journal_entries%rowtype;
  v_reversal_id uuid;
  v_source_status text;
  v_source_purchase_id uuid;
  v_source_sales_id uuid;
  v_inventory record;
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_direction text;
  v_txn_line integer := 0;
  v_contact_id uuid;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'journal_entries.reverse') then
    raise exception using errcode = '42501', message = 'You are not authorized to reverse journal entries for this organization.';
  end if;
  if p_reversal_date is null or p_reason is null or pg_catalog.length(pg_catalog.btrim(p_reason)) < 3 then
    raise exception using errcode = '22023', message = 'A reversal date and reason of at least three characters are required.';
  end if;

  select * into v_original
  from public.journal_entries
  where organization_id = p_organization_id and id = p_journal_entry_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Original journal entry was not found in this organization.';
  end if;
  if v_original.status <> 'posted' or v_original.reversal_of_id is not null
     or v_original.entry_type not in ('manual','expense','payment','purchase_return','sales_return','adjustment') then
    raise exception using errcode = '23514',
      message = 'Only posted manual, expense, payment, return, and inventory-adjustment journals can be reversed here. Purchase and sales invoices require return documents; opening balances require a separate controlled adjustment.';
  end if;
  if exists (
    select 1 from public.journal_entries
    where organization_id = p_organization_id and reversal_of_id = p_journal_entry_id
  ) then
    raise exception using errcode = '23514', message = 'This journal entry has already been reversed.';
  end if;

  if v_original.entry_type = 'adjustment' then
    if v_original.reference_type is distinct from 'inventory_adjustment'
       or v_original.reference_id is distinct from p_journal_entry_id
       or not exists (
         select 1 from public.inventory_transactions it
         where it.organization_id=p_organization_id
           and it.reference_type='inventory_adjustment'
           and it.reference_id=p_journal_entry_id
       ) then
      raise exception using errcode='23514',message='Inventory adjustment source movements are missing or invalid.';
    end if;
  end if;

  if v_original.entry_type = 'expense' then
    select e.status into v_source_status
    from public.expenses e
    where e.organization_id = p_organization_id and e.id = v_original.reference_id
      and e.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Expense source document is missing, already reversed, or no longer posted.';
    end if;
  elsif v_original.entry_type = 'payment' then
    select p.status into v_source_status
    from public.payments p
    where p.organization_id = p_organization_id and p.id = v_original.reference_id
      and p.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Payment source document is missing, already reversed, or no longer posted.';
    end if;
  elsif v_original.entry_type = 'purchase_return' then
    select pr.status, pr.purchase_id into v_source_status, v_source_purchase_id
    from public.purchase_returns pr
    where pr.organization_id = p_organization_id and pr.id = v_original.reference_id
      and pr.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Purchase return source document is missing, already reversed, or no longer posted.';
    end if;
    perform 1 from public.purchase
    where organization_id = p_organization_id and id = v_source_purchase_id
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Original purchase for this return no longer exists.';
    end if;
  elsif v_original.entry_type = 'sales_return' then
    select sr.status, sr.sales_id into v_source_status, v_source_sales_id
    from public.sales_returns sr
    where sr.organization_id = p_organization_id and sr.id = v_original.reference_id
      and sr.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Sales return source document is missing, already reversed, or no longer posted.';
    end if;
    perform 1 from public.sales
    where organization_id = p_organization_id and id = v_source_sales_id
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Original sales invoice for this return no longer exists.';
    end if;
  end if;

  -- Serialize AR/AP changes with contact-level payment posting.
  for v_contact_id in
    select distinct atx.contact_id
    from public.account_transactions atx
    where atx.organization_id = p_organization_id
      and atx.journal_entry_id = p_journal_entry_id
      and atx.contact_id is not null
    order by atx.contact_id
  loop
    perform 1 from public.contacts c
    where c.organization_id = p_organization_id and c.id = v_contact_id
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'A journal contact no longer exists in this organization.';
    end if;
  end loop;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, reversal_of_id, created_by
  )
  values (
    p_organization_id,
    'REV-' || pg_catalog.replace(p_journal_entry_id::text,'-',''),
    p_reversal_date, 'reversal', 'posted',
    'journal_entry_reversal', p_journal_entry_id,
    'Reversal of ' || v_original.entry_number || ': ' || pg_catalog.btrim(p_reason),
    pg_catalog.now(), v_user_id, p_journal_entry_id, v_user_id
  )
  returning id into v_reversal_id;

  if v_original.entry_type in ('purchase_return','sales_return','adjustment') then
    if not exists (
      select 1 from public.inventory_transactions it
      where it.organization_id = p_organization_id
        and it.reference_type = v_original.reference_type
        and it.reference_id = v_original.reference_id
    ) then
      raise exception using errcode = '23514', message = 'Return journal has no inventory movements to reverse.';
    end if;

    for v_inventory in
      select distinct it.product_id
      from public.inventory_transactions it
      where it.organization_id = p_organization_id
        and it.reference_type = v_original.reference_type
        and it.reference_id = v_original.reference_id
      order by it.product_id
    loop
      perform 1 from public.inventory_balances b
      where b.organization_id = p_organization_id and b.product_id = v_inventory.product_id
      for update;
      if not found then
        raise exception using errcode = '23514', message = 'Inventory balance is missing for a returned product.';
      end if;
    end loop;

    for v_inventory in
      select it.*
      from public.inventory_transactions it
      where it.organization_id = p_organization_id
        and it.reference_type = v_original.reference_type
        and it.reference_id = v_original.reference_id
      order by it.product_id, it.transaction_number
    loop
      select b.quantity, b.inventory_value, b.average_cost
        into v_balance_quantity, v_balance_value, v_average_cost
      from public.inventory_balances b
      where b.organization_id = p_organization_id and b.product_id = v_inventory.product_id
      for update;

      if v_original.entry_type = 'purchase_return'
         or (v_original.entry_type = 'adjustment' and v_inventory.direction = 'out') then
        v_direction := 'in';
        v_new_quantity := v_balance_quantity + v_inventory.quantity;
        v_new_value := v_balance_value + v_inventory.total_value;
      else
        v_direction := 'out';
        v_new_quantity := v_balance_quantity - v_inventory.quantity;
        v_new_value := v_balance_value - v_inventory.total_value;
        if v_new_quantity < 0 or v_new_value < 0 then
          raise exception using errcode = '23514', message = 'Cannot reverse this stock movement because the affected inventory has already been consumed.';
        end if;
      end if;
      v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity,6) end;

      update public.inventory_balances
      set quantity = v_new_quantity, inventory_value = v_new_value,
          average_cost = v_new_average, updated_at = pg_catalog.now()
      where organization_id = p_organization_id and product_id = v_inventory.product_id;

      v_txn_line := v_txn_line + 1;
      insert into public.inventory_transactions (
        organization_id, transaction_number, product_id, transaction_date,
        transaction_type, direction, quantity, unit_cost, total_value,
        reference_type, reference_id, unit_cost_before, average_cost_after, created_by
      )
      values (
        p_organization_id,
        'REV-' || pg_catalog.replace(v_reversal_id::text,'-','') || '-' || v_txn_line::text,
        v_inventory.product_id, p_reversal_date, 'adjustment', v_direction,
        v_inventory.quantity, v_inventory.unit_cost, v_inventory.total_value,
        'journal_entry_reversal', v_reversal_id, v_average_cost, v_new_average, v_user_id
      );
    end loop;
  end if;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  select
    p_organization_id, v_reversal_id, atx.account_id,
    row_number() over (order by atx.line_number)::integer,
    'Reversal: ' || coalesce(atx.description, v_original.entry_number),
    atx.credit, atx.debit, atx.contact_id
  from public.account_transactions atx
  where atx.organization_id = p_organization_id and atx.journal_entry_id = p_journal_entry_id;

  if not exists (
    select 1 from public.account_transactions
    where organization_id = p_organization_id and journal_entry_id = v_reversal_id
  ) then
    raise exception using errcode = '23514', message = 'Original journal entry has no ledger lines to reverse.';
  end if;

  update public.journal_entries
  set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
      reversed_at = pg_catalog.now(), reversed_by = v_user_id,
      reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_journal_entry_id;

  if v_original.entry_type = 'expense' then
    update public.expenses
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;
  elsif v_original.entry_type = 'payment' then
    update public.payments
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;
  elsif v_original.entry_type = 'purchase_return' then
    update public.purchase_returns
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;

    if exists (
      select 1 from public.purchase_returns pr
      where pr.organization_id = p_organization_id and pr.purchase_id = v_source_purchase_id and pr.status = 'posted'
    ) then
      if exists (
        select 1 from public.purchase_items pi
        where pi.organization_id = p_organization_id and pi.purchase_id = v_source_purchase_id
          and pi.quantity > coalesce((
            select sum(pri.quantity)
            from public.purchase_return_items pri
            join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
            where pri.organization_id = p_organization_id and pri.purchase_item_id = pi.id and pr.status = 'posted'
          ),0)
      ) then
        update public.purchase set status = 'partially_returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_purchase_id;
      else
        update public.purchase set status = 'returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_purchase_id;
      end if;
    else
      update public.purchase set status = 'posted', updated_at = pg_catalog.now()
      where organization_id = p_organization_id and id = v_source_purchase_id;
    end if;
  elsif v_original.entry_type = 'sales_return' then
    update public.sales_returns
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;

    if exists (
      select 1 from public.sales_returns sr
      where sr.organization_id = p_organization_id and sr.sales_id = v_source_sales_id and sr.status = 'posted'
    ) then
      if exists (
        select 1 from public.sales_items si
        where si.organization_id = p_organization_id and si.sales_id = v_source_sales_id
          and si.quantity > coalesce((
            select sum(sri.quantity)
            from public.sales_return_items sri
            join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
            where sri.organization_id = p_organization_id and sri.sales_item_id = si.id and sr.status = 'posted'
          ),0)
      ) then
        update public.sales set status = 'partially_returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_sales_id;
      else
        update public.sales set status = 'returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_sales_id;
      end if;
    else
      update public.sales set status = 'posted', updated_at = pg_catalog.now()
      where organization_id = p_organization_id and id = v_source_sales_id;
    end if;
  end if;

  return v_reversal_id;
end;
$function$;

revoke all on function public.reverse_journal_entry(uuid, uuid, date, text) from public, anon;
grant execute on function public.reverse_journal_entry(uuid, uuid, date, text) to authenticated;

create or replace function public.post_expense(
  p_organization_id uuid,
  p_expense_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_expense public.expenses%rowtype;
  v_expense_account_id uuid;
  v_category_active boolean;
  v_expense_account public.accounts%rowtype;
  v_payable_account public.accounts%rowtype;
  v_journal_id uuid;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'expenses.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post expenses for this organization.';
  end if;

  select * into v_expense
  from public.expenses
  where organization_id = p_organization_id and id = p_expense_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Expense was not found in this organization.';
  end if;
  if v_expense.status <> 'confirmed' or v_expense.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted expense can be posted.';
  end if;
  if v_expense.amount <= 0 or v_expense.payable_account_id is null then
    raise exception using errcode = '23514', message = 'Expense amount and payable account are required before posting.';
  end if;

  select ec.expense_account_id, ec.is_active
    into v_expense_account_id, v_category_active
  from public.expense_categories ec
  where ec.organization_id = p_organization_id and ec.id = v_expense.expense_category_id;
  if not found or not v_category_active or v_expense_account_id is null then
    raise exception using errcode = '23503', message = 'Expense category must be active and mapped to an expense account.';
  end if;

  select * into v_expense_account
  from public.accounts
  where organization_id = p_organization_id and id = v_expense_account_id;
  if not found or not v_expense_account.is_active or not v_expense_account.is_postable
     or v_expense_account.account_type <> 'expense' then
    raise exception using errcode = '23514', message = 'Expense category account must be an active, postable expense account.';
  end if;

  select * into v_payable_account
  from public.accounts
  where organization_id = p_organization_id and id = v_expense.payable_account_id;
  if not found or not v_payable_account.is_active or not v_payable_account.is_postable
     or v_payable_account.account_type <> 'liability' then
    raise exception using errcode = '23514', message = 'Expense payable account must be an active, postable liability account.';
  end if;

  if v_expense.contact_id is not null then
    if not v_payable_account.is_control_account then
      raise exception using errcode = '23514', message = 'A contact-linked expense requires a payable control account.';
    end if;
    perform 1 from public.contacts
    where organization_id = p_organization_id and id = v_expense.contact_id and is_active
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Expense contact must be active and belong to this organization.';
    end if;
  elsif v_payable_account.is_control_account then
    raise exception using errcode = '23514', message = 'A payable control account requires an expense contact.';
  end if;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, 'EXP-' || pg_catalog.replace(p_expense_id::text, '-', ''),
    v_expense.expense_date, 'expense', 'posted',
    'expense', p_expense_id,
    coalesce(nullif(pg_catalog.btrim(v_expense.description), ''), 'Expense ' || v_expense.expense_number),
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  values
    (p_organization_id, v_journal_id, v_expense_account.id, 1,
     'Expense - ' || v_expense.expense_number, v_expense.amount, 0, null),
    (p_organization_id, v_journal_id, v_payable_account.id, 2,
     'Expense payable - ' || v_expense.expense_number, 0, v_expense.amount, v_expense.contact_id);

  update public.expenses
  set status = 'posted', posted_journal_entry_id = v_journal_id,
      posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_expense_id;
  return v_journal_id;
end;
$function$;

revoke all on function public.post_expense(uuid, uuid) from public, anon;
grant execute on function public.post_expense(uuid, uuid) to authenticated;


create or replace function public.post_purchase_return(
  p_organization_id uuid,
  p_purchase_return_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_return public.purchase_returns%rowtype;
  v_purchase public.purchase%rowtype;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_inventory_value numeric(20,4) := 0;
  v_variance numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_return_quantity numeric(20,6);
  v_line_value numeric(20,4);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_journal_id uuid;
  v_line_number integer := 1;
  v_product record;
  v_account record;
  v_variance_account public.accounts%rowtype;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'purchases.returns.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post purchase returns for this organization.';
  end if;

  select * into v_return from public.purchase_returns
  where organization_id = p_organization_id and id = p_purchase_return_id for update;
  if not found then
    raise exception using errcode = '23503', message = 'Purchase return was not found in this organization.';
  end if;
  if v_return.status <> 'confirmed' or v_return.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted purchase return can be posted.';
  end if;

  select * into v_purchase from public.purchase
  where organization_id = p_organization_id and id = v_return.purchase_id for update;
  if not found or v_purchase.status not in ('posted','partially_returned') then
    raise exception using errcode = '23514', message = 'Purchase return requires a posted purchase that has not been fully returned.';
  end if;
  perform 1 from public.contacts c
  where c.organization_id = p_organization_id and c.id = v_purchase.supplier_id and c.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Supplier must be active and belong to this organization.';
  end if;

  if v_return.supplier_id <> v_purchase.supplier_id
     or v_return.payable_account_id <> v_purchase.payable_account_id then
    raise exception using errcode = '23514', message = 'Purchase return supplier and payable account must match the original purchase.';
  end if;

  if v_return.total_amount + coalesce((
    select sum(pr.total_amount) from public.purchase_returns pr
    where pr.organization_id = p_organization_id and pr.purchase_id = v_purchase.id and pr.status = 'posted'
  ),0) > v_purchase.total_amount then
    raise exception using errcode = '23514', message = 'Cumulative purchase returns cannot exceed the original purchase total.';
  end if;

  select count(*)::integer, coalesce(sum(line_total),0)
    into v_line_count, v_subtotal
  from public.purchase_return_items
  where organization_id = p_organization_id and purchase_return_id = p_purchase_return_id;
  if v_line_count < 1 or v_subtotal <> v_return.subtotal
     or v_return.discount_amount > v_subtotal
     or v_return.total_amount <> v_subtotal - v_return.discount_amount
     or v_return.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Purchase return items, subtotal, discount, and total are inconsistent.';
  end if;

  if exists (
    select 1
    from public.purchase_return_items ri
    join public.purchase_items pi on pi.organization_id = ri.organization_id and pi.id = ri.purchase_item_id
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
      and (pi.purchase_id <> v_purchase.id or pi.product_id <> ri.product_id
        or pi.unit_cost <> ri.unit_cost or ri.line_total <> round(ri.quantity * ri.unit_cost,4)
        or ri.quantity + coalesce((
          select sum(pri.quantity)
          from public.purchase_return_items pri
          join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
          where pri.organization_id = p_organization_id and pri.purchase_item_id = ri.purchase_item_id
            and pr.status = 'posted'
        ),0) > pi.quantity)
  ) then
    raise exception using errcode = '23514', message = 'Return quantity or unit cost exceeds the unreturned quantity/cost of the original purchase item.';
  end if;


  if exists (
    select 1
    from public.purchase_return_items ri
    join public.purchase_items pi on pi.organization_id = ri.organization_id and pi.id = ri.purchase_item_id
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
    group by ri.purchase_item_id, pi.quantity
    having sum(ri.quantity) + coalesce((
      select sum(pri.quantity)
      from public.purchase_return_items pri
      join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
      where pri.organization_id = p_organization_id and pri.purchase_item_id = ri.purchase_item_id and pr.status = 'posted'
    ),0) > pi.quantity
  ) then
    raise exception using errcode = '23514', message = 'Combined return lines cannot exceed the remaining quantity of an original purchase item.';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.organization_id = p_organization_id and a.id = v_return.payable_account_id
      and a.is_active and a.is_postable and a.is_control_account and a.account_type = 'liability'
  ) then
    raise exception using errcode = '23514', message = 'Purchase return payable account must be an active liability control account.';
  end if;

  if exists (
    select 1 from public.purchase_return_items ri
    join public.products pr on pr.organization_id = ri.organization_id and pr.id = ri.product_id
    left join public.accounts ia on ia.organization_id = pr.organization_id and ia.id = pr.inventory_account_id
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
      and (ia.id is null or not ia.is_active or not ia.is_postable or ia.account_type <> 'asset')
  ) then
    raise exception using errcode = '23514', message = 'Every returned product must be active and mapped to an active, postable inventory asset account.';
  end if;

  for v_product in
    select ri.product_id, sum(ri.quantity) as quantity
    from public.purchase_return_items ri
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
    group by ri.product_id order by ri.product_id
  loop
    select b.quantity, b.inventory_value, b.average_cost
      into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_product.product_id
    for update;
    if not found then
      raise exception using errcode = '23514', message = 'Returned product has no inventory balance to reduce.';
    end if;
    v_return_quantity := v_product.quantity;
    v_line_value := case when v_return_quantity = v_balance_quantity
      then v_balance_value else round(v_return_quantity * v_average_cost,4) end;
    if v_balance_quantity < v_return_quantity or v_balance_value < v_line_value then
      raise exception using errcode = '23514', message = 'Insufficient on-hand quantity or inventory value for this purchase return.';
    end if;
    v_new_quantity := v_balance_quantity - v_return_quantity;
    v_new_value := v_balance_value - v_line_value;
    v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity,6) end;
    update public.inventory_balances
    set quantity = v_new_quantity, inventory_value = v_new_value,
        average_cost = v_new_average, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_product.product_id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'PR-' || pg_catalog.replace(p_purchase_return_id::text,'-','') || '-' || pg_catalog.replace(v_product.product_id::text,'-',''),
      v_product.product_id, v_return.return_date, 'purchase_return', 'out',
      v_return_quantity, v_average_cost, v_line_value,
      'purchase_return', p_purchase_return_id, v_average_cost, v_new_average, v_user_id
    );
    v_inventory_value := v_inventory_value + v_line_value;
  end loop;

  v_variance := v_return.total_amount - v_inventory_value;
  if v_variance <> 0 then
    select * into v_variance_account
    from public.accounts
    where organization_id = p_organization_id and id = v_return.purchase_return_variance_account_id;
    if not found or not v_variance_account.is_active or not v_variance_account.is_postable
       or (v_variance > 0 and v_variance_account.account_type <> 'revenue')
       or (v_variance < 0 and v_variance_account.account_type <> 'expense') then
      raise exception using errcode = '23514',
        message = 'Purchase return requires a postable revenue variance account when supplier credit exceeds inventory carrying value, or an expense variance account when it is lower.';
    end if;
  end if;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, 'PR-' || pg_catalog.replace(p_purchase_return_id::text,'-',''),
    v_return.return_date, 'purchase_return', 'posted',
    'purchase_return', p_purchase_return_id, 'Purchase return ' || v_return.return_number,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_return.payable_account_id, v_line_number,
    'Supplier credit - ' || v_return.return_number, v_return.total_amount, 0, v_return.supplier_id
  );
  v_line_number := v_line_number + 1;

  for v_account in
    select pr.inventory_account_id as account_id, sum(it.total_value) as amount
    from public.inventory_transactions it
    join public.products pr on pr.organization_id = it.organization_id and pr.id = it.product_id
    where it.organization_id = p_organization_id
      and it.reference_type = 'purchase_return' and it.reference_id = p_purchase_return_id
    group by pr.inventory_account_id order by pr.inventory_account_id
  loop
    if v_account.amount > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values (p_organization_id, v_journal_id, v_account.account_id, v_line_number,
        'Inventory returned to supplier - ' || v_return.return_number, 0, v_account.amount, null);
      v_line_number := v_line_number + 1;
    end if;
  end loop;

  if v_variance > 0 then
    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
    )
    values (p_organization_id, v_journal_id, v_variance_account.id, v_line_number,
      'Purchase return price variance - ' || v_return.return_number, 0, v_variance, null);
  elsif v_variance < 0 then
    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
    )
    values (p_organization_id, v_journal_id, v_variance_account.id, v_line_number,
      'Purchase return price variance - ' || v_return.return_number, abs(v_variance), 0, null);
  end if;

  update public.purchase_returns
  set status = 'posted', posted_journal_entry_id = v_journal_id, posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_purchase_return_id;

  if exists (
    select 1 from public.purchase_items pi
    where pi.organization_id = p_organization_id and pi.purchase_id = v_purchase.id
      and pi.quantity > coalesce((
        select sum(pri.quantity)
        from public.purchase_return_items pri
        join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
        where pri.organization_id = p_organization_id and pri.purchase_item_id = pi.id and pr.status = 'posted'
      ),0)
  ) then
    update public.purchase set status = 'partially_returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_purchase.id;
  else
    update public.purchase set status = 'returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_purchase.id;
  end if;
  return v_journal_id;
end;
$function$;

revoke all on function public.post_purchase_return(uuid, uuid) from public, anon;
grant execute on function public.post_purchase_return(uuid, uuid) to authenticated;


create or replace function public.post_sales_return(
  p_organization_id uuid,
  p_sales_return_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_return public.sales_returns%rowtype;
  v_sales public.sales%rowtype;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_allocated_revenue numeric(20,4) := 0;
  v_line_revenue numeric(20,4);
  v_line_cost numeric(20,4);
  v_previously_returned_quantity numeric(20,6);
  v_previously_returned_cogs numeric(20,4);
  v_remaining_quantity numeric(20,6);
  v_remaining_cogs numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_journal_id uuid;
  v_line_number integer := 1;
  v_last_line integer;
  v_line record;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'sales.returns.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post sales returns for this organization.';
  end if;

  select * into v_return from public.sales_returns
  where organization_id = p_organization_id and id = p_sales_return_id for update;
  if not found then
    raise exception using errcode = '23503', message = 'Sales return was not found in this organization.';
  end if;
  if v_return.status <> 'confirmed' or v_return.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted sales return can be posted.';
  end if;

  select * into v_sales from public.sales
  where organization_id = p_organization_id and id = v_return.sales_id for update;
  if not found or v_sales.status not in ('posted','partially_returned') then
    raise exception using errcode = '23514', message = 'Sales return requires a posted sales invoice that has not been fully returned.';
  end if;
  perform 1 from public.contacts c
  where c.organization_id = p_organization_id and c.id = v_sales.customer_id and c.is_active
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Customer must be active and belong to this organization.';
  end if;

  if v_return.customer_id <> v_sales.customer_id
     or v_return.receivable_account_id <> v_sales.receivable_account_id then
    raise exception using errcode = '23514', message = 'Sales return customer and receivable account must match the original sales invoice.';
  end if;

  if v_return.total_amount + coalesce((
    select sum(sr.total_amount) from public.sales_returns sr
    where sr.organization_id = p_organization_id and sr.sales_id = v_sales.id and sr.status = 'posted'
  ),0) > v_sales.total_amount then
    raise exception using errcode = '23514', message = 'Cumulative sales returns cannot exceed the original sales invoice total.';
  end if;

  select count(*)::integer, coalesce(sum(line_total),0), max(line_number)
    into v_line_count, v_subtotal, v_last_line
  from public.sales_return_items
  where organization_id = p_organization_id and sales_return_id = p_sales_return_id;
  if v_line_count < 1 or v_subtotal <> v_return.subtotal
     or v_return.discount_amount > v_subtotal
     or v_return.total_amount <> v_subtotal - v_return.discount_amount
     or v_return.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Sales return items, subtotal, discount, and total are inconsistent.';
  end if;

  if v_return.total_amount > coalesce((
    select round(sum(ri.line_total * v_sales.total_amount / nullif(v_sales.subtotal, 0)), 4)
    from public.sales_return_items ri
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
      and v_sales.subtotal > 0
  ), 0) then
    raise exception using errcode = '23514',
      message = 'Sales return total cannot exceed the original net value of the returned lines after allocating the invoice discount.';
  end if;

  if exists (
    select 1
    from public.sales_return_items ri
    join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
      and (si.sales_id <> v_sales.id or si.product_id <> ri.product_id
        or si.unit_price <> ri.unit_price or ri.line_total <> round(ri.quantity * ri.unit_price,4)
        or ri.quantity + coalesce((
          select sum(sri.quantity)
          from public.sales_return_items sri
          join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
          where sri.organization_id = p_organization_id and sri.sales_item_id = ri.sales_item_id and sr.status = 'posted'
        ),0) > si.quantity)
  ) then
    raise exception using errcode = '23514', message = 'Return quantity or unit price exceeds the unreturned quantity/price of the original sales item.';
  end if;


  if exists (
    select 1
    from public.sales_return_items ri
    join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
    group by ri.sales_item_id, si.quantity
    having sum(ri.quantity) + coalesce((
      select sum(sri.quantity)
      from public.sales_return_items sri
      join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
      where sri.organization_id = p_organization_id and sri.sales_item_id = ri.sales_item_id and sr.status = 'posted'
    ),0) > si.quantity
  ) then
    raise exception using errcode = '23514', message = 'Combined return lines cannot exceed the remaining quantity of an original sales item.';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.organization_id = p_organization_id and a.id = v_return.receivable_account_id
      and a.is_active and a.is_postable and a.is_control_account and a.account_type = 'asset'
  ) then
    raise exception using errcode = '23514', message = 'Sales return receivable account must be an active asset control account.';
  end if;

  if exists (
    select 1
    from public.sales_return_items ri
    join public.products pr on pr.organization_id = ri.organization_id and pr.id = ri.product_id
    left join public.accounts sa on sa.organization_id = pr.organization_id and sa.id = pr.sales_account_id
    left join public.accounts ia on ia.organization_id = pr.organization_id and ia.id = pr.inventory_account_id
    left join public.accounts ca on ca.organization_id = pr.organization_id and ca.id = pr.cogs_account_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
      and (sa.id is null or not sa.is_active or not sa.is_postable or sa.account_type <> 'revenue'
        or ia.id is null or not ia.is_active or not ia.is_postable or ia.account_type <> 'asset'
        or ca.id is null or not ca.is_active or not ca.is_postable or ca.account_type <> 'expense')
  ) then
    raise exception using errcode = '23514', message = 'Returned products require active, postable revenue, inventory, and COGS account mappings.';
  end if;

  for v_line in
    select distinct ri.product_id
    from public.sales_return_items ri
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
    order by ri.product_id
  loop
    perform 1 from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;
    if not found then
      raise exception using errcode = '23514', message = 'Returned product has no inventory balance row.';
    end if;
  end loop;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, 'SR-' || pg_catalog.replace(p_sales_return_id::text,'-',''),
    v_return.return_date, 'sales_return', 'posted',
    'sales_return', p_sales_return_id, 'Sales return ' || v_return.return_number,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  for v_line in
    select ri.id, ri.sales_item_id, ri.product_id, ri.quantity, ri.line_total, ri.line_number,
           si.cogs_unit_cost, si.quantity as sold_quantity, si.cogs_total as sold_cogs_total,
           pr.sales_account_id, pr.inventory_account_id, pr.cogs_account_id
    from public.sales_return_items ri
    join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
    join public.products pr on pr.organization_id = ri.organization_id and pr.id = ri.product_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
    order by ri.line_number
  loop
    if v_line.line_number = v_last_line then
      v_line_revenue := v_return.total_amount - v_allocated_revenue;
    else
      v_line_revenue := round(v_line.line_total * v_return.total_amount / v_subtotal,4);
      v_allocated_revenue := v_allocated_revenue + v_line_revenue;
    end if;
    select coalesce(sum(sri.quantity),0), coalesce(sum(sri.cogs_total),0)
      into v_previously_returned_quantity, v_previously_returned_cogs
    from public.sales_return_items sri
    join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
    where sri.organization_id = p_organization_id
      and sri.sales_item_id = v_line.sales_item_id
      and sr.status = 'posted';

    v_remaining_quantity := v_line.sold_quantity - v_previously_returned_quantity;
    v_remaining_cogs := v_line.sold_cogs_total - v_previously_returned_cogs;
    if v_line.quantity = v_remaining_quantity then
      v_line_cost := v_remaining_cogs;
    else
      v_line_cost := least(
        round(v_line.quantity * v_remaining_cogs / v_remaining_quantity,4),
        v_remaining_cogs
      );
    end if;

    select b.quantity, b.inventory_value, b.average_cost
      into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    v_new_quantity := v_balance_quantity + v_line.quantity;
    v_new_value := v_balance_value + v_line_cost;
    v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity,6) end;

    update public.inventory_balances
    set quantity = v_new_quantity, inventory_value = v_new_value,
        average_cost = v_new_average, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_line.product_id;

    update public.sales_return_items
    set cogs_unit_cost = v_line.cogs_unit_cost, cogs_total = v_line_cost, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_line.id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'SR-' || pg_catalog.replace(p_sales_return_id::text,'-','') || '-' || v_line.line_number::text,
      v_line.product_id, v_return.return_date, 'sales_return', 'in',
      v_line.quantity, v_line.cogs_unit_cost, v_line_cost,
      'sales_return', p_sales_return_id, v_average_cost, v_new_average, v_user_id
    );

    if v_line_revenue > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values (p_organization_id, v_journal_id, v_line.sales_account_id, v_line_number,
        'Sales return - ' || v_return.return_number, v_line_revenue, 0, null);
      v_line_number := v_line_number + 1;
    end if;

    if v_line_cost > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_id, v_line.inventory_account_id, v_line_number,
         'Inventory returned by customer - ' || v_return.return_number, v_line_cost, 0, null),
        (p_organization_id, v_journal_id, v_line.cogs_account_id, v_line_number + 1,
         'Reverse cost of goods sold - ' || v_return.return_number, 0, v_line_cost, null);
      v_line_number := v_line_number + 2;
    end if;
  end loop;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_return.receivable_account_id,
    v_line_number, 'Customer credit - ' || v_return.return_number, 0, v_return.total_amount, v_return.customer_id
  );

  update public.sales_returns
  set status = 'posted', posted_journal_entry_id = v_journal_id,
      posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_sales_return_id;

  if exists (
    select 1 from public.sales_items si
    where si.organization_id = p_organization_id and si.sales_id = v_sales.id
      and si.quantity > coalesce((
        select sum(sri.quantity)
        from public.sales_return_items sri
        join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
        where sri.organization_id = p_organization_id and sri.sales_item_id = si.id and sr.status = 'posted'
      ),0)
  ) then
    update public.sales set status = 'partially_returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_sales.id;
  else
    update public.sales set status = 'returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_sales.id;
  end if;
  return v_journal_id;
end;
$function$;

revoke all on function public.post_sales_return(uuid, uuid) from public, anon;
grant execute on function public.post_sales_return(uuid, uuid) to authenticated;

create or replace function public.post_confirmed_journal_entry(
  p_organization_id uuid,
  p_journal_entry_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_entry public.journal_entries%rowtype;
  v_line_count integer;
  v_debit numeric(20,4);
  v_credit numeric(20,4);
  v_contact_id uuid;
begin
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for share;
  if not found then
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;

  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'journal_entries.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post journal entries for this organization.';
  end if;

  select * into v_entry
  from public.journal_entries
  where organization_id = p_organization_id and id = p_journal_entry_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Journal entry was not found in this organization.';
  end if;
  if v_entry.entry_type <> 'manual' or v_entry.status <> 'confirmed' or v_entry.posted_at is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted manual journal entry can be posted by this function.';
  end if;

  select count(*)::integer, coalesce(sum(atx.debit), 0), coalesce(sum(atx.credit), 0)
    into v_line_count, v_debit, v_credit
  from public.account_transactions atx
  where atx.organization_id = p_organization_id and atx.journal_entry_id = p_journal_entry_id;
  if v_line_count < 2 or v_debit <= 0 or v_debit <> v_credit then
    raise exception using errcode = '23514', message = 'Journal entry must have at least two lines and balanced debits and credits.';
  end if;

  if exists (
    select 1
    from public.account_transactions atx
    join public.accounts a on a.organization_id = atx.organization_id and a.id = atx.account_id
    where atx.organization_id = p_organization_id
      and atx.journal_entry_id = p_journal_entry_id
      and (not a.is_active or not a.is_postable)
  ) then
    raise exception using errcode = '23514', message = 'All journal accounts must be active and postable before posting.';
  end if;

  if exists (
    select 1
    from public.account_transactions atx
    left join public.contacts c
      on c.organization_id = atx.organization_id and c.id = atx.contact_id
    where atx.organization_id = p_organization_id
      and atx.journal_entry_id = p_journal_entry_id
      and atx.contact_id is not null
      and (c.id is null or not c.is_active)
  ) then
    raise exception using errcode = '23514', message = 'Every journal contact must be active and belong to this organization.';
  end if;

  for v_contact_id in
    select distinct atx.contact_id
    from public.account_transactions atx
    where atx.organization_id = p_organization_id
      and atx.journal_entry_id = p_journal_entry_id
      and atx.contact_id is not null
    order by atx.contact_id
  loop
    perform 1 from public.contacts c
    where c.organization_id = p_organization_id and c.id = v_contact_id
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'A journal contact no longer exists in this organization.';
    end if;
  end loop;

  update public.journal_entries
  set status = 'posted', posted_at = pg_catalog.now(), posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_journal_entry_id;

  return p_journal_entry_id;
end;
$$;

revoke all on function public.post_confirmed_journal_entry(uuid, uuid) from public, anon;
grant execute on function public.post_confirmed_journal_entry(uuid, uuid) to authenticated;


create or replace function public.save_draft_transaction_document(
  p_organization_id uuid,
  p_document_type text,
  p_header jsonb,
  p_items jsonb default null,
  p_document_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_table text;
  v_child_table text;
  v_parent_column text;
  v_permission text;
  v_allowed_header text[];
  v_child_columns text[];
  v_document_id uuid := coalesce(p_document_id, pg_catalog.gen_random_uuid());
  v_status text;
  v_key text;
  v_columns text;
  v_values text;
  v_set_clause text;
  v_child_column_list text;
  v_child_value_list text;
  v_sql text;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id) then
    raise exception using errcode = '42501', message = 'An authenticated active organization member is required.';
  end if;
  if p_header is null or pg_catalog.jsonb_typeof(p_header) <> 'object'
     or (p_items is not null and pg_catalog.jsonb_typeof(p_items) <> 'array') then
    raise exception using errcode = '22023', message = 'Document header must be a JSON object and items must be a JSON array.';
  end if;

  case p_document_type
    when 'purchase' then
      v_table := 'purchase'; v_child_table := 'purchase_items'; v_parent_column := 'purchase_id';
      v_permission := 'purchases.create';
      v_allowed_header := array['invoice_id','supplier_id','invoice_date','subtotal','discount_amount','total_amount','payable_account_id'];
      v_child_columns := array['line_number','product_id','quantity','unit_cost','line_total'];
    when 'sales' then
      v_table := 'sales'; v_child_table := 'sales_items'; v_parent_column := 'sales_id';
      v_permission := 'sales.create';
      v_allowed_header := array['invoice_id','customer_id','invoice_date','subtotal','discount_amount','total_amount','receivable_account_id'];
      v_child_columns := array['line_number','product_id','quantity','unit_price','line_total'];
    when 'expense' then
      v_table := 'expenses'; v_permission := 'expenses.manage';
      v_allowed_header := array['expense_number','expense_category_id','contact_id','payable_account_id','expense_date','amount','description'];
      v_child_columns := array[]::text[];
    when 'payment' then
      v_table := 'payments';
      v_permission := 'payments.manage';
      v_allowed_header := array['payment_number','payment_type','contact_id','payment_date','amount','account_id','settlement_account_id','description'];
      v_child_columns := array[]::text[];
    when 'purchase_return' then
      v_table := 'purchase_returns'; v_child_table := 'purchase_return_items'; v_parent_column := 'purchase_return_id';
      v_permission := 'purchases.returns.create';
      v_allowed_header := array['return_number','purchase_id','supplier_id','return_date','subtotal','discount_amount','total_amount','payable_account_id','purchase_return_variance_account_id'];
      v_child_columns := array['line_number','purchase_item_id','product_id','quantity','unit_cost','line_total'];
    when 'sales_return' then
      v_table := 'sales_returns'; v_child_table := 'sales_return_items'; v_parent_column := 'sales_return_id';
      v_permission := 'sales.returns.create';
      v_allowed_header := array['return_number','sales_id','customer_id','return_date','subtotal','discount_amount','total_amount','receivable_account_id'];
      v_child_columns := array['line_number','sales_item_id','product_id','quantity','unit_price','line_total'];
    when 'journal_entry' then
      v_table := 'journal_entries'; v_child_table := 'account_transactions'; v_parent_column := 'journal_entry_id';
      v_permission := 'journal_entries.create';
      v_allowed_header := array['entry_number','entry_date','entry_type','reference_type','reference_id','description'];
      v_child_columns := array['account_id','line_number','description','debit','credit','contact_id'];
    else
      raise exception using errcode = '22023', message = 'Unsupported transaction document type.';
  end case;

  if not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'You do not have permission to create or update this draft document.';
  end if;

  if p_document_type = 'journal_entry' then
    if p_header ? 'entry_type' and p_header->>'entry_type' <> 'manual' then
      raise exception using errcode = '22023', message = 'User-created draft journal entries must have entry_type manual.';
    end if;
    p_header := p_header || pg_catalog.jsonb_build_object('entry_type', 'manual');
  end if;

  for v_key in select pg_catalog.jsonb_object_keys(p_header)
  loop
    if not (v_key = any(v_allowed_header)) then
      raise exception using errcode = '22023', message = pg_catalog.format('Header field %s is not editable through this draft function.', v_key);
    end if;
  end loop;

  if p_document_id is null then
    if p_header = '{}'::jsonb then
      raise exception using errcode = '22023', message = 'A new draft requires header fields.';
    end if;
    select
      pg_catalog.string_agg(pg_catalog.format('%I', k), ', ' order by k),
      pg_catalog.string_agg(
        pg_catalog.format('(pg_catalog.jsonb_populate_record(null::public.%I, $3)).%I', v_table, k),
        ', ' order by k
      )
    into v_columns, v_values
    from pg_catalog.jsonb_object_keys(p_header) as keys(k);

    v_sql := pg_catalog.format(
      'insert into public.%I (id, organization_id, created_by, %s) values ($1, $2, $4, %s)',
      v_table, v_columns, v_values
    );
    execute v_sql using v_document_id, p_organization_id, p_header, v_user_id;
  else
    execute pg_catalog.format(
      'select status from public.%I where organization_id = $1 and id = $2 for update', v_table
    ) into v_status using p_organization_id, v_document_id;
    if v_status is null then
      raise exception using errcode = '23503', message = 'Draft document was not found in this organization.';
    end if;
    if v_status <> 'draft' then
      raise exception using errcode = '23514', message = 'Only draft documents can be edited.';
    end if;

    select pg_catalog.string_agg(
      pg_catalog.format('%I = (pg_catalog.jsonb_populate_record(null::public.%I, $3)).%I', k, v_table, k),
      ', ' order by k
    )
    into v_set_clause
    from pg_catalog.jsonb_object_keys(p_header) as keys(k);

    if v_set_clause is null then
      v_set_clause := 'updated_at = pg_catalog.now()';
    else
      v_set_clause := v_set_clause || ', updated_at = pg_catalog.now()';
    end if;
    execute pg_catalog.format(
      'update public.%I set %s where organization_id = $1 and id = $2 and status = ''draft''',
      v_table, v_set_clause
    ) using p_organization_id, v_document_id, p_header;
  end if;

  if v_child_table is null then
    if p_items is not null and pg_catalog.jsonb_array_length(p_items) > 0 then
      raise exception using errcode = '22023', message = 'This document type does not accept line items.';
    end if;
  elsif p_items is not null then
    execute pg_catalog.format(
      'delete from public.%I where organization_id = $1 and %I = $2',
      v_child_table, v_parent_column
    ) using p_organization_id, v_document_id;

    if pg_catalog.jsonb_array_length(p_items) > 0 then
      select
        pg_catalog.string_agg(pg_catalog.format('%I', c), ', ' order by ord),
        pg_catalog.string_agg(pg_catalog.format('x.%I', c), ', ' order by ord)
      into v_child_column_list, v_child_value_list
      from pg_catalog.unnest(v_child_columns) with ordinality as cols(c, ord);

      v_sql := pg_catalog.format(
        'insert into public.%I (id, organization_id, %I, %s) ' ||
        'select pg_catalog.gen_random_uuid(), $1, $2, %s ' ||
        'from pg_catalog.jsonb_populate_recordset(null::public.%I, $3) as x',
        v_child_table, v_parent_column, v_child_column_list, v_child_value_list, v_child_table
      );
      execute v_sql using p_organization_id, v_document_id, p_items;
    end if;
  end if;

  return v_document_id;
end;
$function$;

revoke all on function public.save_draft_transaction_document(uuid, text, jsonb, jsonb, uuid) from public, anon;
grant execute on function public.save_draft_transaction_document(uuid, text, jsonb, jsonb, uuid) to authenticated;


create or replace function public.confirm_transaction_document(
  p_organization_id uuid,
  p_document_type text,
  p_document_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_table text;
  v_permission text;
  v_status text;
  v_count integer;
  v_subtotal numeric(20,4);
  v_total numeric(20,4);
  v_debit numeric(20,4);
  v_credit numeric(20,4);
  v_source_status text;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id) then
    raise exception using errcode = '42501', message = 'An authenticated active organization member is required.';
  end if;

  case p_document_type
    when 'purchase' then v_table := 'purchase'; v_permission := 'purchases.confirm';
    when 'sales' then v_table := 'sales'; v_permission := 'sales.confirm';
    when 'expense' then v_table := 'expenses'; v_permission := 'expenses.confirm';
    when 'payment' then v_table := 'payments'; v_permission := 'payments.confirm';
    when 'purchase_return' then v_table := 'purchase_returns'; v_permission := 'purchases.returns.confirm';
    when 'sales_return' then v_table := 'sales_returns'; v_permission := 'sales.returns.confirm';
    when 'journal_entry' then v_table := 'journal_entries'; v_permission := 'journal_entries.confirm';
    else raise exception using errcode = '22023', message = 'Unsupported transaction document type.';
  end case;

  if not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'You do not have permission to confirm this document.';
  end if;

  execute pg_catalog.format(
    'select status from public.%I where organization_id = $1 and id = $2 for update', v_table
  ) into v_status using p_organization_id, p_document_id;
  if v_status is null then
    raise exception using errcode = '23503', message = 'Document was not found in this organization.';
  end if;
  if v_status <> 'draft' then
    raise exception using errcode = '23514', message = 'Only draft documents can be confirmed.';
  end if;

  if p_document_type = 'purchase' then
    select count(*)::integer, coalesce(sum(pi.line_total), 0)
      into v_count, v_subtotal
    from public.purchase_items pi
    where pi.organization_id = p_organization_id and pi.purchase_id = p_document_id;
    select p.total_amount into v_total from public.purchase p
    where p.organization_id = p_organization_id and p.id = p_document_id;
    if v_count < 1 or v_subtotal <> (select subtotal from public.purchase where organization_id = p_organization_id and id = p_document_id)
       or v_total <> v_subtotal - (select discount_amount from public.purchase where organization_id = p_organization_id and id = p_document_id)
       or v_total <= 0 then
      raise exception using errcode = '23514', message = 'Purchase must have items and consistent positive subtotal, discount, and total before confirmation.';
    end if;

  elsif p_document_type = 'sales' then
    select count(*)::integer, coalesce(sum(si.line_total), 0)
      into v_count, v_subtotal
    from public.sales_items si
    where si.organization_id = p_organization_id and si.sales_id = p_document_id;
    select s.total_amount into v_total from public.sales s
    where s.organization_id = p_organization_id and s.id = p_document_id;
    if v_count < 1 or v_subtotal <> (select subtotal from public.sales where organization_id = p_organization_id and id = p_document_id)
       or v_total <> v_subtotal - (select discount_amount from public.sales where organization_id = p_organization_id and id = p_document_id)
       or v_total <= 0 then
      raise exception using errcode = '23514', message = 'Sales invoice must have items and consistent positive subtotal, discount, and total before confirmation.';
    end if;

  elsif p_document_type = 'expense' then
    if not exists (
      select 1
      from public.expenses e
      join public.expense_categories ec on ec.organization_id = e.organization_id and ec.id = e.expense_category_id
      join public.accounts ea on ea.organization_id = ec.organization_id and ea.id = ec.expense_account_id
      join public.accounts pa on pa.organization_id = e.organization_id and pa.id = e.payable_account_id
      where e.organization_id = p_organization_id and e.id = p_document_id
        and e.amount > 0 and ec.is_active
        and ea.is_active and ea.is_postable and ea.account_type = 'expense'
        and pa.is_active and pa.is_postable and pa.account_type = 'liability'
        and ((e.contact_id is null and not pa.is_control_account)
          or (e.contact_id is not null and pa.is_control_account
            and exists (select 1 from public.contacts c where c.organization_id = e.organization_id and c.id = e.contact_id and c.is_active)))
    ) then
      raise exception using errcode = '23514', message = 'Expense requires an active mapped expense category, a valid liability account, and a valid optional contact.';
    end if;

  elsif p_document_type = 'payment' then
    if not exists (
      select 1 from public.payments p
      join public.accounts cash on cash.organization_id = p.organization_id and cash.id = p.account_id
      where p.organization_id = p_organization_id and p.id = p_document_id
        and p.amount > 0 and cash.is_active and cash.is_postable
        and cash.account_type = 'asset' and not cash.is_control_account
        and (
          (p.payment_type = 'transfer' and p.contact_id is null
            and p.settlement_account_id is not null and p.settlement_account_id <> p.account_id
            and exists (select 1 from public.accounts dest where dest.organization_id = p.organization_id
              and dest.id = p.settlement_account_id and dest.is_active and dest.is_postable
              and dest.account_type = 'asset' and not dest.is_control_account))
          or
          (p.payment_type in ('receipt','payment','refund') and p.contact_id is not null
            and exists (select 1 from public.contacts c where c.organization_id = p.organization_id
              and c.id = p.contact_id and c.is_active)
            and exists (select 1 from public.accounts ctl where ctl.organization_id = p.organization_id
              and ctl.id = p.settlement_account_id and ctl.is_active and ctl.is_postable
              and ctl.is_control_account
              and ((p.payment_type = 'receipt' and ctl.account_type = 'asset')
                or (p.payment_type = 'payment' and ctl.account_type = 'liability')
                or (p.payment_type = 'refund' and ctl.account_type in ('asset','liability')))))
        )
    ) then
      raise exception using errcode = '23514', message = 'Payment requires valid cash/bank, settlement account, contact, and payment-type configuration.';
    end if;
    perform public.validate_payment_allocations(p_organization_id,p_document_id);

  elsif p_document_type = 'purchase_return' then
    select count(*)::integer, coalesce(sum(ri.line_total),0)
      into v_count, v_subtotal
    from public.purchase_return_items ri
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_document_id;
    select pr.total_amount into v_total from public.purchase_returns pr
    where pr.organization_id = p_organization_id and pr.id = p_document_id;
    if v_count < 1 or v_subtotal <> (select subtotal from public.purchase_returns where organization_id = p_organization_id and id = p_document_id)
       or v_total <> v_subtotal - (select discount_amount from public.purchase_returns where organization_id = p_organization_id and id = p_document_id)
       or v_total <= 0 then
      raise exception using errcode = '23514', message = 'Purchase return must have items and consistent positive subtotal, discount, and total.';
    end if;
    select p.status into v_source_status
    from public.purchase_returns pr join public.purchase p
      on p.organization_id = pr.organization_id and p.id = pr.purchase_id
    where pr.organization_id = p_organization_id and pr.id = p_document_id
      and pr.supplier_id = p.supplier_id and pr.payable_account_id = p.payable_account_id;
    if v_source_status is null or v_source_status not in ('posted','partially_returned') then
      raise exception using errcode = '23514', message = 'Purchase return must reference a posted, not-fully-returned purchase with matching supplier and payable account.';
    end if;
    if exists (
      select 1
      from public.purchase_return_items ri
      join public.purchase_items pi on pi.organization_id = ri.organization_id and pi.id = ri.purchase_item_id
      where ri.organization_id = p_organization_id and ri.purchase_return_id = p_document_id
        and (pi.purchase_id <> (select purchase_id from public.purchase_returns where organization_id = p_organization_id and id = p_document_id)
          or pi.product_id <> ri.product_id or pi.unit_cost <> ri.unit_cost
          or ri.line_total <> round(ri.quantity * ri.unit_cost,4)
          or ri.quantity + coalesce((
            select sum(pri.quantity)
            from public.purchase_return_items pri
            join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
            where pri.organization_id = p_organization_id and pri.purchase_item_id = ri.purchase_item_id and pr.status = 'posted'
          ),0) > pi.quantity)
    ) then
      raise exception using errcode = '23514', message = 'Purchase return lines must match original items and cannot exceed remaining purchased quantities.';
    end if;
  if exists (
    select 1
    from public.purchase_return_items ri
    join public.purchase_items pi on pi.organization_id = ri.organization_id and pi.id = ri.purchase_item_id
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_document_id
    group by ri.purchase_item_id, pi.quantity
    having sum(ri.quantity) + coalesce((
      select sum(pri.quantity)
      from public.purchase_return_items pri
      join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
      where pri.organization_id = p_organization_id and pri.purchase_item_id = ri.purchase_item_id and pr.status = 'posted'
    ),0) > pi.quantity
  ) then
    raise exception using errcode = '23514', message = 'Combined return lines cannot exceed the remaining quantity of an original purchase item.';
  end if;



  elsif p_document_type = 'sales_return' then
    select count(*)::integer, coalesce(sum(ri.line_total),0)
      into v_count, v_subtotal
    from public.sales_return_items ri
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_document_id;
    select sr.total_amount into v_total from public.sales_returns sr
    where sr.organization_id = p_organization_id and sr.id = p_document_id;
    if v_count < 1 or v_subtotal <> (select subtotal from public.sales_returns where organization_id = p_organization_id and id = p_document_id)
       or v_total <> v_subtotal - (select discount_amount from public.sales_returns where organization_id = p_organization_id and id = p_document_id)
       or v_total <= 0 then
      raise exception using errcode = '23514', message = 'Sales return must have items and consistent positive subtotal, discount, and total.';
    end if;
    select s.status into v_source_status
    from public.sales_returns sr join public.sales s
      on s.organization_id = sr.organization_id and s.id = sr.sales_id
    where sr.organization_id = p_organization_id and sr.id = p_document_id
      and sr.customer_id = s.customer_id and sr.receivable_account_id = s.receivable_account_id;
    if v_source_status is null or v_source_status not in ('posted','partially_returned') then
      raise exception using errcode = '23514', message = 'Sales return must reference a posted, not-fully-returned invoice with matching customer and receivable account.';
    end if;
    if v_total > coalesce((
      select round(sum(ri.line_total * s.total_amount / nullif(s.subtotal, 0)), 4)
      from public.sales_return_items ri
      join public.sales_returns sr on sr.organization_id = ri.organization_id and sr.id = ri.sales_return_id
      join public.sales s on s.organization_id = sr.organization_id and s.id = sr.sales_id
      where ri.organization_id = p_organization_id and ri.sales_return_id = p_document_id
        and s.subtotal > 0
    ), 0) then
      raise exception using errcode = '23514',
        message = 'Sales return total cannot exceed the original net value of the returned lines after allocating the invoice discount.';
    end if;
    if exists (
      select 1
      from public.sales_return_items ri
      join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
      where ri.organization_id = p_organization_id and ri.sales_return_id = p_document_id
        and (si.sales_id <> (select sales_id from public.sales_returns where organization_id = p_organization_id and id = p_document_id)
          or si.product_id <> ri.product_id or si.unit_price <> ri.unit_price
          or ri.line_total <> round(ri.quantity * ri.unit_price,4)
          or ri.quantity + coalesce((
            select sum(sri.quantity)
            from public.sales_return_items sri
            join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
            where sri.organization_id = p_organization_id and sri.sales_item_id = ri.sales_item_id and sr.status = 'posted'
          ),0) > si.quantity)
    ) then
      raise exception using errcode = '23514', message = 'Sales return lines must match original items and cannot exceed remaining sold quantities.';
    end if;
  if exists (
    select 1
    from public.sales_return_items ri
    join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_document_id
    group by ri.sales_item_id, si.quantity
    having sum(ri.quantity) + coalesce((
      select sum(sri.quantity)
      from public.sales_return_items sri
      join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
      where sri.organization_id = p_organization_id and sri.sales_item_id = ri.sales_item_id and sr.status = 'posted'
    ),0) > si.quantity
  ) then
    raise exception using errcode = '23514', message = 'Combined return lines cannot exceed the remaining quantity of an original sales item.';
  end if;



  elsif p_document_type = 'journal_entry' then
    select count(*)::integer, coalesce(sum(debit), 0), coalesce(sum(credit), 0)
      into v_count, v_debit, v_credit
    from public.account_transactions
    where organization_id = p_organization_id and journal_entry_id = p_document_id;
    if v_count < 2 or v_debit <= 0 or v_debit <> v_credit then
      raise exception using errcode = '23514', message = 'Journal entry must have at least two lines and balanced debits and credits before confirmation.';
    end if;
  end if;

  execute pg_catalog.format(
    'update public.%I set status = ''confirmed'', confirmed_at = pg_catalog.now(), confirmed_by = $3, updated_at = pg_catalog.now() where organization_id = $1 and id = $2',
    v_table
  ) using p_organization_id, p_document_id, v_user_id;
end;
$function$;


create or replace function public.revert_transaction_document_to_draft(
  p_organization_id uuid,
  p_document_type text,
  p_document_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_table text;
  v_permission text;
  v_status text;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id) then
    raise exception using errcode = '42501', message = 'An authenticated active organization member is required.';
  end if;
  case p_document_type
    when 'purchase' then v_table := 'purchase'; v_permission := 'purchases.confirm';
    when 'sales' then v_table := 'sales'; v_permission := 'sales.confirm';
    when 'expense' then v_table := 'expenses'; v_permission := 'expenses.confirm';
    when 'payment' then v_table := 'payments'; v_permission := 'payments.confirm';
    when 'purchase_return' then v_table := 'purchase_returns'; v_permission := 'purchases.returns.confirm';
    when 'sales_return' then v_table := 'sales_returns'; v_permission := 'sales.returns.confirm';
    when 'journal_entry' then v_table := 'journal_entries'; v_permission := 'journal_entries.confirm';
    else raise exception using errcode = '22023', message = 'Unsupported transaction document type.';
  end case;
  if not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'You do not have permission to revert this document.';
  end if;
  execute pg_catalog.format(
    'select status from public.%I where organization_id = $1 and id = $2 for update', v_table
  ) into v_status using p_organization_id, p_document_id;
  if v_status is null then
    raise exception using errcode = '23503', message = 'Document was not found in this organization.';
  end if;
  if v_status <> 'confirmed' then
    raise exception using errcode = '23514', message = 'Only confirmed documents can be reverted to draft.';
  end if;
  execute pg_catalog.format(
    'update public.%I set status = ''draft'', updated_at = pg_catalog.now() where organization_id = $1 and id = $2',
    v_table
  ) using p_organization_id, p_document_id;
end;
$function$;

create or replace function public.void_transaction_document(
  p_organization_id uuid,
  p_document_type text,
  p_document_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_table text;
  v_permission text;
  v_status text;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id) then
    raise exception using errcode = '42501', message = 'An authenticated active organization member is required.';
  end if;
  if p_reason is null or pg_catalog.length(pg_catalog.btrim(p_reason)) < 3 then
    raise exception using errcode = '22023', message = 'A cancellation reason of at least three characters is required.';
  end if;
  case p_document_type
    when 'purchase' then v_table := 'purchase'; v_permission := 'purchases.confirm';
    when 'sales' then v_table := 'sales'; v_permission := 'sales.confirm';
    when 'expense' then v_table := 'expenses'; v_permission := 'expenses.confirm';
    when 'payment' then v_table := 'payments'; v_permission := 'payments.confirm';
    when 'purchase_return' then v_table := 'purchase_returns'; v_permission := 'purchases.returns.confirm';
    when 'sales_return' then v_table := 'sales_returns'; v_permission := 'sales.returns.confirm';
    when 'journal_entry' then v_table := 'journal_entries'; v_permission := 'journal_entries.confirm';
    else raise exception using errcode = '22023', message = 'Unsupported transaction document type.';
  end case;
  if not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'You do not have permission to cancel this document.';
  end if;
  execute pg_catalog.format(
    'select status from public.%I where organization_id = $1 and id = $2 for update', v_table
  ) into v_status using p_organization_id, p_document_id;
  if v_status is null then
    raise exception using errcode = '23503', message = 'Document was not found in this organization.';
  end if;
  if v_status not in ('draft', 'confirmed') then
    raise exception using errcode = '23514', message = 'Only draft or confirmed documents can be cancelled; posted documents require a reversal or return.';
  end if;
  execute pg_catalog.format(
    'update public.%I set status = ''void'', voided_at = pg_catalog.now(), voided_by = $3, void_reason = pg_catalog.btrim($4), updated_at = pg_catalog.now() where organization_id = $1 and id = $2',
    v_table
  ) using p_organization_id, p_document_id, v_user_id, p_reason;
end;
$function$;

create or replace function public.delete_draft_transaction_document(
  p_organization_id uuid,
  p_document_type text,
  p_document_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_table text;
  v_permission text;
  v_status text;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id) then
    raise exception using errcode = '42501', message = 'An authenticated active organization member is required.';
  end if;
  case p_document_type
    when 'purchase' then v_table := 'purchase'; v_permission := 'purchases.create';
    when 'sales' then v_table := 'sales'; v_permission := 'sales.create';
    when 'expense' then v_table := 'expenses'; v_permission := 'expenses.manage';
    when 'payment' then v_table := 'payments'; v_permission := 'payments.manage';
    when 'purchase_return' then v_table := 'purchase_returns'; v_permission := 'purchases.returns.create';
    when 'sales_return' then v_table := 'sales_returns'; v_permission := 'sales.returns.create';
    when 'journal_entry' then v_table := 'journal_entries'; v_permission := 'journal_entries.create';
    else raise exception using errcode = '22023', message = 'Unsupported transaction document type.';
  end case;
  if not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'You do not have permission to delete this draft document.';
  end if;
  execute pg_catalog.format(
    'select status from public.%I where organization_id = $1 and id = $2 for update', v_table
  ) into v_status using p_organization_id, p_document_id;
  if v_status is null then
    raise exception using errcode = '23503', message = 'Document was not found in this organization.';
  end if;
  if v_status <> 'draft' then
    raise exception using errcode = '23514', message = 'Only draft documents can be deleted; confirmed documents must first be reverted to draft.';
  end if;

  if p_document_type in ('purchase', 'purchase_return', 'sales', 'sales_return', 'expense')
     and exists (
       select 1 from public.payment_allocations pa
       where pa.organization_id = p_organization_id
         and pa.document_type = p_document_type
         and pa.document_id = p_document_id
     ) then
    raise exception using errcode = '23514',
      message = 'This draft document has payment allocations; remove or reassign those allocations before deleting it.';
  end if;

  case p_document_type
    when 'purchase' then
      delete from public.purchase_items where organization_id = p_organization_id and purchase_id = p_document_id;
    when 'sales' then
      delete from public.sales_items where organization_id = p_organization_id and sales_id = p_document_id;
    when 'purchase_return' then
      delete from public.purchase_return_items where organization_id = p_organization_id and purchase_return_id = p_document_id;
    when 'sales_return' then
      delete from public.sales_return_items where organization_id = p_organization_id and sales_return_id = p_document_id;
    when 'payment' then
      delete from public.payment_allocations where organization_id = p_organization_id and payment_id = p_document_id;
    when 'journal_entry' then
      delete from public.account_transactions where organization_id = p_organization_id and journal_entry_id = p_document_id;
    else null;
  end case;

  execute pg_catalog.format(
    'delete from public.%I where organization_id = $1 and id = $2', v_table
  ) using p_organization_id, p_document_id;
end;
$function$;

revoke all on function public.confirm_transaction_document(uuid, text, uuid) from public, anon;
revoke all on function public.revert_transaction_document_to_draft(uuid, text, uuid) from public, anon;
revoke all on function public.void_transaction_document(uuid, text, uuid, text) from public, anon;
revoke all on function public.delete_draft_transaction_document(uuid, text, uuid) from public, anon;
grant execute on function public.confirm_transaction_document(uuid, text, uuid) to authenticated;
grant execute on function public.revert_transaction_document_to_draft(uuid, text, uuid) to authenticated;
grant execute on function public.void_transaction_document(uuid, text, uuid, text) to authenticated;
grant execute on function public.delete_draft_transaction_document(uuid, text, uuid) to authenticated;



-- ============================================================================
-- OPERATIONAL ERP COMPLETION: DEFAULT COA, MASTER DATA, RBAC, PROFILE, NUMBERING
-- ============================================================================

create or replace function public.seed_default_chart_of_accounts(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v record;
  v_parent_id uuid;
begin
  if not exists (select 1 from public.organizations o where o.id = p_organization_id) then
    raise exception using errcode = '23503', message = 'Organization was not found.';
  end if;

  for v in
    select *
    from (values
      ('1000','Assets','asset',null::text,'debit',false,false,10),
      ('1100','Current Assets','asset','1000','debit',false,false,20),
      ('1110','Cash and Bank','asset','1100','debit',false,true,30),
      ('1120','Accounts Receivable','asset','1100','debit',true,true,40),
      ('1130','Inventory','asset','1100','debit',false,true,50),
      ('1140','Other Current Assets','asset','1100','debit',false,true,60),
      ('2000','Liabilities','liability',null::text,'credit',false,false,70),
      ('2100','Current Liabilities','liability','2000','credit',false,false,80),
      ('2110','Accounts Payable','liability','2100','credit',true,true,90),
      ('3000','Equity','equity',null::text,'credit',false,false,100),
      ('3100','Owner Capital','equity','3000','credit',false,true,110),
      ('3200','Retained Earnings','equity','3000','credit',false,true,120),
      ('3300','Opening Balance Equity','equity','3000','credit',false,true,130),
      ('4000','Revenue','revenue',null::text,'credit',false,false,140),
      ('4100','Sales Revenue','revenue','4000','credit',false,true,150),
      ('4200','Purchase Return Gain','revenue','4000','credit',false,true,160),
      ('4300','Inventory Adjustment Gain','revenue','4000','credit',false,true,170),
      ('5000','Expenses','expense',null::text,'debit',false,false,180),
      ('5100','Cost of Goods Sold','expense','5000','debit',false,true,190),
      ('5200','Purchase Return Loss','expense','5000','debit',false,true,200),
      ('5300','Inventory Adjustment Loss','expense','5000','debit',false,true,210),
      ('5400','General Expenses','expense','5000','debit',false,true,220)
    ) as coa(code, name, account_type, parent_code, normal_balance, is_control, is_postable, sort_order)
    order by sort_order
  loop
    v_parent_id := null;
    if v.parent_code is not null then
      select a.id into v_parent_id
      from public.accounts a
      where a.organization_id = p_organization_id
        and a.account_code = v.parent_code;
      if v_parent_id is null then
        raise exception using errcode = '23514',
          message = pg_catalog.format('Default chart parent %s is missing.', v.parent_code);
      end if;
    end if;

    insert into public.accounts (
      organization_id, account_code, account_name, account_type,
      parent_account_id, normal_balance, is_control_account,
      is_system_account, is_postable, is_active
    )
    values (
      p_organization_id, v.code, v.name, v.account_type,
      v_parent_id, v.normal_balance, v.is_control, true, v.is_postable, true
    )
    on conflict (organization_id, account_code) do nothing;
  end loop;

  insert into public.expense_categories (
    organization_id, category_code, name, expense_account_id, is_active
  )
  select p_organization_id, 'GEN', 'General Expenses', a.id, true
  from public.accounts a
  where a.organization_id = p_organization_id and a.account_code = '5400'
  on conflict (organization_id, category_code) do nothing;

  insert into public.number_sequences (
    organization_id, document_type, prefix, next_number, padding, is_active
  )
  values
    (p_organization_id, 'purchase', 'PUR-', 1, 5, true),
    (p_organization_id, 'sale', 'SAL-', 1, 5, true),
    (p_organization_id, 'expense', 'EXP-', 1, 5, true),
    (p_organization_id, 'payment', 'PAY-', 1, 5, true),
    (p_organization_id, 'journal_entry', 'JRN-', 1, 5, true),
    (p_organization_id, 'purchase_return', 'PR-', 1, 5, true),
    (p_organization_id, 'sales_return', 'SR-', 1, 5, true),
    (p_organization_id, 'inventory_adjustment', 'IA-', 1, 5, true)
  on conflict (organization_id, document_type) do nothing;
end;
$function$;
revoke all on function public.seed_default_chart_of_accounts(uuid) from public, anon, authenticated;

create or replace function public.create_organization_with_admin(
  p_name text,
  p_currency text default 'BDT',
  p_timezone text default 'Asia/Dhaka'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_organization_id uuid;
  v_role_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication is required to create an organization.';
  end if;
  if p_name is null or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'Organization name must contain between 1 and 160 characters.';
  end if;
  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    raise exception using errcode = '22023', message = 'Currency must be a three-letter uppercase ISO currency code.';
  end if;
  if p_timezone is null or not exists (
    select 1 from pg_catalog.pg_timezone_names tz where tz.name = pg_catalog.btrim(p_timezone)
  ) then
    raise exception using errcode = '22023', message = 'Timezone must be a valid PostgreSQL timezone name.';
  end if;

  insert into public.organizations (name, currency, timezone)
  values (pg_catalog.btrim(p_name), p_currency, pg_catalog.btrim(p_timezone))
  returning id into v_organization_id;

  insert into public.roles (organization_id, name, status, is_system_role)
  values (v_organization_id, 'Administrator', 'active', true)
  returning id into v_role_id;

  insert into public.role_permissions (role_id, permission_id)
  select v_role_id, p.id from public.permissions p
  on conflict (role_id, permission_id) do nothing;

  insert into public.organization_users (organization_id, user_id, role_id, is_active)
  values (v_organization_id, v_user_id, v_role_id, true);

  perform public.seed_default_chart_of_accounts(v_organization_id);
  return v_organization_id;
end;
$function$;
revoke all on function public.create_organization_with_admin(text,text,text) from public, anon;
grant execute on function public.create_organization_with_admin(text,text,text) to authenticated;

create or replace function public.next_document_number(
  p_organization_id uuid,
  p_document_type text
)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_permission text;
  v_prefix text;
  v_number bigint;
  v_padding smallint;
begin
  v_permission := case p_document_type
    when 'purchase' then 'purchases.create'
    when 'sale' then 'sales.create'
    when 'expense' then 'expenses.manage'
    when 'payment' then 'payments.manage'
    when 'journal_entry' then 'journal_entries.create'
    when 'purchase_return' then 'purchases.returns.create'
    when 'sales_return' then 'sales.returns.create'
    when 'inventory_adjustment' then 'inventory.adjust'
    else null
  end;
  if (select auth.uid()) is null or v_permission is null
     or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'Not authorized to allocate this document number.';
  end if;

  insert into public.number_sequences(organization_id, document_type, prefix, next_number, padding)
  values (p_organization_id, p_document_type, upper(left(p_document_type, 3)) || '-', 2, 5)
  on conflict (organization_id, document_type) do update
    set next_number = public.number_sequences.next_number + 1,
        updated_at = pg_catalog.now()
    where public.number_sequences.is_active
  returning prefix, next_number - 1, padding into v_prefix, v_number, v_padding;

  if not found then
    raise exception using errcode = '55000',
      message = 'Document numbering is disabled for this document type in this organization.';
  end if;
  return v_prefix || lpad(v_number::text, v_padding, '0');
end;
$function$;
revoke all on function public.next_document_number(uuid,text) from public, anon;
grant execute on function public.next_document_number(uuid,text) to authenticated;

-- Document numbers are generated by PostgreSQL and cannot be client-selected or edited.
create or replace function public.assign_document_number()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_type text;
begin
  if tg_op = 'UPDATE' then
    if tg_table_name = 'purchase' then new.invoice_id := old.invoice_id;
    elsif tg_table_name = 'sales' then new.invoice_id := old.invoice_id;
    elsif tg_table_name = 'expenses' then new.expense_number := old.expense_number;
    elsif tg_table_name = 'payments' then new.payment_number := old.payment_number;
    elsif tg_table_name = 'purchase_returns' then new.return_number := old.return_number;
    elsif tg_table_name = 'sales_returns' then new.return_number := old.return_number;
    elsif tg_table_name = 'journal_entries' then new.entry_number := old.entry_number;
    end if;
    return new;
  end if;

  if new.status <> 'draft' then return new; end if;
  if tg_table_name = 'purchase' then v_type := 'purchase'; new.invoice_id := public.next_document_number(new.organization_id, v_type);
  elsif tg_table_name = 'sales' then v_type := 'sale'; new.invoice_id := public.next_document_number(new.organization_id, v_type);
  elsif tg_table_name = 'expenses' then v_type := 'expense'; new.expense_number := public.next_document_number(new.organization_id, v_type);
  elsif tg_table_name = 'payments' then v_type := 'payment'; new.payment_number := public.next_document_number(new.organization_id, v_type);
  elsif tg_table_name = 'purchase_returns' then v_type := 'purchase_return'; new.return_number := public.next_document_number(new.organization_id, v_type);
  elsif tg_table_name = 'sales_returns' then v_type := 'sales_return'; new.return_number := public.next_document_number(new.organization_id, v_type);
  elsif tg_table_name = 'journal_entries' and new.entry_type = 'manual' then v_type := 'journal_entry'; new.entry_number := public.next_document_number(new.organization_id, v_type);
  end if;
  return new;
end;
$function$;
revoke all on function public.assign_document_number() from public, anon, authenticated;

create trigger purchase_assign_document_number before insert or update of invoice_id on public.purchase
for each row execute function public.assign_document_number();
create trigger sales_assign_document_number before insert or update of invoice_id on public.sales
for each row execute function public.assign_document_number();
create trigger expenses_assign_document_number before insert or update of expense_number on public.expenses
for each row execute function public.assign_document_number();
create trigger payments_assign_document_number before insert or update of payment_number on public.payments
for each row execute function public.assign_document_number();
create trigger purchase_returns_assign_document_number before insert or update of return_number on public.purchase_returns
for each row execute function public.assign_document_number();
create trigger sales_returns_assign_document_number before insert or update of return_number on public.sales_returns
for each row execute function public.assign_document_number();
create trigger journal_entries_assign_document_number before insert or update of entry_number on public.journal_entries
for each row execute function public.assign_document_number();

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
     or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'organization.update') then
    raise exception using errcode = '42501', message = 'Not authorized to update this organization.';
  end if;
  if p_name is null or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 160
     or p_currency is null or p_currency !~ '^[A-Z]{3}$' or p_timezone is null or not exists (
       select 1 from pg_catalog.pg_timezone_names tz where tz.name = pg_catalog.btrim(p_timezone)
     ) then
    raise exception using errcode = '22023', message = 'Organization name, ISO currency, or timezone is invalid.';
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
    raise exception using errcode = '23503', message = 'Active organization was not found.';
  end if;
end;
$function$;
revoke all on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) to authenticated;

create or replace function public.save_master_data(
  p_organization_id uuid,
  p_entity_type text,
  p_data jsonb,
  p_record_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_table text;
  v_permission text;
  v_allowed text[];
  v_key text;
  v_columns text;
  v_values text;
  v_set_clause text;
  v_id uuid := coalesce(p_record_id, pg_catalog.gen_random_uuid());
  v_has_created_by boolean := false;
  v_system boolean;
  v_current_is_control boolean;
  v_has_activity boolean;
  v_default_id uuid;
  v_parent_type text;
  v_parent_balance text;
  v_current_account_type text;
  v_current_normal_balance text;
  v_parent_postable boolean;
  v_inventory_account_id uuid;
  v_sales_account_id uuid;
  v_cogs_account_id uuid;
  v_unit_id uuid;
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id) then
    raise exception using errcode = '42501', message = 'An authenticated active organization member is required.';
  end if;
  if p_data is null or pg_catalog.jsonb_typeof(p_data) <> 'object' or p_data = '{}'::jsonb then
    raise exception using errcode = '22023', message = 'Master-data fields must be a non-empty JSON object.';
  end if;

  case p_entity_type
    when 'account' then
      v_table := 'accounts'; v_permission := 'accounts.manage';
      v_allowed := array['account_code','account_name','account_type','parent_account_id','normal_balance','is_control_account','is_postable','is_active'];
    when 'unit' then
      v_table := 'units_of_measure'; v_permission := 'products.manage';
      v_allowed := array['name','is_active'];
    when 'contact' then
      v_table := 'contacts'; v_permission := 'contacts.manage'; v_has_created_by := true;
      v_allowed := array['contact_number','name','phone','email','address','is_active'];
    when 'product' then
      v_table := 'products'; v_permission := 'products.manage'; v_has_created_by := true;
      v_allowed := array['product_code','name','unit_id','inventory_account_id','sales_account_id','cogs_account_id','is_active'];
    when 'expense_category' then
      v_table := 'expense_categories'; v_permission := 'expenses.manage';
      v_allowed := array['category_code','name','expense_account_id','is_active'];
    else
      raise exception using errcode = '22023', message = 'Unsupported master-data entity type.';
  end case;

  if not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'You do not have permission to manage this master-data entity.';
  end if;
  -- Serialize master-data changes against transaction posting, which takes FOR SHARE on the organization row.
  perform 1 from public.organizations o where o.id=p_organization_id and o.is_active for update;
  if not found then raise exception using errcode='23503',message='Active organization was not found.'; end if;
  for v_key in select pg_catalog.jsonb_object_keys(p_data) loop
    if not (v_key = any(v_allowed)) then
      raise exception using errcode = '22023',
        message = pg_catalog.format('Field %s is not editable for %s.', v_key, p_entity_type);
    end if;
  end loop;

  if p_entity_type = 'account' then
    if p_data ? 'account_type' or p_data ? 'normal_balance' then
      if p_data->>'account_type' is not null and
         p_data->>'normal_balance' is distinct from
           (case p_data->>'account_type'
             when 'asset' then 'debit' when 'expense' then 'debit'
             when 'liability' then 'credit' when 'equity' then 'credit'
             when 'revenue' then 'credit' else null end) then
        raise exception using errcode='22023',message='Normal balance must match the account type.';
      end if;
      if p_data->>'account_type' is not null and p_data->>'normal_balance' is null
         and (p_record_id is null or p_data->>'account_type' is distinct from v_current_account_type) then
        raise exception using errcode='22023',message='Changing account type requires a matching normal balance.';
      end if;
    end if;
    if p_record_id is not null then
      select a.is_system_account,a.account_type,a.normal_balance,a.is_control_account
      into v_system,v_current_account_type,v_current_normal_balance,v_current_is_control
      from public.accounts a
      where a.organization_id=p_organization_id and a.id=p_record_id
      for update;
      if not found then raise exception using errcode='23503',message='Account was not found in this organization.'; end if;
      if v_system and (p_data ? 'account_code' or p_data ? 'account_type' or p_data ? 'normal_balance'
        or p_data ? 'is_control_account' or p_data ? 'is_postable' or p_data ? 'is_active'
        or p_data ? 'parent_account_id') then
        raise exception using errcode='42501',message='System chart accounts cannot be reclassified, moved, or deactivated.';
      end if;
      if p_data ? 'account_type' and (p_data->>'account_type') is distinct from v_current_account_type
         and p_data->>'normal_balance' is null then
        raise exception using errcode='22023',message='Changing account type requires a matching normal balance.';
      end if;
      if p_data ? 'normal_balance' and (p_data->>'normal_balance') is distinct from v_current_normal_balance
         and not p_data ? 'account_type' then
        if (p_data->>'normal_balance') is distinct from
          (case v_current_account_type when 'asset' then 'debit' when 'expense' then 'debit'
            when 'liability' then 'credit' when 'equity' then 'credit'
            when 'revenue' then 'credit' else null end) then
          raise exception using errcode='22023',message='Normal balance must match the account type.';
        end if;
      end if;
      if exists (select 1 from public.account_transactions atx
        where atx.organization_id=p_organization_id and atx.account_id=p_record_id)
        and (p_data ? 'account_code' or p_data ? 'account_type' or p_data ? 'normal_balance'
          or p_data ? 'is_control_account' or p_data ? 'is_postable' or p_data ? 'parent_account_id') then
        raise exception using errcode='23514',message='An account used by ledger entries cannot be re-coded or structurally reclassified.';
      end if;
      if p_data->>'is_active'='false' and (
        exists(select 1 from public.account_transactions atx where atx.organization_id=p_organization_id and atx.account_id=p_record_id)
        or exists(select 1 from public.products pr where pr.organization_id=p_organization_id and p_record_id in (pr.inventory_account_id,pr.sales_account_id,pr.cogs_account_id) and pr.is_active)
        or exists(select 1 from public.expense_categories ec where ec.organization_id=p_organization_id and ec.expense_account_id=p_record_id and ec.is_active)
        or exists(select 1 from public.accounts child where child.organization_id=p_organization_id and child.parent_account_id=p_record_id)
      ) then
        raise exception using errcode='23514',message='An account with ledger activity, active mappings, or child accounts cannot be deactivated.';
      end if;
    end if;
    if coalesce((p_data->>'is_control_account')::boolean,v_current_is_control,false)
       and coalesce(p_data->>'account_type',v_current_account_type) not in ('asset','liability') then
      raise exception using errcode='23514',message='Only asset or liability accounts can be control accounts.';
    end if;
    if p_data ? 'parent_account_id' and p_data->>'parent_account_id' is not null then
      select a.account_type,a.normal_balance,a.is_postable
      into v_parent_type,v_parent_balance,v_parent_postable
      from public.accounts a
      where a.organization_id=p_organization_id and a.id=(p_data->>'parent_account_id')::uuid;
      if not found then raise exception using errcode='23503',message='Parent account must belong to this organization.'; end if;
      if v_parent_postable then
        raise exception using errcode='23514',message='A postable account cannot be used as a parent account.';
      end if;
      if coalesce(p_data->>'account_type',v_current_account_type) is distinct from v_parent_type then
        raise exception using errcode='23514',message='Parent and child accounts must have the same account type.';
      end if;
    end if;
  elsif p_entity_type = 'product' then
    if p_record_id is null then
      if not (p_data ? 'unit_id') then
        raise exception using errcode='22023',message='A unit of measure is required for a new product.';
      end if;
      v_inventory_account_id := (select id from public.accounts where organization_id=p_organization_id and account_code='1130');
      v_sales_account_id := (select id from public.accounts where organization_id=p_organization_id and account_code='4100');
      v_cogs_account_id := (select id from public.accounts where organization_id=p_organization_id and account_code='5100');
      p_data := p_data || pg_catalog.jsonb_build_object(
        'inventory_account_id',coalesce((p_data->>'inventory_account_id')::uuid,v_inventory_account_id),
        'sales_account_id',coalesce((p_data->>'sales_account_id')::uuid,v_sales_account_id),
        'cogs_account_id',coalesce((p_data->>'cogs_account_id')::uuid,v_cogs_account_id)
      );
      v_unit_id := (p_data->>'unit_id')::uuid;
    else
      select pr.unit_id,pr.inventory_account_id,pr.sales_account_id,pr.cogs_account_id
      into v_unit_id,v_inventory_account_id,v_sales_account_id,v_cogs_account_id
      from public.products pr
      where pr.organization_id=p_organization_id and pr.id=p_record_id
      for update;
      if not found then raise exception using errcode='23503',message='Product was not found in this organization.'; end if;
      if p_data ? 'unit_id' then v_unit_id := (p_data->>'unit_id')::uuid; end if;
      if p_data ? 'inventory_account_id' then v_inventory_account_id := (p_data->>'inventory_account_id')::uuid; end if;
      if p_data ? 'sales_account_id' then v_sales_account_id := (p_data->>'sales_account_id')::uuid; end if;
      if p_data ? 'cogs_account_id' then v_cogs_account_id := (p_data->>'cogs_account_id')::uuid; end if;
      if exists (
        select 1 from public.inventory_transactions it
        where it.organization_id=p_organization_id and it.product_id=p_record_id
      ) and ((p_data ? 'inventory_account_id' and v_inventory_account_id is distinct from
          (select inventory_account_id from public.products where organization_id=p_organization_id and id=p_record_id))
        or (p_data ? 'sales_account_id' and v_sales_account_id is distinct from
          (select sales_account_id from public.products where organization_id=p_organization_id and id=p_record_id))
        or (p_data ? 'cogs_account_id' and v_cogs_account_id is distinct from
          (select cogs_account_id from public.products where organization_id=p_organization_id and id=p_record_id))) then
        raise exception using errcode='23514',message='Product account mappings cannot change after inventory movements exist.';
      end if;
      if p_data->>'is_active'='false' and exists (
        select 1 from public.inventory_balances b
        where b.organization_id=p_organization_id and b.product_id=p_record_id and b.quantity<>0
      ) then
        raise exception using errcode='23514',message='A product with non-zero stock cannot be deactivated.';
      end if;
    end if;
    if not exists(select 1 from public.units_of_measure u where u.organization_id=p_organization_id and u.id=v_unit_id and u.is_active) then
      raise exception using errcode='23514',message='Product unit must be active and belong to this organization.';
    end if;
    if not exists(select 1 from public.accounts a where a.organization_id=p_organization_id and a.id=v_inventory_account_id
      and a.account_type='asset' and a.is_postable and a.is_active)
      or not exists(select 1 from public.accounts a where a.organization_id=p_organization_id and a.id=v_sales_account_id
      and a.account_type='revenue' and a.is_postable and a.is_active)
      or not exists(select 1 from public.accounts a where a.organization_id=p_organization_id and a.id=v_cogs_account_id
      and a.account_type='expense' and a.is_postable and a.is_active) then
      raise exception using errcode='23514',message='Product mappings require active, postable inventory asset, revenue, and COGS expense accounts.';
    end if;
  elsif p_entity_type = 'expense_category' then
    if p_record_id is null then
      if not (p_data ? 'expense_account_id') then
        select id into v_default_id from public.accounts
        where organization_id=p_organization_id and account_code='5400';
        p_data := p_data || pg_catalog.jsonb_build_object('expense_account_id',v_default_id);
      end if;
    end if;
    if p_data ? 'expense_account_id' and not exists (
      select 1 from public.accounts a
      where a.organization_id=p_organization_id and a.id=(p_data->>'expense_account_id')::uuid
        and a.account_type='expense' and a.is_postable and a.is_active
    ) then
      raise exception using errcode='23514',message='Expense category must map to an active, postable expense account.';
    end if;
  end if;

  if p_record_id is not null and p_entity_type='contact' and p_data->>'is_active'='false' then
    if exists (
      select 1 from public.account_transactions atx
      join public.accounts a on a.organization_id=atx.organization_id and a.id=atx.account_id
      join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
      where atx.organization_id=p_organization_id and atx.contact_id=p_record_id
        and a.is_control_account and je.status in ('posted','reversed')
      group by a.id having sum(atx.debit-atx.credit)<>0
    ) then
      raise exception using errcode='23514',message='A contact with an outstanding receivable or payable balance cannot be deactivated.';
    end if;
  elsif p_record_id is not null and p_entity_type='unit' and p_data->>'is_active'='false' then
    if exists(select 1 from public.products pr where pr.organization_id=p_organization_id and pr.unit_id=p_record_id and pr.is_active) then
      raise exception using errcode='23514',message='A unit used by active products cannot be deactivated.';
    end if;
  end if;

  if p_record_id is null then
    select
      pg_catalog.string_agg(pg_catalog.format('%I',k),', ' order by k),
      pg_catalog.string_agg(pg_catalog.format('(pg_catalog.jsonb_populate_record(null::public.%I,$3)).%I',v_table,k),', ' order by k)
    into v_columns,v_values
    from pg_catalog.jsonb_object_keys(p_data) as keys(k);
    if v_has_created_by then
      execute pg_catalog.format(
        'insert into public.%I (id,organization_id,created_by,%s) values ($1,$2,$4,%s)',
        v_table,v_columns,v_values
      ) using v_id,p_organization_id,p_data,(select auth.uid());
    else
      execute pg_catalog.format(
        'insert into public.%I (id,organization_id,%s) values ($1,$2,%s)',
        v_table,v_columns,v_values
      ) using v_id,p_organization_id,p_data;
    end if;
  else
    if v_table = 'products' and not exists (
      select 1 from public.products where organization_id = p_organization_id and id = p_record_id
    ) then raise exception using errcode = '23503', message = 'Product was not found in this organization.'; end if;
    if v_table = 'contacts' and not exists (
      select 1 from public.contacts where organization_id = p_organization_id and id = p_record_id
    ) then raise exception using errcode = '23503', message = 'Contact was not found in this organization.'; end if;
    if v_table = 'units_of_measure' and not exists (
      select 1 from public.units_of_measure where organization_id = p_organization_id and id = p_record_id
    ) then raise exception using errcode = '23503', message = 'Unit was not found in this organization.'; end if;
    if v_table = 'expense_categories' and not exists (
      select 1 from public.expense_categories where organization_id = p_organization_id and id = p_record_id
    ) then raise exception using errcode = '23503', message = 'Expense category was not found in this organization.'; end if;
    if v_table = 'accounts' and not exists (
      select 1 from public.accounts where organization_id = p_organization_id and id = p_record_id
    ) then raise exception using errcode = '23503', message = 'Account was not found in this organization.'; end if;

    select pg_catalog.string_agg(
      pg_catalog.format('%I=(pg_catalog.jsonb_populate_record(null::public.%I,$3)).%I',k,v_table,k),
      ', ' order by k
    ) into v_set_clause
    from pg_catalog.jsonb_object_keys(p_data) as keys(k);
    execute pg_catalog.format('update public.%I set %s where organization_id=$1 and id=$2',v_table,v_set_clause)
      using p_organization_id,p_record_id,p_data;
  end if;
  return v_id;
end;
$function$;
revoke all on function public.save_master_data(uuid,text,jsonb,uuid) from public, anon;
grant execute on function public.save_master_data(uuid,text,jsonb,uuid) to authenticated;

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
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'roles.manage') then
    raise exception using errcode = '42501', message = 'Not authorized to create roles.';
  end if;
  if p_name is null or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 100
     or p_permission_keys is null then
    raise exception using errcode = '22023', message = 'Role name and permission list are required.';
  end if;
  perform 1 from public.organizations o
  where o.id=p_organization_id and o.is_active for update;
  if not found then raise exception using errcode='23503',message='Active organization was not found.'; end if;

  if exists (
    select 1 from unnest(p_permission_keys) as x(permission_key)
    where not public.has_org_permission(p_organization_id,x.permission_key)
  ) then
    raise exception using errcode = '42501', message = 'A custom role cannot receive permissions the current user does not hold.';
  end if;
  insert into public.roles(organization_id,name,status,is_system_role)
  values(p_organization_id,pg_catalog.btrim(p_name),'active',false)
  returning id into v_role_id;
  select count(distinct x.permission_key) into v_requested from unnest(p_permission_keys) as x(permission_key);
  insert into public.role_permissions(role_id,permission_id)
  select v_role_id,p.id from public.permissions p
  where p.permission_key = any(p_permission_keys);
  get diagnostics v_inserted = row_count;
  if v_inserted <> v_requested then
    raise exception using errcode = '22023', message = 'One or more permission keys do not exist.';
  end if;
  return v_role_id;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'A role with this name already exists.';
end;
$function$;

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
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'roles.manage') then
    raise exception using errcode = '42501', message = 'Not authorized to change role permissions.';
  end if;
  if p_permission_keys is null then raise exception using errcode = '22023', message = 'Permission list is required.'; end if;
  perform 1 from public.organizations o
  where o.id=p_organization_id and o.is_active for update;
  if not found then raise exception using errcode='23503',message='Active organization was not found.'; end if;
  select r.is_system_role into v_system
  from public.roles r
  where r.organization_id=p_organization_id and r.id=p_role_id and r.status='active'
  for update;
  if not found then raise exception using errcode = '23503', message = 'Active role was not found.'; end if;
  if v_system then raise exception using errcode = '42501', message = 'System Administrator permissions are immutable.'; end if;
  if exists (select 1 from unnest(p_permission_keys) as x(permission_key) where not public.has_org_permission(p_organization_id,x.permission_key)) then
    raise exception using errcode = '42501', message = 'A custom role cannot receive permissions the current user does not hold.';
  end if;
  select count(distinct x.permission_key) into v_requested from unnest(p_permission_keys) as x(permission_key);
  delete from public.role_permissions where role_id=p_role_id;
  insert into public.role_permissions(role_id,permission_id)
  select p_role_id,p.id from public.permissions p where p.permission_key=any(p_permission_keys);
  get diagnostics v_inserted = row_count;
  if v_inserted <> v_requested then raise exception using errcode = '22023', message = 'One or more permission keys do not exist.'; end if;
end;
$function$;
revoke all on function public.create_custom_role(uuid,text,text[]) from public,anon;
revoke all on function public.replace_custom_role_permissions(uuid,uuid,text[]) from public,anon;
grant execute on function public.create_custom_role(uuid,text,text[]) to authenticated;
grant execute on function public.replace_custom_role_permissions(uuid,uuid,text[]) to authenticated;



-- ============================================================================
-- INVOICE-LEVEL SUBLEDGER ALLOCATIONS
-- ============================================================================

create or replace function public.validate_payment_allocations(
  p_organization_id uuid,
  p_payment_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_payment public.payments%rowtype;
  v_allocation record;
  v_outstanding numeric(20,4);
  v_allocated numeric(20,4);
  v_settlement_type text;
begin
  select * into v_payment
  from public.payments p
  where p.organization_id = p_organization_id and p.id = p_payment_id;
  if not found then raise exception using errcode = '23503', message = 'Payment was not found.'; end if;

  select coalesce(sum(pa.allocated_amount),0) into v_allocated
  from public.payment_allocations pa
  where pa.organization_id = p_organization_id and pa.payment_id = p_payment_id;
  if v_allocated > v_payment.amount then
    raise exception using errcode = '23514', message = 'Invoice allocations cannot exceed the payment amount.';
  end if;

  if v_allocated = 0 then return; end if;
  if v_payment.payment_type = 'transfer' then
    raise exception using errcode = '23514', message = 'Bank transfers cannot be allocated to contact documents.';
  end if;

  select a.account_type into v_settlement_type
  from public.accounts a
  where a.organization_id = p_organization_id and a.id = v_payment.settlement_account_id;
  if v_payment.payment_type = 'refund' and v_settlement_type is distinct from 'asset' and v_settlement_type is distinct from 'liability' then
    raise exception using errcode = '23514', message = 'Refund allocations require an AR or AP control account.';
  end if;

  for v_allocation in
    select pa.document_type, pa.document_id, pa.allocated_amount
    from public.payment_allocations pa
    where pa.organization_id = p_organization_id and pa.payment_id = p_payment_id
    order by pa.document_type, pa.document_id
  loop
    v_outstanding := null;

    if v_allocation.document_type = 'sales' then
      if v_payment.payment_type <> 'receipt' then
        raise exception using errcode = '23514', message = 'Receipts can only be allocated to sales invoices.';
      end if;
      perform 1 from public.sales s
      where s.organization_id = p_organization_id and s.id = v_allocation.document_id
      for update;
      select s.total_amount
        - coalesce((select sum(pa.allocated_amount)
          from public.payment_allocations pa
          join public.payments p on p.organization_id=pa.organization_id and p.id=pa.payment_id
          where pa.organization_id=p_organization_id and pa.document_type='sales'
            and pa.document_id=s.id and p.status='posted' and p.id<>p_payment_id),0)
        - coalesce((select sum(sr.total_amount) from public.sales_returns sr
          where sr.organization_id=p_organization_id and sr.sales_id=s.id and sr.status='posted'),0)
      into v_outstanding
      from public.sales s
      where s.organization_id=p_organization_id and s.id=v_allocation.document_id
        and s.status in ('posted','partially_returned');
      if v_outstanding is null then
        raise exception using errcode = '23503', message = 'Allocated sales invoice must be posted and belong to this organization.';
      end if;
      if (select customer_id from public.sales where organization_id=p_organization_id and id=v_allocation.document_id)
         is distinct from v_payment.contact_id then
        raise exception using errcode = '23514', message = 'Sales invoice customer must match the payment contact.';
      end if;

    elsif v_allocation.document_type = 'purchase' then
      if v_payment.payment_type <> 'payment' then
        raise exception using errcode = '23514', message = 'Supplier payments can only be allocated to purchases.';
      end if;
      perform 1 from public.purchase p
      where p.organization_id=p_organization_id and p.id=v_allocation.document_id
      for update;
      select p.total_amount
        - coalesce((select sum(pa.allocated_amount)
          from public.payment_allocations pa
          join public.payments pm on pm.organization_id=pa.organization_id and pm.id=pa.payment_id
          where pa.organization_id=p_organization_id and pa.document_type='purchase'
            and pa.document_id=p.id and pm.status='posted' and pm.id<>p_payment_id),0)
        - coalesce((select sum(pr.total_amount) from public.purchase_returns pr
          where pr.organization_id=p_organization_id and pr.purchase_id=p.id and pr.status='posted'),0)
      into v_outstanding
      from public.purchase p
      where p.organization_id=p_organization_id and p.id=v_allocation.document_id
        and p.status in ('posted','partially_returned');
      if v_outstanding is null then
        raise exception using errcode = '23503', message = 'Allocated purchase must be posted and belong to this organization.';
      end if;
      if (select supplier_id from public.purchase where organization_id=p_organization_id and id=v_allocation.document_id)
         is distinct from v_payment.contact_id then
        raise exception using errcode = '23514', message = 'Purchase supplier must match the payment contact.';
      end if;

    elsif v_allocation.document_type = 'expense' then
      if v_payment.payment_type <> 'payment' then
        raise exception using errcode = '23514', message = 'Supplier payments can only be allocated to expenses.';
      end if;
      perform 1 from public.expenses e
      where e.organization_id=p_organization_id and e.id=v_allocation.document_id
      for update;
      select e.amount
        - coalesce((select sum(pa.allocated_amount)
          from public.payment_allocations pa
          join public.payments pm on pm.organization_id=pa.organization_id and pm.id=pa.payment_id
          where pa.organization_id=p_organization_id and pa.document_type='expense'
            and pa.document_id=e.id and pm.status='posted' and pm.id<>p_payment_id),0)
      into v_outstanding
      from public.expenses e
      where e.organization_id=p_organization_id and e.id=v_allocation.document_id
        and e.status='posted';
      if v_outstanding is null then
        raise exception using errcode = '23503', message = 'Allocated expense must be posted and belong to this organization.';
      end if;
      if (select contact_id from public.expenses where organization_id=p_organization_id and id=v_allocation.document_id)
         is distinct from v_payment.contact_id then
        raise exception using errcode = '23514', message = 'Expense contact must match the payment contact.';
      end if;

    elsif v_allocation.document_type = 'sales_return' then
      if v_payment.payment_type <> 'refund' or v_settlement_type is distinct from 'asset' then
        raise exception using errcode = '23514', message = 'Customer refunds can only be allocated to sales return credit notes.';
      end if;
      perform 1 from public.sales_returns sr
      where sr.organization_id=p_organization_id and sr.id=v_allocation.document_id
      for update;
      select sr.total_amount
        - coalesce((select sum(pa.allocated_amount)
          from public.payment_allocations pa
          join public.payments pm on pm.organization_id=pa.organization_id and pm.id=pa.payment_id
          where pa.organization_id=p_organization_id and pa.document_type='sales_return'
            and pa.document_id=sr.id and pm.status='posted' and pm.id<>p_payment_id),0)
      into v_outstanding
      from public.sales_returns sr
      where sr.organization_id=p_organization_id and sr.id=v_allocation.document_id
        and sr.status='posted';
      if v_outstanding is null then
        raise exception using errcode = '23503', message = 'Allocated sales return must be posted and belong to this organization.';
      end if;
      if (select customer_id from public.sales_returns where organization_id=p_organization_id and id=v_allocation.document_id)
         is distinct from v_payment.contact_id then
        raise exception using errcode = '23514', message = 'Sales return customer must match the refund contact.';
      end if;

    elsif v_allocation.document_type = 'purchase_return' then
      if v_payment.payment_type <> 'refund' or v_settlement_type is distinct from 'liability' then
        raise exception using errcode = '23514', message = 'Supplier refunds can only be allocated to purchase return credit notes.';
      end if;
      perform 1 from public.purchase_returns pr
      where pr.organization_id=p_organization_id and pr.id=v_allocation.document_id
      for update;
      select pr.total_amount
        - coalesce((select sum(pa.allocated_amount)
          from public.payment_allocations pa
          join public.payments pm on pm.organization_id=pa.organization_id and pm.id=pa.payment_id
          where pa.organization_id=p_organization_id and pa.document_type='purchase_return'
            and pa.document_id=pr.id and pm.status='posted' and pm.id<>p_payment_id),0)
      into v_outstanding
      from public.purchase_returns pr
      where pr.organization_id=p_organization_id and pr.id=v_allocation.document_id
        and pr.status='posted';
      if v_outstanding is null then
        raise exception using errcode = '23503', message = 'Allocated purchase return must be posted and belong to this organization.';
      end if;
      if (select supplier_id from public.purchase_returns where organization_id=p_organization_id and id=v_allocation.document_id)
         is distinct from v_payment.contact_id then
        raise exception using errcode = '23514', message = 'Purchase return supplier must match the refund contact.';
      end if;
    else
      raise exception using errcode = '22023', message = 'Unsupported allocation document type.';
    end if;

    if v_allocation.allocated_amount > v_outstanding or v_outstanding <= 0 then
      raise exception using errcode = '23514',
        message = pg_catalog.format('Allocation %s exceeds the document outstanding balance %s.',
          v_allocation.allocated_amount, v_outstanding);
    end if;
  end loop;
end;
$function$;
revoke all on function public.validate_payment_allocations(uuid,uuid) from public,anon,authenticated;

create or replace function public.set_payment_allocations(
  p_organization_id uuid,
  p_payment_id uuid,
  p_allocations jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_payment public.payments%rowtype;
  v_count integer;
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'payments.manage') then
    raise exception using errcode='42501',message='Not authorized to manage payment allocations.';
  end if;
  if p_allocations is null or pg_catalog.jsonb_typeof(p_allocations)<>'array' then
    raise exception using errcode='22023',message='Allocations must be supplied as a JSON array.';
  end if;
  select * into v_payment from public.payments p
  where p.organization_id=p_organization_id and p.id=p_payment_id for update;
  if not found then raise exception using errcode='23503',message='Payment was not found.'; end if;
  if v_payment.status<>'draft' then
    raise exception using errcode='23514',message='Allocations can only be changed while the payment is a draft.';
  end if;
  if v_payment.payment_type='transfer' and pg_catalog.jsonb_array_length(p_allocations)>0 then
    raise exception using errcode='23514',message='Bank transfers cannot have invoice allocations.';
  end if;
  if exists (
    select 1 from pg_catalog.jsonb_to_recordset(p_allocations) as x(
      document_type text,document_id uuid,allocated_amount numeric
    )
    where x.document_type not in ('purchase','purchase_return','sales','sales_return','expense')
      or x.document_id is null or x.allocated_amount is null or x.allocated_amount<=0
  ) then
    raise exception using errcode='22023',message='Every allocation requires a supported document type, document ID, and positive amount.';
  end if;
  select count(*) into v_count
  from pg_catalog.jsonb_to_recordset(p_allocations) as x(
    document_type text,document_id uuid,allocated_amount numeric
  );
  if v_count<>pg_catalog.jsonb_array_length(p_allocations) then
    raise exception using errcode='22023',message='Allocation records could not be parsed.';
  end if;
  delete from public.payment_allocations
  where organization_id=p_organization_id and payment_id=p_payment_id;
  insert into public.payment_allocations(
    organization_id,payment_id,document_type,document_id,allocated_amount
  )
  select p_organization_id,p_payment_id,x.document_type,x.document_id,x.allocated_amount
  from pg_catalog.jsonb_to_recordset(p_allocations) as x(
    document_type text,document_id uuid,allocated_amount numeric
  );
  perform public.validate_payment_allocations(p_organization_id,p_payment_id);
end;
$function$;
revoke all on function public.set_payment_allocations(uuid,uuid,jsonb) from public,anon;
grant execute on function public.set_payment_allocations(uuid,uuid,jsonb) to authenticated;

-- ============================================================================
-- CONTROLLED INVENTORY ADJUSTMENT POSTING
-- ============================================================================

create or replace function public.post_inventory_adjustment(
  p_organization_id uuid,
  p_adjustment_date date,
  p_reason text,
  p_lines jsonb,
  p_gain_account_id uuid default null,
  p_loss_account_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_journal_id uuid := pg_catalog.gen_random_uuid();
  v_entry_number text;
  v_gain_account uuid;
  v_loss_account uuid;
  v_line record;
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_line_value numeric(20,4);
  v_line_no integer := 0;
  v_count integer;
begin
  perform 1 from public.organizations o
  where o.id=p_organization_id and o.is_active for share;
  if not found then raise exception using errcode='23503',message='Active organization was not found.'; end if;
  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'inventory.adjust') then
    raise exception using errcode='42501',message='Not authorized to post inventory adjustments.';
  end if;
  if p_adjustment_date is null or p_reason is null or pg_catalog.length(pg_catalog.btrim(p_reason))<3
     or p_lines is null or pg_catalog.jsonb_typeof(p_lines)<>'array'
     or pg_catalog.jsonb_array_length(p_lines)<1 then
    raise exception using errcode='22023',message='Adjustment date, reason, and at least one inventory line are required.';
  end if;

  select count(*) into v_count
  from pg_catalog.jsonb_to_recordset(p_lines) as x(
    product_id uuid,direction text,quantity numeric,unit_cost numeric
  );
  if v_count<>pg_catalog.jsonb_array_length(p_lines) or exists (
    select 1 from pg_catalog.jsonb_to_recordset(p_lines) as x(
      product_id uuid,direction text,quantity numeric,unit_cost numeric
    )
    where x.product_id is null or x.direction not in ('increase','decrease')
      or x.quantity is null or x.quantity<=0
      or (x.direction='increase' and (x.unit_cost is null or x.unit_cost<=0))
  ) then
    raise exception using errcode='22023',message='Each adjustment line requires a product, increase/decrease direction, positive quantity, and positive cost for increases.';
  end if;

  select a.id into v_gain_account
  from public.accounts a
  where a.organization_id=p_organization_id
    and a.id=coalesce(p_gain_account_id,(select id from public.accounts where organization_id=p_organization_id and account_code='4300'))
    and a.account_type='revenue' and a.is_active and a.is_postable;
  if v_gain_account is null then raise exception using errcode='23514',message='An active, postable inventory adjustment gain revenue account is required.'; end if;

  select a.id into v_loss_account
  from public.accounts a
  where a.organization_id=p_organization_id
    and a.id=coalesce(p_loss_account_id,(select id from public.accounts where organization_id=p_organization_id and account_code='5300'))
    and a.account_type='expense' and a.is_active and a.is_postable;
  if v_loss_account is null then raise exception using errcode='23514',message='An active, postable inventory adjustment loss expense account is required.'; end if;

  for v_line in
    select distinct x.product_id
    from pg_catalog.jsonb_to_recordset(p_lines) as x(
      product_id uuid,direction text,quantity numeric,unit_cost numeric
    )
    order by x.product_id
  loop
    if not exists (
      select 1 from public.products pr
      join public.accounts a on a.organization_id=pr.organization_id and a.id=pr.inventory_account_id
      where pr.organization_id=p_organization_id and pr.id=v_line.product_id
        and pr.is_active and a.is_active and a.is_postable and a.account_type='asset'
    ) then
      raise exception using errcode='23514',message='Every adjusted product must be active and mapped to an active, postable inventory asset account.';
    end if;
    insert into public.inventory_balances(organization_id,product_id,quantity,average_cost,inventory_value)
    values(p_organization_id,v_line.product_id,0,0,0)
    on conflict(organization_id,product_id) do nothing;
    perform 1 from public.inventory_balances b
    where b.organization_id=p_organization_id and b.product_id=v_line.product_id for update;
  end loop;

  v_entry_number := public.next_document_number(p_organization_id,'inventory_adjustment');
  insert into public.journal_entries(
    id,organization_id,entry_number,entry_date,entry_type,status,reference_type,reference_id,
    description,posted_at,posted_by,created_by
  )
  values(
    v_journal_id,p_organization_id,v_entry_number,p_adjustment_date,'adjustment','posted',
    'inventory_adjustment',v_journal_id,pg_catalog.btrim(p_reason),pg_catalog.now(),v_user_id,v_user_id
  );

  for v_line in
    select (x.item->>'product_id')::uuid as product_id,
      x.item->>'direction' as direction,
      (x.item->>'quantity')::numeric as quantity,
      (x.item->>'unit_cost')::numeric as unit_cost,
      x.ordinality
    from pg_catalog.jsonb_array_elements(p_lines) with ordinality as x(item,ordinality)
    order by (x.item->>'product_id')::uuid,x.ordinality
  loop
    select b.quantity,b.inventory_value,b.average_cost
    into v_balance_quantity,v_balance_value,v_average_cost
    from public.inventory_balances b
    where b.organization_id=p_organization_id and b.product_id=v_line.product_id
    for update;

    if v_line.direction='increase' then
      v_line_value:=round(v_line.quantity*v_line.unit_cost,4);
      v_new_quantity:=v_balance_quantity+v_line.quantity;
      v_new_value:=v_balance_value+v_line_value;
    else
      if v_line.quantity>v_balance_quantity then
        raise exception using errcode='23514',message='Inventory decrease exceeds the available product quantity.';
      end if;
      v_line_value:=case when v_line.quantity=v_balance_quantity then v_balance_value
        else round(v_line.quantity*v_average_cost,4) end;
      v_new_quantity:=v_balance_quantity-v_line.quantity;
      v_new_value:=v_balance_value-v_line_value;
    end if;
    if v_line_value<=0 or v_new_quantity<0 or v_new_value<0 then
      raise exception using errcode='23514',message='Inventory adjustment would create a zero-value movement or negative stock valuation.';
    end if;
    v_new_average:=case when v_new_quantity=0 then 0 else round(v_new_value/v_new_quantity,6) end;

    update public.inventory_balances
    set quantity=v_new_quantity,inventory_value=v_new_value,average_cost=v_new_average,updated_at=pg_catalog.now()
    where organization_id=p_organization_id and product_id=v_line.product_id;

    insert into public.inventory_transactions(
      organization_id,transaction_number,product_id,transaction_date,transaction_type,direction,
      quantity,unit_cost,total_value,reference_type,reference_id,unit_cost_before,average_cost_after,created_by
    )
    values(
      p_organization_id,v_entry_number||'-'||v_line.ordinality::text,v_line.product_id,p_adjustment_date,
      'adjustment',case when v_line.direction='increase' then 'in' else 'out' end,
      v_line.quantity,case when v_line.direction='increase' then v_line.unit_cost else v_average_cost end,
      v_line_value,'inventory_adjustment',v_journal_id,v_average_cost,v_new_average,v_user_id
    );
  end loop;

  insert into public.account_transactions(
    organization_id,journal_entry_id,account_id,line_number,description,debit,credit,contact_id
  )
  select p_organization_id,v_journal_id,pr.inventory_account_id,
    row_number() over(order by pr.inventory_account_id,it.direction)::integer,
    'Inventory adjustment - '||v_entry_number,
    case when it.direction='in' then sum(it.total_value) else 0 end,
    case when it.direction='out' then sum(it.total_value) else 0 end,
    null
  from public.inventory_transactions it
  join public.products pr on pr.organization_id=it.organization_id and pr.id=it.product_id
  where it.organization_id=p_organization_id and it.reference_type='inventory_adjustment' and it.reference_id=v_journal_id
  group by pr.inventory_account_id,it.direction
  having sum(it.total_value)>0;

  select coalesce(max(atx.line_number),0) into v_line_no
  from public.account_transactions atx
  where atx.organization_id=p_organization_id and atx.journal_entry_id=v_journal_id;

  insert into public.account_transactions(
    organization_id,journal_entry_id,account_id,line_number,description,debit,credit,contact_id
  )
  select p_organization_id,v_journal_id,v_gain_account,v_line_no+1,
    'Inventory adjustment gain - '||v_entry_number,0,sum(it.total_value),null
  from public.inventory_transactions it
  where it.organization_id=p_organization_id and it.reference_type='inventory_adjustment'
    and it.reference_id=v_journal_id and it.direction='in'
  having sum(it.total_value)>0;

  insert into public.account_transactions(
    organization_id,journal_entry_id,account_id,line_number,description,debit,credit,contact_id
  )
  select p_organization_id,v_journal_id,v_loss_account,v_line_no+2,
    'Inventory adjustment loss - '||v_entry_number,sum(it.total_value),0,null
  from public.inventory_transactions it
  where it.organization_id=p_organization_id and it.reference_type='inventory_adjustment'
    and it.reference_id=v_journal_id and it.direction='out'
  having sum(it.total_value)>0;

  if (select coalesce(sum(debit),0) from public.account_transactions where organization_id=p_organization_id and journal_entry_id=v_journal_id)
     <> (select coalesce(sum(credit),0) from public.account_transactions where organization_id=p_organization_id and journal_entry_id=v_journal_id) then
    raise exception using errcode='23514',message='Inventory adjustment journal failed debit/credit reconciliation.';
  end if;
  return v_journal_id;
end;
$function$;
revoke all on function public.post_inventory_adjustment(uuid,date,text,jsonb,uuid,uuid) from public,anon;
grant execute on function public.post_inventory_adjustment(uuid,date,text,jsonb,uuid,uuid) to authenticated;

-- ============================================================================
-- FINANCIAL AND OPERATIONAL REPORTING CONTRACTS
-- ============================================================================

create or replace function public.report_trial_balance(
  p_organization_id uuid,p_date_from date,p_date_to date
)
returns table(account_id uuid,account_code text,account_name text,account_type text,
  opening_balance numeric,movement_debit numeric,movement_credit numeric,closing_balance numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view financial reports.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then
    raise exception using errcode='22023',message='A valid report date range is required.';
  end if;
  return query
  select a.id,a.account_code,a.account_name,a.account_type,
    coalesce(sum(atx.debit-atx.credit) filter(where je.entry_date<p_date_from),0)::numeric,
    coalesce(sum(atx.debit) filter(where je.entry_date between p_date_from and p_date_to),0)::numeric,
    coalesce(sum(atx.credit) filter(where je.entry_date between p_date_from and p_date_to),0)::numeric,
    coalesce(sum(atx.debit-atx.credit) filter(where je.entry_date<=p_date_to),0)::numeric
  from public.accounts a
  left join public.account_transactions atx on atx.organization_id=a.organization_id and atx.account_id=a.id
  left join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
    and je.status in ('posted','reversed') and je.entry_date<=p_date_to
  where a.organization_id=p_organization_id and a.is_postable
  group by a.id,a.account_code,a.account_name,a.account_type
  order by a.account_code;
end;
$function$;

create or replace function public.report_general_ledger(
  p_organization_id uuid,p_account_id uuid,p_date_from date,p_date_to date
)
returns table(entry_date date,entry_number text,description text,contact_id uuid,
  debit numeric,credit numeric,running_balance numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view financial reports.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then
    raise exception using errcode='22023',message='A valid report date range is required.';
  end if;
  if not exists(select 1 from public.accounts a where a.organization_id=p_organization_id and a.id=p_account_id) then
    raise exception using errcode='23503',message='Account was not found in this organization.';
  end if;
  return query
  with opening as (
    select coalesce(sum(atx.debit-atx.credit),0) as balance
    from public.account_transactions atx
    join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
    where atx.organization_id=p_organization_id and atx.account_id=p_account_id
      and je.status in ('posted','reversed') and je.entry_date<p_date_from
  ), activity as (
    select je.entry_date,je.entry_number,coalesce(atx.description,je.description) as description,
      atx.contact_id,atx.debit,atx.credit,
      row_number() over(order by je.entry_date,je.created_at,je.id,atx.line_number) as rn
    from public.account_transactions atx
    join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
    where atx.organization_id=p_organization_id and atx.account_id=p_account_id
      and je.status in ('posted','reversed') and je.entry_date between p_date_from and p_date_to
  )
  select a.entry_date,a.entry_number,a.description,a.contact_id,a.debit,a.credit,
    (o.balance+sum(a.debit-a.credit) over(order by a.rn))::numeric
  from activity a cross join opening o order by a.rn;
end;
$function$;

create or replace function public.report_profit_and_loss(
  p_organization_id uuid,p_date_from date,p_date_to date
)
returns table(account_id uuid,account_code text,account_name text,account_type text,amount numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view financial reports.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then
    raise exception using errcode='22023',message='A valid report date range is required.';
  end if;
  return query
  select a.id,a.account_code,a.account_name,a.account_type,
    (case when a.account_type='revenue' then sum(atx.credit-atx.debit)
      else sum(atx.debit-atx.credit) end)::numeric
  from public.accounts a
  join public.account_transactions atx on atx.organization_id=a.organization_id and atx.account_id=a.id
  join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
  where a.organization_id=p_organization_id and a.account_type in ('revenue','expense')
    and a.is_postable and je.status in ('posted','reversed')
    and je.entry_date between p_date_from and p_date_to
  group by a.id,a.account_code,a.account_name,a.account_type
  order by a.account_type,a.account_code;
end;
$function$;

create or replace function public.report_balance_sheet(
  p_organization_id uuid,p_as_of_date date
)
returns table(account_id uuid,account_code text,account_name text,account_type text,balance numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view financial reports.';
  end if;
  if p_as_of_date is null then raise exception using errcode='22023',message='An as-of date is required.'; end if;
  return query
  with balances as (
    select a.id,a.account_code,a.account_name,a.account_type,
      (case when a.account_type='asset' then sum(atx.debit-atx.credit)
        else sum(atx.credit-atx.debit) end)::numeric as balance
    from public.accounts a
    join public.account_transactions atx on atx.organization_id=a.organization_id and atx.account_id=a.id
    join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
    where a.organization_id=p_organization_id and a.account_type in ('asset','liability','equity')
      and a.is_postable and je.status in ('posted','reversed') and je.entry_date<=p_as_of_date
    group by a.id,a.account_code,a.account_name,a.account_type
    having sum(atx.debit-atx.credit)<>0
  ), current_earnings as (
    select coalesce(sum(atx.credit-atx.debit),0)::numeric as amount
    from public.accounts a
    join public.account_transactions atx on atx.organization_id=a.organization_id and atx.account_id=a.id
    join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
    where a.organization_id=p_organization_id and a.account_type in ('revenue','expense')
      and a.is_postable and je.status in ('posted','reversed') and je.entry_date<=p_as_of_date
  )
  select b.id,b.account_code,b.account_name,b.account_type,b.balance from balances b
  union all
  select null::uuid,'CURRENT_EARNINGS'::text,'Current earnings'::text,'equity'::text,ce.amount
  from current_earnings ce where ce.amount<>0
  order by 4,2;
end;
$function$;

create or replace function public.report_inventory_valuation(
  p_organization_id uuid,p_as_of_date date default current_date
)
returns table(product_id uuid,product_code text,product_name text,quantity numeric,
  inventory_value numeric,average_cost numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'inventory.read') then
    raise exception using errcode='42501',message='Not authorized to view inventory valuation.';
  end if;
  if p_as_of_date is null then raise exception using errcode='22023',message='An as-of date is required.'; end if;
  return query
  select pr.id,pr.product_code,pr.name,
    coalesce(sum(case when it.direction='in' then it.quantity else -it.quantity end),0)::numeric,
    coalesce(sum(case when it.direction='in' then it.total_value else -it.total_value end),0)::numeric,
    case when coalesce(sum(case when it.direction='in' then it.quantity else -it.quantity end),0)=0
      then 0
      else round(coalesce(sum(case when it.direction='in' then it.total_value else -it.total_value end),0)
        /sum(case when it.direction='in' then it.quantity else -it.quantity end),6) end::numeric
  from public.products pr
  left join public.inventory_transactions it on it.organization_id=pr.organization_id
    and it.product_id=pr.id and it.transaction_date<=p_as_of_date
  where pr.organization_id=p_organization_id
  group by pr.id,pr.product_code,pr.name
  order by pr.product_code;
end;
$function$;

create or replace function public.report_contact_balances(
  p_organization_id uuid,p_as_of_date date default current_date
)
returns table(contact_id uuid,contact_name text,account_id uuid,account_code text,
  account_type text,balance numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view contact balances.';
  end if;
  if p_as_of_date is null then raise exception using errcode='22023',message='An as-of date is required.'; end if;
  return query
  select c.id,c.name,a.id,a.account_code,a.account_type,
    (case when a.account_type='asset' then sum(atx.debit-atx.credit)
      else sum(atx.credit-atx.debit) end)::numeric
  from public.account_transactions atx
  join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id
  join public.contacts c on c.organization_id=atx.organization_id and c.id=atx.contact_id
  join public.accounts a on a.organization_id=atx.organization_id and a.id=atx.account_id
  where atx.organization_id=p_organization_id and atx.contact_id is not null
    and a.is_control_account and je.status in ('posted','reversed') and je.entry_date<=p_as_of_date
  group by c.id,c.name,a.id,a.account_code,a.account_type
  having sum(atx.debit-atx.credit)<>0
  order by c.name,a.account_code;
end;
$function$;

create or replace function public.report_receivables_aging(
  p_organization_id uuid,p_as_of_date date default current_date
)
returns table(document_id uuid,document_number text,contact_id uuid,contact_name text,
  invoice_date date,days_outstanding integer,current_amount numeric,days_31_60 numeric,
  days_61_90 numeric,over_90 numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view receivables aging.';
  end if;
  if p_as_of_date is null then raise exception using errcode='22023',message='An as-of date is required.'; end if;
  return query
  with open_docs as (
    select s.id,s.invoice_id,s.customer_id,s.invoice_date,
      greatest(0,s.total_amount
        -coalesce((select sum(pa.allocated_amount) from public.payment_allocations pa
          join public.payments p on p.organization_id=pa.organization_id and p.id=pa.payment_id
          where pa.organization_id=p_organization_id and pa.document_type='sales'
            and pa.document_id=s.id and p.status='posted'),0)
        -coalesce((select sum(sr.total_amount) from public.sales_returns sr
          where sr.organization_id=p_organization_id and sr.sales_id=s.id and sr.status='posted'
            and sr.return_date<=p_as_of_date),0)) as outstanding
    from public.sales s
    where s.organization_id=p_organization_id and s.status in ('posted','partially_returned')
      and s.invoice_date<=p_as_of_date
  )
  select d.id,d.invoice_id,c.id,c.name,d.invoice_date,(p_as_of_date-d.invoice_date)::integer,
    case when p_as_of_date-d.invoice_date<=30 then d.outstanding else 0 end,
    case when p_as_of_date-d.invoice_date between 31 and 60 then d.outstanding else 0 end,
    case when p_as_of_date-d.invoice_date between 61 and 90 then d.outstanding else 0 end,
    case when p_as_of_date-d.invoice_date>90 then d.outstanding else 0 end
  from open_docs d join public.contacts c on c.organization_id=p_organization_id and c.id=d.customer_id
  where d.outstanding>0 order by d.invoice_date,d.invoice_id;
end;
$function$;

create or replace function public.report_payables_aging(
  p_organization_id uuid,p_as_of_date date default current_date
)
returns table(document_type text,document_id uuid,document_number text,contact_id uuid,
  contact_name text,document_date date,days_outstanding integer,current_amount numeric,
  days_31_60 numeric,days_61_90 numeric,over_90 numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view payables aging.';
  end if;
  if p_as_of_date is null then raise exception using errcode='22023',message='An as-of date is required.'; end if;
  return query
  with docs as (
    select 'purchase'::text as dtype,p.id,p.invoice_id as number,p.supplier_id as contact,p.invoice_date as doc_date,
      greatest(0,p.total_amount
        -coalesce((select sum(pa.allocated_amount) from public.payment_allocations pa
          join public.payments pm on pm.organization_id=pa.organization_id and pm.id=pa.payment_id
          where pa.organization_id=p_organization_id and pa.document_type='purchase'
            and pa.document_id=p.id and pm.status='posted' and pm.payment_date<=p_as_of_date),0)
        -coalesce((select sum(pr.total_amount) from public.purchase_returns pr
          where pr.organization_id=p_organization_id and pr.purchase_id=p.id and pr.status='posted'
            and pr.return_date<=p_as_of_date),0)) as outstanding
    from public.purchase p where p.organization_id=p_organization_id
      and p.status in ('posted','partially_returned') and p.invoice_date<=p_as_of_date
    union all
    select 'expense',e.id,e.expense_number,e.contact_id,e.expense_date,
      greatest(0,e.amount-coalesce((select sum(pa.allocated_amount) from public.payment_allocations pa
        join public.payments pm on pm.organization_id=pa.organization_id and pm.id=pa.payment_id
        where pa.organization_id=p_organization_id and pa.document_type='expense'
          and pa.document_id=e.id and pm.status='posted' and pm.payment_date<=p_as_of_date),0))
    from public.expenses e where e.organization_id=p_organization_id and e.status='posted'
      and e.contact_id is not null and e.expense_date<=p_as_of_date
  )
  select d.dtype,d.id,d.number,c.id,c.name,d.doc_date,(p_as_of_date-d.doc_date)::integer,
    case when p_as_of_date-d.doc_date<=30 then d.outstanding else 0 end,
    case when p_as_of_date-d.doc_date between 31 and 60 then d.outstanding else 0 end,
    case when p_as_of_date-d.doc_date between 61 and 90 then d.outstanding else 0 end,
    case when p_as_of_date-d.doc_date>90 then d.outstanding else 0 end
  from docs d join public.contacts c on c.organization_id=p_organization_id and c.id=d.contact
  where d.outstanding>0 order by d.doc_date,d.number;
end;
$function$;


create or replace function public.report_unapplied_payments(
  p_organization_id uuid,p_as_of_date date default current_date
)
returns table(payment_id uuid,payment_number text,payment_type text,contact_id uuid,
  contact_name text,payment_date date,unapplied_amount numeric)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'reports.read') then
    raise exception using errcode='42501',message='Not authorized to view unapplied payment balances.';
  end if;
  if p_as_of_date is null then raise exception using errcode='22023',message='An as-of date is required.'; end if;
  return query
  select p.id,p.payment_number,p.payment_type,p.contact_id,c.name,p.payment_date,
    (p.amount-coalesce(sum(pa.allocated_amount),0))::numeric
  from public.payments p
  left join public.contacts c on c.organization_id=p.organization_id and c.id=p.contact_id
  left join public.payment_allocations pa on pa.organization_id=p.organization_id and pa.payment_id=p.id
  where p.organization_id=p_organization_id and p.status='posted'
    and p.payment_type in ('receipt','payment','refund') and p.payment_date<=p_as_of_date
  group by p.id,p.payment_number,p.payment_type,p.contact_id,c.name,p.payment_date,p.amount
  having p.amount-coalesce(sum(pa.allocated_amount),0)>0
  order by p.payment_date,p.payment_number;
end;
$function$;
revoke all on function public.report_unapplied_payments(uuid,date) from public,anon;
grant execute on function public.report_unapplied_payments(uuid,date) to authenticated;

revoke all on function public.report_trial_balance(uuid,date,date) from public,anon;
revoke all on function public.report_general_ledger(uuid,uuid,date,date) from public,anon;
revoke all on function public.report_profit_and_loss(uuid,date,date) from public,anon;
revoke all on function public.report_balance_sheet(uuid,date) from public,anon;
revoke all on function public.report_inventory_valuation(uuid,date) from public,anon;
revoke all on function public.report_contact_balances(uuid,date) from public,anon;
revoke all on function public.report_receivables_aging(uuid,date) from public,anon;
revoke all on function public.report_payables_aging(uuid,date) from public,anon;
grant execute on function public.report_trial_balance(uuid,date,date) to authenticated;
grant execute on function public.report_general_ledger(uuid,uuid,date,date) to authenticated;
grant execute on function public.report_profit_and_loss(uuid,date,date) to authenticated;
grant execute on function public.report_balance_sheet(uuid,date) to authenticated;
grant execute on function public.report_inventory_valuation(uuid,date) to authenticated;
grant execute on function public.report_contact_balances(uuid,date) to authenticated;
grant execute on function public.report_receivables_aging(uuid,date) to authenticated;
grant execute on function public.report_payables_aging(uuid,date) to authenticated;



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
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'users.manage') then
    raise exception using errcode='42501',message='Not authorized to assign organization roles.';
  end if;
  perform 1 from public.organizations o where o.id=p_organization_id and o.is_active for update;
  if not found then raise exception using errcode='23503',message='Active organization was not found.'; end if;
  if not exists(select 1 from public.roles r
    where r.organization_id=p_organization_id and r.id=p_role_id and r.status='active') then
    raise exception using errcode='23503',message='The selected role must be active and belong to this organization.';
  end if;
  if exists (
    select 1 from public.role_permissions rp
    join public.permissions p on p.id=rp.permission_id
    where rp.role_id=p_role_id
      and not public.has_org_permission(p_organization_id,p.permission_key)
  ) then
    raise exception using errcode='42501',
      message='You cannot assign a role containing permissions you do not hold.';
  end if;
end;
$function$;
revoke all on function public.validate_role_assignment(uuid,uuid) from public,anon;
grant execute on function public.validate_role_assignment(uuid,uuid) to authenticated;

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
  if (select auth.uid()) is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id,'roles.manage') then
    raise exception using errcode='42501',message='Not authorized to update custom roles.';
  end if;
  if p_name is null or pg_catalog.length(pg_catalog.btrim(p_name)) not between 1 and 100
     or p_status not in ('active','inactive') then
    raise exception using errcode='22023',message='Role name or status is invalid.';
  end if;
  perform 1 from public.organizations o where o.id=p_organization_id and o.is_active for update;
  if not found then raise exception using errcode='23503',message='Active organization was not found.'; end if;
  select r.is_system_role into v_system
  from public.roles r where r.organization_id=p_organization_id and r.id=p_role_id for update;
  if not found then raise exception using errcode='23503',message='Role was not found in this organization.'; end if;
  if v_system then raise exception using errcode='42501',message='System roles cannot be renamed or deactivated.'; end if;
  if p_status='inactive' and exists (
    select 1 from public.organization_users ou
    where ou.organization_id=p_organization_id and ou.role_id=p_role_id and ou.is_active
  ) then
    raise exception using errcode='23514',message='Reassign or deactivate all active members before deactivating this role.';
  end if;
  update public.roles set name=pg_catalog.btrim(p_name),status=p_status
  where organization_id=p_organization_id and id=p_role_id;
exception when unique_violation then
  raise exception using errcode='23505',message='A role with this name already exists.';
end;
$function$;
revoke all on function public.update_custom_role(uuid,uuid,text,text) from public,anon;
grant execute on function public.update_custom_role(uuid,uuid,text,text) to authenticated;

-- Final bootstrap policy layer, identical to the incremental membership-security migration.
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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

  -- Re-check after acquiring the organization row lock. A concurrent handover
  -- may have revoked the caller's Administrator status while this RPC waited.
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can perform administrative operations.';
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
  
  -- Serialize profile writes with Administrator handover and re-check authority
  -- after acquiring the organization row lock.
  perform 1 from public.organizations o
  where o.id = p_organization_id and o.is_active
  for update;
  if not found then
    raise exception using errcode = '23503',
      message = 'Active organization was not found.';
  end if;
  if not public.is_org_administrator(p_organization_id) then
    raise exception using errcode = '42501',
      message = 'Only the active organization Administrator can update company details.';
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
