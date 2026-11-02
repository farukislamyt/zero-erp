-- Zero ERP: ledger, inventory, purchasing, sales, expenses, and payments
-- Migration: 20261102000200_transaction_schema.sql
-- Depends on 20261102000100_core_foundation.sql.
-- All financial and inventory writes remain unavailable to client roles until the
-- posting and allocation RPCs have been implemented and granted explicitly.

begin;

create table public.journal_entries (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  entry_number text not null check (pg_catalog.length(pg_catalog.btrim(entry_number)) between 1 and 80),
  accounting_period_id uuid not null,
  entry_date date not null,
  entry_type text not null
    check (entry_type in ('manual', 'purchase', 'purchase_return', 'sale', 'sales_return', 'expense', 'payment', 'reversal', 'opening_balance', 'adjustment')),
  status text not null default 'draft' check (status in ('draft', 'posted', 'reversed', 'void')),
  reference_type text,
  reference_id uuid,
  description text,
  posted_at timestamptz,
  reversal_of_id uuid,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint journal_entries_org_id_id_uq unique (organization_id, id),
  constraint journal_entries_org_number_uq unique (organization_id, entry_number),
  constraint journal_entries_period_same_org_fk
    foreign key (organization_id, accounting_period_id)
    references public.accounting_periods (organization_id, id)
    on delete restrict,
  constraint journal_entries_reversal_same_org_fk
    foreign key (organization_id, reversal_of_id)
    references public.journal_entries (organization_id, id)
    on delete restrict,
  constraint journal_entries_not_self_reversal_chk check (reversal_of_id is distinct from id),
  constraint journal_entries_posted_timestamp_chk
    check ((status in ('posted', 'reversed') and posted_at is not null) or status in ('draft', 'void'))
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
  quantity numeric(20, 6) not null default 0,
  average_cost numeric(20, 6) not null default 0 check (average_cost >= 0),
  inventory_value numeric(20, 4) not null default 0,
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
  status text not null default 'draft' check (status in ('draft', 'approved', 'posted', 'partially_returned', 'returned', 'void')),
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
  constraint purchase_discount_limit_chk check (discount_amount <= subtotal)
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
  status text not null default 'draft' check (status in ('draft', 'posted', 'void')),
  subtotal numeric(20, 4) not null default 0 check (subtotal >= 0),
  discount_amount numeric(20, 4) not null default 0 check (discount_amount >= 0),
  total_amount numeric(20, 4) not null default 0 check (total_amount >= 0),
  payable_account_id uuid not null,
  posted_journal_entry_id uuid,
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
  constraint purchase_returns_discount_limit_chk check (discount_amount <= subtotal)
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
  status text not null default 'draft' check (status in ('draft', 'approved', 'posted', 'partially_returned', 'returned', 'void')),
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
  constraint sales_discount_limit_chk check (discount_amount <= subtotal)
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
  status text not null default 'draft' check (status in ('draft', 'posted', 'void')),
  subtotal numeric(20, 4) not null default 0 check (subtotal >= 0),
  discount_amount numeric(20, 4) not null default 0 check (discount_amount >= 0),
  total_amount numeric(20, 4) not null default 0 check (total_amount >= 0),
  receivable_account_id uuid not null,
  posted_journal_entry_id uuid,
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
  constraint sales_returns_discount_limit_chk check (discount_amount <= subtotal)
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
  status text not null default 'draft' check (status in ('draft', 'approved', 'posted', 'void')),
  posted_journal_entry_id uuid,
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
    on delete restrict
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
  status text not null default 'draft' check (status in ('draft', 'approved', 'posted', 'void')),
  posted_journal_entry_id uuid,
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
    on delete restrict
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
create index journal_entries_period_idx on public.journal_entries (organization_id, accounting_period_id);
create unique index journal_entries_one_reversal_per_entry_uq
  on public.journal_entries (organization_id, reversal_of_id) where reversal_of_id is not null;
create index account_transactions_account_idx on public.account_transactions (organization_id, account_id);
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
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy account_transactions_select_member on public.account_transactions
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy inventory_transactions_select_member on public.inventory_transactions
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy inventory_balances_select_member on public.inventory_balances
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy purchase_select_member on public.purchase
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy purchase_items_select_member on public.purchase_items
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy purchase_returns_select_member on public.purchase_returns
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy purchase_return_items_select_member on public.purchase_return_items
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy sales_select_member on public.sales
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy sales_items_select_member on public.sales_items
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy sales_returns_select_member on public.sales_returns
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy sales_return_items_select_member on public.sales_return_items
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy expenses_select_member on public.expenses
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy payments_select_member on public.payments
  for select to authenticated using (public.is_active_org_member(organization_id));
create policy payment_allocations_select_member on public.payment_allocations
  for select to authenticated using (public.is_active_org_member(organization_id));

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

commit;
