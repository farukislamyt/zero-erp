# Zero ERP — Complete Database Reference

> **Database source of truth.** This reference describes the effective database after applying the migrations below in timestamp order. It is generated from the SQL definitions in this branch; it is not a target design or a description of unimplemented application features.
>
> **Branch:** `feat/database-migrations`  
> **Last reviewed:** 2026-11-03  
> **Scope:** Supabase PostgreSQL, `public` schema, and the external Supabase Auth dependency (`auth.users`, `auth.uid()`).

## Migration chain and effective-state rule

Apply these migrations in order:

1. [`20261103000000_initial_database_schema.sql`](../supabase/migrations/20261103000000_initial_database_schema.sql) — creates the tables, constraints, indexes, seeds, initial functions, triggers, RLS policies and grants for a new/empty database.
2. [`20261103010000_organization_membership_security.sql`](../supabase/migrations/20261103010000_organization_membership_security.sql) — adds/overrides membership, creator-anchor, RBAC, role-management and profile functions/triggers; adds the one-active-company-per-user unique index.
3. [`20261103020000_permanent_organization_administrator.sql`](../supabase/migrations/20261103020000_permanent_organization_administrator.sql) — makes the original creator membership permanently immutable, protects the Administrator role, redefines organization creation and drops the Administrator-transfer RPC.

A later `CREATE OR REPLACE FUNCTION` replaces the earlier body for the same function signature. A later `DROP TRIGGER` / `CREATE TRIGGER` replaces the named trigger on its table. The historical `transfer_organization_administrator(uuid, uuid)` function existed in an earlier migration but is **not present in the effective final schema** because migration 0200 drops it. The legacy `post_manual_journal_entry(...)` function remains defined but its client EXECUTE privilege is revoked.

## Effective database inventory

| Object class | Effective count / state |
|---|---:|
| Tables in `public` | 26 |
| Tables with RLS enabled | 26 |
| RLS policies | 26 |
| Effective triggers | 37 |
| Explicit indexes (including unique/partial) | 30 |
| Effective public functions (transfer RPC excluded) | 53 |
| Seeded global permission keys | 43 |
| Views / materialized views | 0 |
| Custom enum/type/domain definitions | 0 |
| User-defined sequences | 0 |
| User-created schemas / extensions | 0 |

The database uses PostgreSQL built-ins and Supabase-managed `auth.users` / `auth.uid()`; those Auth objects are not created by these migrations.

## Tenant and authorization model

- `organizations` is the tenant root.
- Tenant-owned records carry `organization_id`; tenant-owned references are generally protected by composite foreign keys containing `organization_id`.
- `organization_users` links a Supabase Auth user to an organization and assigns exactly one `role_id` per membership.
- `permissions` is a global seeded catalog. `roles` are organization-scoped. `role_permissions` joins roles to permissions.
- RLS is enabled on all 26 public tables. The installed policies are SELECT policies; browser-role mutations are intended to use granted, permission-checked RPCs rather than direct table writes.
- The original organization creator is identified by the creator membership whose `created_at` equals `organizations.created_at`. The final migration rejects any update or delete to that membership and rejects any later Administrator assignment.
- A partial unique index enforces at most one active organization membership per Auth user.

## Table-by-table reference

Every column definition below is transcribed from the effective table-creation DDL. Constraint definitions include inline constraints and later `ALTER TABLE ... ADD CONSTRAINT` statements. Indexes, triggers, and RLS policies are listed under the table to which they apply.

### `public.organizations`

**Purpose:** Tenant root and organization profile/default settings.

**Columns (14):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `name` | `text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 160)` |
| `phone` | `text` |
| `email` | `text` |
| `address` | `text` |
| `city` | `text` |
| `country` | `text` |
| `currency` | `char(3) not null default 'BDT'` |
| `timezone` | `text not null default 'Asia/Dhaka'` |
| `tin` | `text` |
| `bin` | `text` |
| `is_active` | `boolean not null default true` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (1):**

- `constraint organizations_currency_format_chk check (currency ~ '^[A-Z]{3}$')`

**Indexes:**

- No explicit index created directly on this table beyond primary/unique constraints.

**Triggers:**

```sql
create trigger organizations_set_updated_at before update on public.organizations for each row execute function public.set_updated_at();
```

```sql
create trigger organizations_guard_created_at before update of created_at on public.organizations for each row execute function public.guard_organization_created_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy organizations_select_member on public.organizations for select to authenticated using (public.has_org_permission(id, 'organization.read'));
```

### `public.roles`

**Purpose:** Organization-scoped role definitions; includes the immutable system Administrator role and custom roles.

**Columns (7):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `name` | `text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 100)` |
| `status` | `text not null default 'active' check (status in ('active', 'inactive'))` |
| `is_system_role` | `boolean not null default false` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (2):**

- `constraint roles_org_id_id_uq unique (organization_id, id)`
- `constraint roles_org_name_uq unique (organization_id, name)`

**Indexes:**

- `create index roles_org_status_idx on public.roles (organization_id, status);`

**Triggers:**

```sql
create trigger roles_set_updated_at before update on public.roles for each row execute function public.set_updated_at();
```

```sql
create trigger roles_guard_system_role before update or delete on public.roles for each row execute function public.guard_system_role_mutation();
```

```sql
create trigger roles_guard_system_administrator before insert or update or delete on public.roles for each row execute function public.guard_system_administrator_role();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy roles_select_member on public.roles for select to authenticated using (public.has_org_permission(organization_id, 'roles.read'));
```

### `public.permissions`

**Purpose:** Global seeded permission catalog used by RBAC.

**Columns (7):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `permission_key` | `text not null unique check (permission_key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$')` |
| `name` | `text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 120)` |
| `description` | `text` |
| `module` | `text not null check (pg_catalog.length(pg_catalog.btrim(module)) between 1 and 80)` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (0):**

- No table-level constraints declared in the migration.

**Indexes:**

- No explicit index created directly on this table beyond primary/unique constraints.

**Triggers:**

```sql
create trigger permissions_set_updated_at before update on public.permissions for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy permissions_select_authenticated on public.permissions for select to authenticated using (true);
```

### `public.organization_users`

**Purpose:** Supabase Auth user membership in an organization, with one role and active-state flag.

**Columns (7):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `user_id` | `uuid not null references auth.users(id) on delete cascade` |
| `role_id` | `uuid not null` |
| `is_active` | `boolean not null default true` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (3):**

- `constraint organization_users_org_id_id_uq unique (organization_id, id)`
- `constraint organization_users_org_user_uq unique (organization_id, user_id)`
- `constraint organization_users_role_same_org_fk foreign key (organization_id, role_id) references public.roles (organization_id, id) on delete restrict`

**Indexes:**

- `create index organization_users_user_active_idx on public.organization_users (user_id, is_active);`
- `create index organization_users_role_idx on public.organization_users (role_id);`
- `create unique index if not exists organization_users_one_active_company_per_user on public.organization_users (user_id) where is_active = true;`
- `create unique index if not exists organization_users_one_active_company_per_user on public.organization_users (user_id) where is_active = true;`

**Triggers:**

```sql
create trigger organization_users_set_updated_at before update on public.organization_users for each row execute function public.set_updated_at();
```

```sql
create trigger organization_users_guard_creator_record before insert or update or delete on public.organization_users for each row execute function public.guard_organization_creator_membership();
```

```sql
create trigger organization_users_guard_last_admin before insert or update or delete on public.organization_users for each row execute function public.guard_administrator_membership();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy organization_users_select_member_or_self on public.organization_users for select to authenticated using (user_id = (select auth.uid()) or public.has_org_permission(organization_id, 'users.read'));
```

### `public.role_permissions`

**Purpose:** Many-to-many assignment of global permissions to organization roles.

**Columns (4):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `role_id` | `uuid not null references public.roles(id) on delete cascade` |
| `permission_id` | `uuid not null references public.permissions(id) on delete restrict` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (1):**

- `constraint role_permissions_role_permission_uq unique (role_id, permission_id)`

**Indexes:**

- `create index role_permissions_permission_idx on public.role_permissions (permission_id);`

**Triggers:**

```sql
create trigger role_permissions_guard_admin before update or delete on public.role_permissions for each row execute function public.guard_system_role_permissions();
```

```sql
create trigger role_permissions_guard_control_plane before insert or update of role_id, permission_id on public.role_permissions for each row execute function public.guard_custom_role_control_plane_permissions();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy role_permissions_select_member on public.role_permissions for select to authenticated using ( exists ( select 1 from public.roles r where r.id = role_permissions.role_id and public.has_org_permission(r.organization_id, 'roles.read') ) );
```

### `public.accounts`

**Purpose:** Organization chart of accounts, account hierarchy, control/system/postable flags and ledger classification.

**Columns (13):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `account_code` | `text not null check (pg_catalog.length(pg_catalog.btrim(account_code)) between 1 and 40)` |
| `account_name` | `text not null check (pg_catalog.length(pg_catalog.btrim(account_name)) between 1 and 160)` |
| `account_type` | `text not null check (account_type in ('asset', 'liability', 'equity', 'revenue', 'expense'))` |
| `parent_account_id` | `uuid` |
| `normal_balance` | `text not null check (normal_balance in ('debit', 'credit'))` |
| `is_control_account` | `boolean not null default false` |
| `is_system_account` | `boolean not null default false` |
| `is_postable` | `boolean not null default true` |
| `is_active` | `boolean not null default true` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (4):**

- `constraint accounts_org_id_id_uq unique (organization_id, id)`
- `constraint accounts_org_code_uq unique (organization_id, account_code)`
- `constraint accounts_parent_same_org_fk foreign key (organization_id, parent_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint accounts_not_own_parent_chk check (parent_account_id is distinct from id)`

**Indexes:**

- `create index accounts_org_parent_idx on public.accounts (organization_id, parent_account_id);`

**Triggers:**

```sql
create trigger accounts_prevent_hierarchy_cycle before insert or update of organization_id, parent_account_id on public.accounts for each row execute function public.prevent_account_hierarchy_cycle();
```

```sql
create trigger accounts_set_updated_at before update on public.accounts for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy accounts_select_member on public.accounts for select to authenticated using (public.has_org_permission(organization_id, 'accounts.read'));
```

### `public.units_of_measure`

**Purpose:** Organization-scoped product units of measure.

**Columns (6):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `name` | `text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 80)` |
| `is_active` | `boolean not null default true` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (2):**

- `constraint units_of_measure_org_id_id_uq unique (organization_id, id)`
- `constraint units_of_measure_org_name_uq unique (organization_id, name)`

**Indexes:**

- No explicit index created directly on this table beyond primary/unique constraints.

**Triggers:**

```sql
create trigger units_of_measure_set_updated_at before update on public.units_of_measure for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy units_of_measure_select_member on public.units_of_measure for select to authenticated using (public.has_org_permission(organization_id, 'products.read'));
```

### `public.contacts`

**Purpose:** Organization contacts used as customers, suppliers, and other transaction counterparties; no customer/supplier discriminator column exists.

**Columns (11):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `contact_number` | `text not null check (pg_catalog.length(pg_catalog.btrim(contact_number)) between 1 and 50)` |
| `name` | `text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 180)` |
| `phone` | `text` |
| `email` | `text` |
| `address` | `text` |
| `is_active` | `boolean not null default true` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (2):**

- `constraint contacts_org_id_id_uq unique (organization_id, id)`
- `constraint contacts_org_number_uq unique (organization_id, contact_number)`

**Indexes:**

- `create index contacts_org_name_idx on public.contacts (organization_id, name);`

**Triggers:**

```sql
create trigger contacts_set_updated_at before update on public.contacts for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy contacts_select_member on public.contacts for select to authenticated using (public.has_org_permission(organization_id, 'contacts.read'));
```

### `public.products`

**Purpose:** Organization product catalog with unit and optional inventory/sales/COGS account mappings.

**Columns (12):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `product_code` | `text not null check (pg_catalog.length(pg_catalog.btrim(product_code)) between 1 and 60)` |
| `name` | `text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 180)` |
| `unit_id` | `uuid not null` |
| `inventory_account_id` | `uuid` |
| `sales_account_id` | `uuid` |
| `cogs_account_id` | `uuid` |
| `is_active` | `boolean not null default true` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (6):**

- `constraint products_org_id_id_uq unique (organization_id, id)`
- `constraint products_org_code_uq unique (organization_id, product_code)`
- `constraint products_unit_same_org_fk foreign key (organization_id, unit_id) references public.units_of_measure (organization_id, id) on delete restrict`
- `constraint products_inventory_account_same_org_fk foreign key (organization_id, inventory_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint products_sales_account_same_org_fk foreign key (organization_id, sales_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint products_cogs_account_same_org_fk foreign key (organization_id, cogs_account_id) references public.accounts (organization_id, id) on delete restrict`

**Indexes:**

- `create index products_org_name_idx on public.products (organization_id, name);`

**Triggers:**

```sql
create trigger products_set_updated_at before update on public.products for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy products_select_member on public.products for select to authenticated using (public.has_org_permission(organization_id, 'products.read'));
```

### `public.expense_categories`

**Purpose:** Organization expense classifications with optional mapped expense account.

**Columns (8):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `category_code` | `text not null check (pg_catalog.length(pg_catalog.btrim(category_code)) between 1 and 40)` |
| `name` | `text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 120)` |
| `expense_account_id` | `uuid` |
| `is_active` | `boolean not null default true` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (3):**

- `constraint expense_categories_org_id_id_uq unique (organization_id, id)`
- `constraint expense_categories_org_code_uq unique (organization_id, category_code)`
- `constraint expense_categories_account_same_org_fk foreign key (organization_id, expense_account_id) references public.accounts (organization_id, id) on delete restrict`

**Indexes:**

- `create index expense_categories_org_name_idx on public.expense_categories (organization_id, name);`

**Triggers:**

```sql
create trigger expense_categories_set_updated_at before update on public.expense_categories for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy expense_categories_select_member on public.expense_categories for select to authenticated using (public.has_org_permission(organization_id, 'expenses.read'));
```

### `public.number_sequences`

**Purpose:** Per-organization document-number prefix, next value, padding, and active flag.

**Columns (9):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `document_type` | `text not null check (pg_catalog.length(pg_catalog.btrim(document_type)) between 1 and 60)` |
| `prefix` | `text not null default ''` |
| `next_number` | `bigint not null default 1 check (next_number > 0)` |
| `padding` | `smallint not null default 5 check (padding between 1 and 18)` |
| `is_active` | `boolean not null default true` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (2):**

- `constraint number_sequences_org_id_id_uq unique (organization_id, id)`
- `constraint number_sequences_org_type_uq unique (organization_id, document_type)`

**Indexes:**

- No explicit index created directly on this table beyond primary/unique constraints.

**Triggers:**

```sql
create trigger number_sequences_set_updated_at before update on public.number_sequences for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy number_sequences_select_member on public.number_sequences for select to authenticated using (public.has_org_permission(organization_id, 'organization.read'));
```

### `public.journal_entries`

**Purpose:** Journal header, lifecycle/audit timestamps, source references and reversal links.

**Columns (24):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `entry_number` | `text not null check (pg_catalog.length(pg_catalog.btrim(entry_number)) between 1 and 80)` |
| `entry_date` | `date not null` |
| `entry_type` | `text not null check (entry_type in ('manual', 'purchase', 'purchase_return', 'sale', 'sales_return', 'expense', 'payment', 'reversal', 'opening_balance', 'adjustment'))` |
| `status` | `text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'reversed', 'void'))` |
| `confirmed_at` | `timestamptz` |
| `confirmed_by` | `uuid references auth.users(id) on delete set null` |
| `posted_by` | `uuid references auth.users(id) on delete set null` |
| `voided_at` | `timestamptz` |
| `voided_by` | `uuid references auth.users(id) on delete set null` |
| `void_reason` | `text` |
| `reference_type` | `text` |
| `reference_id` | `uuid` |
| `description` | `text` |
| `posted_at` | `timestamptz` |
| `reversal_of_id` | `uuid` |
| `reversal_journal_entry_id` | `uuid` |
| `reversed_at` | `timestamptz` |
| `reversed_by` | `uuid references auth.users(id) on delete set null` |
| `reversal_reason` | `text` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (9):**

- `constraint journal_entries_org_id_id_uq unique (organization_id, id)`
- `constraint journal_entries_org_number_uq unique (organization_id, entry_number)`
- `constraint journal_entries_reversal_same_org_fk foreign key (organization_id, reversal_of_id) references public.journal_entries (organization_id, id) on delete restrict`
- `constraint journal_entries_not_self_reversal_chk check (reversal_of_id is distinct from id)`
- `constraint journal_entries_reversal_entry_same_org_fk foreign key (organization_id, reversal_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`
- `constraint journal_entries_reversed_audit_chk check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null))`
- `constraint journal_entries_posted_timestamp_chk check ((status in ('posted', 'reversed') and posted_at is not null) or status in ('draft', 'confirmed', 'void'))`
- `constraint journal_entries_confirmed_timestamp_chk check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null))`
- `constraint journal_entries_void_timestamp_chk check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))`

**Indexes:**

- `create index journal_entries_org_date_idx on public.journal_entries (organization_id, entry_date desc);`
- `create index journal_entries_org_status_idx on public.journal_entries (organization_id, status);`
- `create unique index journal_entries_one_reversal_per_entry_uq on public.journal_entries (organization_id, reversal_of_id) where reversal_of_id is not null;`
- `create unique index journal_entries_one_org_opening_balance_uq on public.journal_entries (organization_id) where entry_type = 'opening_balance' and reference_type = 'organization_opening_balance';`
- `create unique index journal_entries_payment_reference_uq on public.journal_entries (organization_id, reference_type, reference_id) where entry_type = 'payment' and reference_type = 'payment' and reference_id is not null;`
- `create unique index journal_entries_sales_reference_uq on public.journal_entries (organization_id, reference_type, reference_id) where entry_type = 'sale' and reference_type = 'sale' and reference_id is not null;`

**Triggers:**

```sql
create trigger journal_entries_set_updated_at before update on public.journal_entries for each row execute function public.set_updated_at();
```

```sql
create trigger journal_entries_assign_document_number before insert or update of entry_number on public.journal_entries for each row execute function public.assign_document_number();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy journal_entries_select_member on public.journal_entries for select to authenticated using (public.has_org_permission(organization_id, 'journal_entries.read'));
```

### `public.account_transactions`

**Purpose:** Debit/credit journal lines, account/contact references and one-sided amount validation.

**Columns (10):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `journal_entry_id` | `uuid not null` |
| `account_id` | `uuid not null` |
| `line_number` | `integer not null check (line_number > 0)` |
| `description` | `text` |
| `debit` | `numeric(20, 4) not null default 0 check (debit >= 0)` |
| `credit` | `numeric(20, 4) not null default 0 check (credit >= 0)` |
| `contact_id` | `uuid` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (6):**

- `constraint account_transactions_org_id_id_uq unique (organization_id, id)`
- `constraint account_transactions_line_uq unique (organization_id, journal_entry_id, line_number)`
- `constraint account_transactions_journal_same_org_fk foreign key (organization_id, journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`
- `constraint account_transactions_account_same_org_fk foreign key (organization_id, account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint account_transactions_contact_same_org_fk foreign key (organization_id, contact_id) references public.contacts (organization_id, id) on delete restrict`
- `constraint account_transactions_one_side_chk check ( (debit > 0 and credit = 0) or (credit > 0 and debit = 0) )`

**Indexes:**

- `create index account_transactions_account_idx on public.account_transactions (organization_id, account_id);`
- `create index account_transactions_org_account_contact_idx on public.account_transactions (organization_id, account_id, contact_id) where contact_id is not null;`

**Triggers:**

- No trigger declared for this table.

**RLS:** Enabled.

**Policies:**

```sql
create policy account_transactions_select_member on public.account_transactions for select to authenticated using (public.has_org_permission(organization_id, 'journal_entries.read'));
```

### `public.inventory_transactions`

**Purpose:** Append-style stock movement/cost history with transaction and polymorphic source reference fields.

**Columns (16):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `transaction_number` | `text not null check (pg_catalog.length(pg_catalog.btrim(transaction_number)) between 1 and 80)` |
| `product_id` | `uuid not null` |
| `transaction_date` | `date not null` |
| `transaction_type` | `text not null check (transaction_type in ('purchase', 'sale', 'purchase_return', 'sales_return', 'adjustment', 'opening_balance'))` |
| `direction` | `text not null check (direction in ('in', 'out'))` |
| `quantity` | `numeric(20, 6) not null check (quantity > 0)` |
| `unit_cost` | `numeric(20, 6) not null default 0 check (unit_cost >= 0)` |
| `total_value` | `numeric(20, 4) not null default 0 check (total_value >= 0)` |
| `reference_type` | `text` |
| `reference_id` | `uuid` |
| `unit_cost_before` | `numeric(20, 6) check (unit_cost_before is null or unit_cost_before >= 0)` |
| `average_cost_after` | `numeric(20, 6) check (average_cost_after is null or average_cost_after >= 0)` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (3):**

- `constraint inventory_transactions_org_id_id_uq unique (organization_id, id)`
- `constraint inventory_transactions_org_number_uq unique (organization_id, transaction_number)`
- `constraint inventory_transactions_product_same_org_fk foreign key (organization_id, product_id) references public.products (organization_id, id) on delete restrict`

**Indexes:**

- `create index inventory_transactions_product_date_idx on public.inventory_transactions (organization_id, product_id, transaction_date desc);`

**Triggers:**

- No trigger declared for this table.

**RLS:** Enabled.

**Policies:**

```sql
create policy inventory_transactions_select_member on public.inventory_transactions for select to authenticated using (public.has_org_permission(organization_id, 'inventory.read'));
```

### `public.inventory_balances`

**Purpose:** Current per-product stock quantity, average cost and inventory value snapshot.

**Columns (7):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `product_id` | `uuid not null` |
| `quantity` | `numeric(20, 6) not null default 0 check (quantity >= 0)` |
| `average_cost` | `numeric(20, 6) not null default 0 check (average_cost >= 0)` |
| `inventory_value` | `numeric(20, 4) not null default 0 check (inventory_value >= 0)` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (3):**

- `constraint inventory_balances_org_id_id_uq unique (organization_id, id)`
- `constraint inventory_balances_product_uq unique (organization_id, product_id)`
- `constraint inventory_balances_product_same_org_fk foreign key (organization_id, product_id) references public.products (organization_id, id) on delete restrict`

**Indexes:**

- No explicit index created directly on this table beyond primary/unique constraints.

**Triggers:**

- No trigger declared for this table.

**RLS:** Enabled.

**Policies:**

```sql
create policy inventory_balances_select_member on public.inventory_balances for select to authenticated using (public.has_org_permission(organization_id, 'inventory.read'));
```

### `public.purchase`

**Purpose:** Purchase invoice header, supplier, totals, status lifecycle and ledger linkage.

**Columns (20):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `invoice_id` | `text not null check (pg_catalog.length(pg_catalog.btrim(invoice_id)) between 1 and 80)` |
| `supplier_id` | `uuid not null` |
| `invoice_date` | `date not null` |
| `status` | `text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'partially_returned', 'returned', 'void'))` |
| `confirmed_at` | `timestamptz` |
| `confirmed_by` | `uuid references auth.users(id) on delete set null` |
| `posted_by` | `uuid references auth.users(id) on delete set null` |
| `voided_at` | `timestamptz` |
| `voided_by` | `uuid references auth.users(id) on delete set null` |
| `void_reason` | `text` |
| `subtotal` | `numeric(20, 4) not null default 0 check (subtotal >= 0)` |
| `discount_amount` | `numeric(20, 4) not null default 0 check (discount_amount >= 0)` |
| `total_amount` | `numeric(20, 4) not null default 0 check (total_amount >= 0)` |
| `payable_account_id` | `uuid not null` |
| `posted_journal_entry_id` | `uuid` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (8):**

- `constraint purchase_org_id_id_uq unique (organization_id, id)`
- `constraint purchase_org_invoice_uq unique (organization_id, invoice_id)`
- `constraint purchase_supplier_same_org_fk foreign key (organization_id, supplier_id) references public.contacts (organization_id, id) on delete restrict`
- `constraint purchase_payable_account_same_org_fk foreign key (organization_id, payable_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint purchase_discount_limit_chk check (discount_amount <= subtotal)`
- `constraint purchase_confirmed_timestamp_chk check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null))`
- `constraint purchase_void_timestamp_chk check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))`
- `alter table public.purchase add constraint purchase_posted_journal_same_org_fk foreign key (organization_id, posted_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`

**Indexes:**

- `create index purchase_supplier_date_idx on public.purchase (organization_id, supplier_id, invoice_date desc);`

**Triggers:**

```sql
create trigger purchase_set_updated_at before update on public.purchase for each row execute function public.set_updated_at();
```

```sql
create trigger purchase_assign_document_number before insert or update of invoice_id on public.purchase for each row execute function public.assign_document_number();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy purchase_select_member on public.purchase for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

### `public.purchase_items`

**Purpose:** Purchase invoice product lines and quantities/costs.

**Columns (10):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `purchase_id` | `uuid not null` |
| `line_number` | `integer not null check (line_number > 0)` |
| `product_id` | `uuid not null` |
| `quantity` | `numeric(20, 6) not null check (quantity > 0)` |
| `unit_cost` | `numeric(20, 6) not null check (unit_cost >= 0)` |
| `line_total` | `numeric(20, 4) not null check (line_total >= 0)` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (4):**

- `constraint purchase_items_org_id_id_uq unique (organization_id, id)`
- `constraint purchase_items_line_uq unique (organization_id, purchase_id, line_number)`
- `constraint purchase_items_purchase_same_org_fk foreign key (organization_id, purchase_id) references public.purchase (organization_id, id) on delete restrict`
- `constraint purchase_items_product_same_org_fk foreign key (organization_id, product_id) references public.products (organization_id, id) on delete restrict`

**Indexes:**

- `create index purchase_items_product_idx on public.purchase_items (organization_id, product_id);`

**Triggers:**

```sql
create trigger purchase_items_set_updated_at before update on public.purchase_items for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy purchase_items_select_member on public.purchase_items for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

### `public.purchase_returns`

**Purpose:** Purchase return header, source purchase/supplier, values, status, variance account and journal/reversal links.

**Columns (26):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `return_number` | `text not null check (pg_catalog.length(pg_catalog.btrim(return_number)) between 1 and 80)` |
| `purchase_id` | `uuid not null` |
| `supplier_id` | `uuid not null` |
| `return_date` | `date not null` |
| `status` | `text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed'))` |
| `confirmed_at` | `timestamptz` |
| `confirmed_by` | `uuid references auth.users(id) on delete set null` |
| `posted_by` | `uuid references auth.users(id) on delete set null` |
| `voided_at` | `timestamptz` |
| `voided_by` | `uuid references auth.users(id) on delete set null` |
| `void_reason` | `text` |
| `subtotal` | `numeric(20, 4) not null default 0 check (subtotal >= 0)` |
| `discount_amount` | `numeric(20, 4) not null default 0 check (discount_amount >= 0)` |
| `total_amount` | `numeric(20, 4) not null default 0 check (total_amount >= 0)` |
| `payable_account_id` | `uuid not null` |
| `purchase_return_variance_account_id` | `uuid` |
| `posted_journal_entry_id` | `uuid` |
| `reversal_journal_entry_id` | `uuid` |
| `reversed_at` | `timestamptz` |
| `reversed_by` | `uuid references auth.users(id) on delete set null` |
| `reversal_reason` | `text` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (12):**

- `constraint purchase_returns_org_id_id_uq unique (organization_id, id)`
- `constraint purchase_returns_org_number_uq unique (organization_id, return_number)`
- `constraint purchase_returns_purchase_same_org_fk foreign key (organization_id, purchase_id) references public.purchase (organization_id, id) on delete restrict`
- `constraint purchase_returns_supplier_same_org_fk foreign key (organization_id, supplier_id) references public.contacts (organization_id, id) on delete restrict`
- `constraint purchase_returns_account_same_org_fk foreign key (organization_id, payable_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint purchase_returns_variance_account_same_org_fk foreign key (organization_id, purchase_return_variance_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint purchase_returns_discount_limit_chk check (discount_amount <= subtotal)`
- `constraint purchase_returns_reversal_entry_same_org_fk foreign key (organization_id, reversal_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`
- `constraint purchase_returns_reversed_audit_chk check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null))`
- `constraint purchase_returns_confirmed_timestamp_chk check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null))`
- `constraint purchase_returns_void_timestamp_chk check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))`
- `alter table public.purchase_returns add constraint purchase_returns_posted_journal_same_org_fk foreign key (organization_id, posted_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`

**Indexes:**

- `create index purchase_returns_purchase_idx on public.purchase_returns (organization_id, purchase_id);`

**Triggers:**

```sql
create trigger purchase_returns_set_updated_at before update on public.purchase_returns for each row execute function public.set_updated_at();
```

```sql
create trigger purchase_returns_assign_document_number before insert or update of return_number on public.purchase_returns for each row execute function public.assign_document_number();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy purchase_returns_select_member on public.purchase_returns for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

### `public.purchase_return_items`

**Purpose:** Purchase return lines linked to original purchase items and products.

**Columns (11):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `purchase_return_id` | `uuid not null` |
| `line_number` | `integer not null check (line_number > 0)` |
| `purchase_item_id` | `uuid not null` |
| `product_id` | `uuid not null` |
| `quantity` | `numeric(20, 6) not null check (quantity > 0)` |
| `unit_cost` | `numeric(20, 6) not null check (unit_cost >= 0)` |
| `line_total` | `numeric(20, 4) not null check (line_total >= 0)` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (6):**

- `constraint purchase_return_items_org_id_id_uq unique (organization_id, id)`
- `constraint purchase_return_items_line_uq unique (organization_id, purchase_return_id, line_number)`
- `constraint purchase_return_items_source_item_uq unique (organization_id, purchase_return_id, purchase_item_id)`
- `constraint purchase_return_items_return_same_org_fk foreign key (organization_id, purchase_return_id) references public.purchase_returns (organization_id, id) on delete restrict`
- `constraint purchase_return_items_purchase_item_same_org_fk foreign key (organization_id, purchase_item_id) references public.purchase_items (organization_id, id) on delete restrict`
- `constraint purchase_return_items_product_same_org_fk foreign key (organization_id, product_id) references public.products (organization_id, id) on delete restrict`

**Indexes:**

- `create index purchase_return_items_source_idx on public.purchase_return_items (organization_id, purchase_item_id);`

**Triggers:**

```sql
create trigger purchase_return_items_set_updated_at before update on public.purchase_return_items for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy purchase_return_items_select_member on public.purchase_return_items for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

### `public.sales`

**Purpose:** Sales invoice header, customer, totals, status lifecycle and receivable/journal links.

**Columns (20):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `invoice_id` | `text not null check (pg_catalog.length(pg_catalog.btrim(invoice_id)) between 1 and 80)` |
| `customer_id` | `uuid not null` |
| `invoice_date` | `date not null` |
| `status` | `text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'partially_returned', 'returned', 'void'))` |
| `confirmed_at` | `timestamptz` |
| `confirmed_by` | `uuid references auth.users(id) on delete set null` |
| `posted_by` | `uuid references auth.users(id) on delete set null` |
| `voided_at` | `timestamptz` |
| `voided_by` | `uuid references auth.users(id) on delete set null` |
| `void_reason` | `text` |
| `subtotal` | `numeric(20, 4) not null default 0 check (subtotal >= 0)` |
| `discount_amount` | `numeric(20, 4) not null default 0 check (discount_amount >= 0)` |
| `total_amount` | `numeric(20, 4) not null default 0 check (total_amount >= 0)` |
| `receivable_account_id` | `uuid not null` |
| `posted_journal_entry_id` | `uuid` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (8):**

- `constraint sales_org_id_id_uq unique (organization_id, id)`
- `constraint sales_org_invoice_uq unique (organization_id, invoice_id)`
- `constraint sales_customer_same_org_fk foreign key (organization_id, customer_id) references public.contacts (organization_id, id) on delete restrict`
- `constraint sales_receivable_account_same_org_fk foreign key (organization_id, receivable_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint sales_discount_limit_chk check (discount_amount <= subtotal)`
- `constraint sales_confirmed_timestamp_chk check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null))`
- `constraint sales_void_timestamp_chk check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))`
- `alter table public.sales add constraint sales_posted_journal_same_org_fk foreign key (organization_id, posted_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`

**Indexes:**

- `create index sales_customer_date_idx on public.sales (organization_id, customer_id, invoice_date desc);`

**Triggers:**

```sql
create trigger sales_set_updated_at before update on public.sales for each row execute function public.set_updated_at();
```

```sql
create trigger sales_assign_document_number before insert or update of invoice_id on public.sales for each row execute function public.assign_document_number();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy sales_select_member on public.sales for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

### `public.sales_items`

**Purpose:** Sales invoice product lines, selling price and captured COGS.

**Columns (12):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `sales_id` | `uuid not null` |
| `line_number` | `integer not null check (line_number > 0)` |
| `product_id` | `uuid not null` |
| `quantity` | `numeric(20, 6) not null check (quantity > 0)` |
| `unit_price` | `numeric(20, 6) not null check (unit_price >= 0)` |
| `line_total` | `numeric(20, 4) not null check (line_total >= 0)` |
| `cogs_unit_cost` | `numeric(20, 6) not null default 0 check (cogs_unit_cost >= 0)` |
| `cogs_total` | `numeric(20, 4) not null default 0 check (cogs_total >= 0)` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (4):**

- `constraint sales_items_org_id_id_uq unique (organization_id, id)`
- `constraint sales_items_line_uq unique (organization_id, sales_id, line_number)`
- `constraint sales_items_sales_same_org_fk foreign key (organization_id, sales_id) references public.sales (organization_id, id) on delete restrict`
- `constraint sales_items_product_same_org_fk foreign key (organization_id, product_id) references public.products (organization_id, id) on delete restrict`

**Indexes:**

- `create index sales_items_product_idx on public.sales_items (organization_id, product_id);`

**Triggers:**

```sql
create trigger sales_items_set_updated_at before update on public.sales_items for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy sales_items_select_member on public.sales_items for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

### `public.sales_returns`

**Purpose:** Sales return header, source sale/customer, values, status and journal/reversal links.

**Columns (25):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `return_number` | `text not null check (pg_catalog.length(pg_catalog.btrim(return_number)) between 1 and 80)` |
| `sales_id` | `uuid not null` |
| `customer_id` | `uuid not null` |
| `return_date` | `date not null` |
| `status` | `text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed'))` |
| `confirmed_at` | `timestamptz` |
| `confirmed_by` | `uuid references auth.users(id) on delete set null` |
| `posted_by` | `uuid references auth.users(id) on delete set null` |
| `voided_at` | `timestamptz` |
| `voided_by` | `uuid references auth.users(id) on delete set null` |
| `void_reason` | `text` |
| `subtotal` | `numeric(20, 4) not null default 0 check (subtotal >= 0)` |
| `discount_amount` | `numeric(20, 4) not null default 0 check (discount_amount >= 0)` |
| `total_amount` | `numeric(20, 4) not null default 0 check (total_amount >= 0)` |
| `receivable_account_id` | `uuid not null` |
| `posted_journal_entry_id` | `uuid` |
| `reversal_journal_entry_id` | `uuid` |
| `reversed_at` | `timestamptz` |
| `reversed_by` | `uuid references auth.users(id) on delete set null` |
| `reversal_reason` | `text` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (11):**

- `constraint sales_returns_org_id_id_uq unique (organization_id, id)`
- `constraint sales_returns_org_number_uq unique (organization_id, return_number)`
- `constraint sales_returns_sales_same_org_fk foreign key (organization_id, sales_id) references public.sales (organization_id, id) on delete restrict`
- `constraint sales_returns_customer_same_org_fk foreign key (organization_id, customer_id) references public.contacts (organization_id, id) on delete restrict`
- `constraint sales_returns_account_same_org_fk foreign key (organization_id, receivable_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint sales_returns_discount_limit_chk check (discount_amount <= subtotal)`
- `constraint sales_returns_reversal_entry_same_org_fk foreign key (organization_id, reversal_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`
- `constraint sales_returns_reversed_audit_chk check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null))`
- `constraint sales_returns_confirmed_timestamp_chk check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null))`
- `constraint sales_returns_void_timestamp_chk check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))`
- `alter table public.sales_returns add constraint sales_returns_posted_journal_same_org_fk foreign key (organization_id, posted_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`

**Indexes:**

- `create index sales_returns_sales_idx on public.sales_returns (organization_id, sales_id);`

**Triggers:**

```sql
create trigger sales_returns_set_updated_at before update on public.sales_returns for each row execute function public.set_updated_at();
```

```sql
create trigger sales_returns_assign_document_number before insert or update of return_number on public.sales_returns for each row execute function public.assign_document_number();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy sales_returns_select_member on public.sales_returns for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

### `public.sales_return_items`

**Purpose:** Sales return lines linked to original sales items and products, including captured COGS.

**Columns (13):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `sales_return_id` | `uuid not null` |
| `line_number` | `integer not null check (line_number > 0)` |
| `sales_item_id` | `uuid not null` |
| `product_id` | `uuid not null` |
| `quantity` | `numeric(20, 6) not null check (quantity > 0)` |
| `unit_price` | `numeric(20, 6) not null check (unit_price >= 0)` |
| `line_total` | `numeric(20, 4) not null check (line_total >= 0)` |
| `cogs_unit_cost` | `numeric(20, 6) not null default 0 check (cogs_unit_cost >= 0)` |
| `cogs_total` | `numeric(20, 4) not null default 0 check (cogs_total >= 0)` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (6):**

- `constraint sales_return_items_org_id_id_uq unique (organization_id, id)`
- `constraint sales_return_items_line_uq unique (organization_id, sales_return_id, line_number)`
- `constraint sales_return_items_source_item_uq unique (organization_id, sales_return_id, sales_item_id)`
- `constraint sales_return_items_return_same_org_fk foreign key (organization_id, sales_return_id) references public.sales_returns (organization_id, id) on delete restrict`
- `constraint sales_return_items_sales_item_same_org_fk foreign key (organization_id, sales_item_id) references public.sales_items (organization_id, id) on delete restrict`
- `constraint sales_return_items_product_same_org_fk foreign key (organization_id, product_id) references public.products (organization_id, id) on delete restrict`

**Indexes:**

- `create index sales_return_items_source_idx on public.sales_return_items (organization_id, sales_item_id);`

**Triggers:**

```sql
create trigger sales_return_items_set_updated_at before update on public.sales_return_items for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy sales_return_items_select_member on public.sales_return_items for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

### `public.expenses`

**Purpose:** Expense document header, category/contact/accounts, amount, status and journal/reversal audit.

**Columns (24):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `expense_number` | `text not null check (pg_catalog.length(pg_catalog.btrim(expense_number)) between 1 and 80)` |
| `expense_category_id` | `uuid not null` |
| `contact_id` | `uuid` |
| `payable_account_id` | `uuid` |
| `expense_date` | `date not null` |
| `amount` | `numeric(20, 4) not null check (amount > 0)` |
| `description` | `text` |
| `status` | `text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed'))` |
| `confirmed_at` | `timestamptz` |
| `confirmed_by` | `uuid references auth.users(id) on delete set null` |
| `posted_by` | `uuid references auth.users(id) on delete set null` |
| `voided_at` | `timestamptz` |
| `voided_by` | `uuid references auth.users(id) on delete set null` |
| `void_reason` | `text` |
| `posted_journal_entry_id` | `uuid` |
| `reversal_journal_entry_id` | `uuid` |
| `reversed_at` | `timestamptz` |
| `reversed_by` | `uuid references auth.users(id) on delete set null` |
| `reversal_reason` | `text` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (10):**

- `constraint expenses_org_id_id_uq unique (organization_id, id)`
- `constraint expenses_org_number_uq unique (organization_id, expense_number)`
- `constraint expenses_category_same_org_fk foreign key (organization_id, expense_category_id) references public.expense_categories (organization_id, id) on delete restrict`
- `constraint expenses_contact_same_org_fk foreign key (organization_id, contact_id) references public.contacts (organization_id, id) on delete restrict`
- `constraint expenses_account_same_org_fk foreign key (organization_id, payable_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint expenses_reversal_entry_same_org_fk foreign key (organization_id, reversal_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`
- `constraint expenses_reversed_audit_chk check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null))`
- `constraint expenses_confirmed_timestamp_chk check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null))`
- `constraint expenses_void_timestamp_chk check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))`
- `alter table public.expenses add constraint expenses_posted_journal_same_org_fk foreign key (organization_id, posted_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`

**Indexes:**

- `create index expenses_org_date_idx on public.expenses (organization_id, expense_date desc);`

**Triggers:**

```sql
create trigger expenses_set_updated_at before update on public.expenses for each row execute function public.set_updated_at();
```

```sql
create trigger expenses_assign_document_number before insert or update of expense_number on public.expenses for each row execute function public.assign_document_number();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy expenses_select_member on public.expenses for select to authenticated using (public.has_org_permission(organization_id, 'expenses.read'));
```

### `public.payments`

**Purpose:** Receipt/payment/transfer/refund document header, contact/accounts, amount, status and journal/reversal audit.

**Columns (25):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `payment_number` | `text not null check (pg_catalog.length(pg_catalog.btrim(payment_number)) between 1 and 80)` |
| `payment_type` | `text not null check (payment_type in ('receipt', 'payment', 'transfer', 'refund'))` |
| `contact_id` | `uuid` |
| `payment_date` | `date not null` |
| `amount` | `numeric(20, 4) not null check (amount > 0)` |
| `account_id` | `uuid not null` |
| `settlement_account_id` | `uuid` |
| `status` | `text not null default 'draft' check (status in ('draft', 'confirmed', 'posted', 'void', 'reversed'))` |
| `confirmed_at` | `timestamptz` |
| `confirmed_by` | `uuid references auth.users(id) on delete set null` |
| `posted_by` | `uuid references auth.users(id) on delete set null` |
| `voided_at` | `timestamptz` |
| `voided_by` | `uuid references auth.users(id) on delete set null` |
| `void_reason` | `text` |
| `posted_journal_entry_id` | `uuid` |
| `reversal_journal_entry_id` | `uuid` |
| `reversed_at` | `timestamptz` |
| `reversed_by` | `uuid references auth.users(id) on delete set null` |
| `reversal_reason` | `text` |
| `description` | `text` |
| `created_by` | `uuid references auth.users(id) on delete set null` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (10):**

- `constraint payments_org_id_id_uq unique (organization_id, id)`
- `constraint payments_org_number_uq unique (organization_id, payment_number)`
- `constraint payments_contact_same_org_fk foreign key (organization_id, contact_id) references public.contacts (organization_id, id) on delete restrict`
- `constraint payments_account_same_org_fk foreign key (organization_id, account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint payments_settlement_account_same_org_fk foreign key (organization_id, settlement_account_id) references public.accounts (organization_id, id) on delete restrict`
- `constraint payments_reversal_entry_same_org_fk foreign key (organization_id, reversal_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`
- `constraint payments_reversed_audit_chk check (status <> 'reversed' or (reversal_journal_entry_id is not null and reversed_at is not null and reversed_by is not null and nullif(pg_catalog.btrim(reversal_reason), '') is not null))`
- `constraint payments_confirmed_timestamp_chk check (status <> 'confirmed' or (confirmed_at is not null and confirmed_by is not null))`
- `constraint payments_void_timestamp_chk check (status <> 'void' or (voided_at is not null and voided_by is not null and nullif(pg_catalog.btrim(void_reason), '') is not null))`
- `alter table public.payments add constraint payments_posted_journal_same_org_fk foreign key (organization_id, posted_journal_entry_id) references public.journal_entries (organization_id, id) on delete restrict`

**Indexes:**

- `create index payments_org_date_idx on public.payments (organization_id, payment_date desc);`

**Triggers:**

```sql
create trigger payments_set_updated_at before update on public.payments for each row execute function public.set_updated_at();
```

```sql
create trigger payments_assign_document_number before insert or update of payment_number on public.payments for each row execute function public.assign_document_number();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy payments_select_member on public.payments for select to authenticated using (public.has_org_permission(organization_id, 'payments.read'));
```

### `public.payment_allocations`

**Purpose:** Payment-to-document allocation rows. document_id is polymorphic and does not have a conventional FK to each supported document table.

**Columns (8):**

| Column | Exact SQL definition |
|---|---|
| `id` | `uuid primary key default pg_catalog.gen_random_uuid()` |
| `organization_id` | `uuid not null references public.organizations(id) on delete restrict` |
| `payment_id` | `uuid not null` |
| `document_type` | `text not null check (document_type in ('purchase', 'purchase_return', 'sales', 'sales_return', 'expense'))` |
| `document_id` | `uuid not null` |
| `allocated_amount` | `numeric(20, 4) not null check (allocated_amount > 0)` |
| `created_at` | `timestamptz not null default pg_catalog.now()` |
| `updated_at` | `timestamptz not null default pg_catalog.now()` |

**Constraints (3):**

- `constraint payment_allocations_org_id_id_uq unique (organization_id, id)`
- `constraint payment_allocations_payment_document_uq unique (organization_id, payment_id, document_type, document_id)`
- `constraint payment_allocations_payment_same_org_fk foreign key (organization_id, payment_id) references public.payments (organization_id, id) on delete restrict`

**Indexes:**

- `create index payment_allocations_document_idx on public.payment_allocations (organization_id, document_type, document_id);`

**Triggers:**

```sql
create trigger payment_allocations_set_updated_at before update on public.payment_allocations for each row execute function public.set_updated_at();
```

**RLS:** Enabled.

**Policies:**

```sql
create policy payment_allocations_select_member on public.payment_allocations for select to authenticated using (public.has_org_permission(organization_id, 'payments.read'));
```

## Global permission catalog

The bootstrap upserts these 43 permission rows into `public.permissions`. The exact permission key is what the RPC authorization checks use.

| Permission key | Display name | Module | Description |
|---|---|---|---|
| `organization.read` | View organization | `organization` | View organization profile and settings. |
| `organization.update` | Update organization | `organization` | Update organization profile and settings. |
| `users.read` | View members | `users` | View organization memberships. |
| `users.manage` | Manage members | `users` | Add existing verified users, deactivate members, and assign organization roles. |
| `roles.read` | View roles | `roles` | View organization roles and their permissions. |
| `roles.manage` | Manage roles | `roles` | Create and update organization-specific custom roles. |
| `opening_balances.post` | Post opening balances | `accounting` | Post an organization's one-time general ledger, party, and inventory opening balances. |
| `accounts.read` | View chart of accounts | `accounting` | View accounts and account hierarchy. |
| `accounts.manage` | Manage chart of accounts | `accounting` | Create and update chart of accounts. |
| `journal_entries.read` | View journal entries | `accounting` | View journal entries and lines. |
| `journal_entries.create` | Create journal entries | `accounting` | Create draft journal entries. |
| `journal_entries.confirm` | Confirm journal entries | `accounting` | Confirm balanced draft journal entries before posting. |
| `journal_entries.post` | Post journal entries | `accounting` | Post balanced journal entries. |
| `journal_entries.reverse` | Reverse journal entries | `accounting` | Create controlled reversals of posted entries. |
| `contacts.read` | View contacts | `contacts` | View customers, suppliers, and other contacts. |
| `contacts.manage` | Manage contacts | `contacts` | Create and update contacts. |
| `products.read` | View products | `inventory` | View products and units. |
| `products.manage` | Manage products | `inventory` | Create and update products and account mappings. |
| `inventory.read` | View inventory | `inventory` | View stock balances and movements. |
| `inventory.adjust` | Adjust inventory | `inventory` | Post authorized inventory adjustments. |
| `purchases.read` | View purchases | `purchases` | View purchase invoices and returns. |
| `purchases.create` | Create purchases | `purchases` | Create and update draft purchase documents. |
| `purchases.confirm` | Confirm purchases | `purchases` | Confirm purchase documents before posting. |
| `purchases.post` | Post purchases | `purchases` | Post purchases and related stock/accounting effects. |
| `purchases.returns.create` | Create purchase returns | `purchases` | Create and update draft purchase return documents. |
| `purchases.returns.post` | Post purchase returns | `purchases` | Post purchase returns. |
| `purchases.returns.confirm` | Confirm purchase returns | `purchases` | Confirm purchase return documents before posting. |
| `sales.read` | View sales | `sales` | View sales invoices and returns. |
| `sales.create` | Create sales | `sales` | Create and update draft sales documents. |
| `sales.confirm` | Confirm sales | `sales` | Confirm sales invoices before posting. |
| `sales.post` | Post sales | `sales` | Post sales and related stock/accounting effects. |
| `sales.returns.create` | Create sales returns | `sales` | Create and update draft sales return documents. |
| `sales.returns.post` | Post sales returns | `sales` | Post sales returns. |
| `sales.returns.confirm` | Confirm sales returns | `sales` | Confirm sales return documents before posting. |
| `expenses.read` | View expenses | `expenses` | View expense records. |
| `expenses.manage` | Manage expenses | `expenses` | Create and update draft expenses. |
| `expenses.confirm` | Confirm expenses | `expenses` | Confirm expense documents before posting. |
| `expenses.post` | Post expenses | `expenses` | Post expenses to the ledger. |
| `payments.read` | View payments | `payments` | View payments and allocations. |
| `payments.manage` | Manage payments | `payments` | Create payments and manage draft allocations. |
| `payments.confirm` | Confirm payments | `payments` | Confirm payments and receipts before posting. |
| `payments.post` | Post payments | `payments` | Post payments and allocation effects. |
| `reports.read` | View reports | `reports` | View organization financial and operational reports. |

## Function and RPC reference

The list below is the effective final function set after migration overrides and the transfer-function drop. Trigger-returning functions are database trigger handlers, not application RPCs. Functions with EXECUTE granted to `authenticated` are callable by authenticated database clients subject to their own authorization checks. SECURITY DEFINER functions pin `search_path = ''` in the SQL definition.

| Function | Parameters | Returns | Kind | SECURITY DEFINER | EXECUTE exposure | Defined/last replaced by | Purpose |
|---|---|---|---|---|---|---|---|
| `public.set_updated_at` | `—` | `trigger` | Trigger function | No | Trigger-only | `20261103000000_initial_database_schema.sql` | BEFORE UPDATE trigger helper that sets updated_at to the current transaction timestamp. |
| `public.prevent_account_hierarchy_cycle` | `—` | `trigger` | Trigger function | Yes | Trigger-only | `20261103000000_initial_database_schema.sql` | Rejects account parent changes that would create a hierarchy cycle. |
| `public.is_active_org_member` | `p_organization_id uuid` | `boolean` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns whether the current auth.uid() has an active membership in the specified organization. |
| `public.has_org_permission` | `p_organization_id uuid, p_permission_key text` | `boolean` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Checks active organization, active membership, active role and the requested permission key. |
| `public.next_document_number` | `p_organization_id uuid, p_document_type text` | `text` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Atomically allocates the next formatted number from the organization's active number_sequences row after permission validation. |
| `public.create_organization_with_admin` | `p_name text, p_currency text default 'BDT', p_timezone text default 'Asia/Dhaka'` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103020000_permanent_organization_administrator.sql` | Atomically creates an organization, its system Administrator role, role-permission assignments, the authenticated creator's permanent membership, and the default chart of accounts. |
| `public.guard_system_role_mutation` | `—` | `trigger` | Trigger function | No | Trigger-only | `20261103000000_initial_database_schema.sql` | Rejects protected system-role mutation through the roles table. |
| `public.guard_administrator_membership` | `—` | `trigger` | Trigger function | Yes | Trigger-only | `20261103020000_permanent_organization_administrator.sql` | Membership trigger that prevents Administrator membership changes, reassignment, deactivation or deletion; final implementation allows initial creator bootstrap only. |
| `public.guard_system_role_permissions` | `—` | `trigger` | Trigger function | Yes | Trigger-only | `20261103000000_initial_database_schema.sql` | Protects the system role's permission assignments from unauthorized changes. |
| `public.add_organization_user_by_email` | `p_organization_id uuid, p_email text, p_role_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Adds an existing email-verified Supabase Auth user to the organization with an active organization role. |
| `public.update_organization_user_role` | `p_organization_id uuid, p_membership_id uuid, p_role_id uuid` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Changes an ordinary membership's assigned role after organization/permission validation; creator membership is protected by triggers. |
| `public.set_organization_user_active` | `p_organization_id uuid, p_membership_id uuid, p_is_active boolean` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Activates/deactivates an ordinary membership subject to role and creator protections. |
| `public.post_manual_journal_entry` | `p_organization_id uuid, p_entry_number text, p_entry_date date, p_description text, p_lines jsonb` | `uuid` | Internal/helper function | Yes | No explicit authenticated EXECUTE grant, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Legacy one-step manual journal posting function; EXECUTE is revoked from client roles. Use the draft/confirm/post workflow. |
| `public.post_purchase` | `p_organization_id uuid, p_purchase_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts a confirmed purchase and its ledger/inventory effects atomically. |
| `public.post_opening_balances` | `p_organization_id uuid, p_entry_date date, p_account_lines jsonb, p_party_balances jsonb, p_inventory_lines jsonb, p_description text default 'Opening balances'` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts one-time opening general-ledger, party receivable/payable, and inventory balances. |
| `public.post_contact_payment` | `p_organization_id uuid, p_payment_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts a contact-level receipt/payment/refund/transfer settlement and its ledger effects. |
| `public.post_sales` | `p_organization_id uuid, p_sales_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts a confirmed sales document with ledger and inventory effects. |
| `public.reverse_journal_entry` | `p_organization_id uuid, p_journal_entry_id uuid, p_reversal_date date, p_reason text` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Creates a controlled reversal of a posted journal entry with audit metadata. |
| `public.post_expense` | `p_organization_id uuid, p_expense_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts a confirmed expense and corresponding journal entry. |
| `public.post_purchase_return` | `p_organization_id uuid, p_purchase_return_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts a confirmed purchase return and corresponding stock/ledger effects. |
| `public.post_sales_return` | `p_organization_id uuid, p_sales_return_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts a confirmed sales return and corresponding stock/ledger effects. |
| `public.post_confirmed_journal_entry` | `p_organization_id uuid, p_journal_entry_id uuid` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts a confirmed manual journal entry. |
| `public.save_draft_transaction_document` | `p_organization_id uuid, p_document_type text, p_header jsonb, p_items jsonb default null, p_document_id uuid default null` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Creates or updates a supported draft purchase, sale, return, expense, payment or journal document using JSONB header/items. |
| `public.confirm_transaction_document` | `p_organization_id uuid, p_document_type text, p_document_id uuid` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Validates and confirms a supported draft transaction document without posting ledger/inventory effects. |
| `public.revert_transaction_document_to_draft` | `p_organization_id uuid, p_document_type text, p_document_id uuid` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Reverts an eligible confirmed transaction document to draft. |
| `public.void_transaction_document` | `p_organization_id uuid, p_document_type text, p_document_id uuid, p_reason text` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Voids an eligible draft/confirmed transaction document with a required reason. |
| `public.delete_draft_transaction_document` | `p_organization_id uuid, p_document_type text, p_document_id uuid` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Deletes an eligible draft transaction document. |
| `public.seed_default_chart_of_accounts` | `p_organization_id uuid` | `void` | Internal/helper function | Yes | No explicit authenticated EXECUTE grant, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Seeds the organization's default chart of accounts; invoked by the organization-creation RPC. |
| `public.assign_document_number` | `—` | `trigger` | Trigger function | Yes | Trigger-only | `20261103000000_initial_database_schema.sql` | BEFORE INSERT trigger that assigns document numbers for configured document tables. |
| `public.update_organization_profile` | `p_organization_id uuid, p_name text, p_phone text, p_email text, p_address text, p_city text, p_country text, p_currency text, p_timezone text, p_tin text, p_bin text` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Updates organization profile fields after organization.update authorization and validates currency/timezone values. |
| `public.save_master_data` | `p_organization_id uuid, p_entity_type text, p_data jsonb, p_record_id uuid default null` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Permission-checked create/update routine for supported master-data entity types, using JSONB payloads. |
| `public.create_custom_role` | `p_organization_id uuid, p_name text, p_permission_keys text[]` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Creates an organization-scoped custom role with validated permission keys. |
| `public.replace_custom_role_permissions` | `p_organization_id uuid, p_role_id uuid, p_permission_keys text[]` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Replaces a custom role's permission assignments after permission/role validation. |
| `public.validate_payment_allocations` | `p_organization_id uuid, p_payment_id uuid` | `void` | Internal/helper function | Yes | No explicit authenticated EXECUTE grant, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Validates allocation rows for a payment, including organization, document type and amount constraints. |
| `public.set_payment_allocations` | `p_organization_id uuid, p_payment_id uuid, p_allocations jsonb` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Replaces a payment's allocation rows through the controlled payment-allocation RPC. |
| `public.post_inventory_adjustment` | `p_organization_id uuid, p_adjustment_date date, p_reason text, p_lines jsonb, p_gain_account_id uuid default null, p_loss_account_id uuid default null` | `uuid` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Posts an inventory adjustment with stock and corresponding accounting effects. |
| `public.report_trial_balance` | `p_organization_id uuid,p_date_from date,p_date_to date` | `table(account_id uuid,account_code text,account_name text,account_type text, opening_balance numeric,movement_debit numeric,movement_credit numeric,closing_balance numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns account opening balances, period debit/credit movement and closing balances for a date range. |
| `public.report_general_ledger` | `p_organization_id uuid,p_account_id uuid,p_date_from date,p_date_to date` | `table(entry_date date,entry_number text,description text,contact_id uuid, debit numeric,credit numeric,running_balance numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns journal-line activity and running balance for one account and date range. |
| `public.report_profit_and_loss` | `p_organization_id uuid,p_date_from date,p_date_to date` | `table(account_id uuid,account_code text,account_name text,account_type text,amount numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns revenue/expense account totals for a date range. |
| `public.report_balance_sheet` | `p_organization_id uuid,p_as_of_date date` | `table(account_id uuid,account_code text,account_name text,account_type text,balance numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns asset/liability/equity balances as of a date. |
| `public.report_inventory_valuation` | `p_organization_id uuid,p_as_of_date date default current_date` | `table(product_id uuid,product_code text,product_name text,quantity numeric, inventory_value numeric,average_cost numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns product quantity, inventory value and average cost as of a date. |
| `public.report_contact_balances` | `p_organization_id uuid,p_as_of_date date default current_date` | `table(contact_id uuid,contact_name text,account_id uuid,account_code text, account_type text,balance numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns contact-level balances by control account as of a date. |
| `public.report_receivables_aging` | `p_organization_id uuid,p_as_of_date date default current_date` | `table(document_id uuid,document_number text,contact_id uuid,contact_name text, invoice_date date,days_outstanding integer,current_amount numeric,days_31_60 numeric, days_61_90 numeric,over_90 numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns posted sales-document outstanding amounts bucketed by age as of a date. |
| `public.report_payables_aging` | `p_organization_id uuid,p_as_of_date date default current_date` | `table(document_type text,document_id uuid,document_number text,contact_id uuid, contact_name text,document_date date,days_outstanding integer,current_amount numeric, days_31_60 numeric,days_61_90 numeric,over_90 numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns posted purchase/expense outstanding amounts bucketed by age as of a date. |
| `public.report_unapplied_payments` | `p_organization_id uuid,p_as_of_date date default current_date` | `table(payment_id uuid,payment_number text,payment_type text,contact_id uuid, contact_name text,payment_date date,unapplied_amount numeric)` | Reporting RPC | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103000000_initial_database_schema.sql` | Returns posted receipt/payment/refund balances not allocated to documents as of a date. |
| `public.validate_role_assignment` | `p_organization_id uuid, p_role_id uuid` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Validates that a target role is active, belongs to the organization, and does not grant permissions the caller lacks. |
| `public.update_custom_role` | `p_organization_id uuid, p_role_id uuid, p_name text, p_status text` | `void` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Renames/activates/deactivates an organization custom role subject to active-member and system-role protections. |
| `public.is_organization_creator` | `p_organization_id uuid, p_user_id uuid` | `boolean` | Internal/helper function | Yes | No explicit authenticated EXECUTE grant, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Returns whether the specified user matches the organization creator membership anchor. |
| `public.is_org_administrator` | `p_organization_id uuid` | `boolean` | RPC/helper callable | Yes | authenticated EXECUTE granted, PUBLIC revoked, anon revoked | `20261103010000_organization_membership_security.sql` | Returns whether the current user is the organization's Administrator. |
| `public.guard_organization_creator_membership` | `—` | `trigger` | Trigger function | Yes | Trigger-only | `20261103020000_permanent_organization_administrator.sql` | Rejects all updates/deletes to the original creator membership and prevents forged creator membership inserts. |
| `public.guard_organization_created_at` | `—` | `trigger` | Trigger function | No | Trigger-only | `20261103010000_organization_membership_security.sql` | Prevents mutation of the organization creation timestamp used as creator identity anchor. |
| `public.guard_custom_role_control_plane_permissions` | `—` | `trigger` | Trigger function | Yes | Trigger-only | `20261103010000_organization_membership_security.sql` | Prevents custom roles from being assigned protected RBAC/control-plane permissions. |
| `public.guard_system_administrator_role` | `—` | `trigger` | Trigger function | Yes | Trigger-only | `20261103020000_permanent_organization_administrator.sql` | Prevents system Administrator role creation outside bootstrap and prevents its later update/delete. |

### Historical / removed function

- `public.transfer_organization_administrator(uuid, uuid)`: introduced by migration 0100 and granted to `authenticated` in that historical migration; dropped by migration 0200. It is **not callable and does not exist** after the full migration chain.
- `public.post_manual_journal_entry(uuid, text, date, text, jsonb)`: remains defined in the bootstrap but client-role EXECUTE is revoked. Manual journals use `save_draft_transaction_document`, `confirm_transaction_document`, and `post_confirmed_journal_entry`.

## Effective trigger inventory

The list below accounts for trigger drops/re-creations across the migrations; it is not a historical list of every trigger statement.

```sql
create trigger accounts_prevent_hierarchy_cycle before insert or update of organization_id, parent_account_id on public.accounts for each row execute function public.prevent_account_hierarchy_cycle();
```

```sql
create trigger organizations_set_updated_at before update on public.organizations for each row execute function public.set_updated_at();
```

```sql
create trigger roles_set_updated_at before update on public.roles for each row execute function public.set_updated_at();
```

```sql
create trigger permissions_set_updated_at before update on public.permissions for each row execute function public.set_updated_at();
```

```sql
create trigger organization_users_set_updated_at before update on public.organization_users for each row execute function public.set_updated_at();
```

```sql
create trigger accounts_set_updated_at before update on public.accounts for each row execute function public.set_updated_at();
```

```sql
create trigger units_of_measure_set_updated_at before update on public.units_of_measure for each row execute function public.set_updated_at();
```

```sql
create trigger contacts_set_updated_at before update on public.contacts for each row execute function public.set_updated_at();
```

```sql
create trigger products_set_updated_at before update on public.products for each row execute function public.set_updated_at();
```

```sql
create trigger expense_categories_set_updated_at before update on public.expense_categories for each row execute function public.set_updated_at();
```

```sql
create trigger number_sequences_set_updated_at before update on public.number_sequences for each row execute function public.set_updated_at();
```

```sql
create trigger journal_entries_set_updated_at before update on public.journal_entries for each row execute function public.set_updated_at();
```

```sql
create trigger purchase_set_updated_at before update on public.purchase for each row execute function public.set_updated_at();
```

```sql
create trigger purchase_items_set_updated_at before update on public.purchase_items for each row execute function public.set_updated_at();
```

```sql
create trigger purchase_returns_set_updated_at before update on public.purchase_returns for each row execute function public.set_updated_at();
```

```sql
create trigger purchase_return_items_set_updated_at before update on public.purchase_return_items for each row execute function public.set_updated_at();
```

```sql
create trigger sales_set_updated_at before update on public.sales for each row execute function public.set_updated_at();
```

```sql
create trigger sales_items_set_updated_at before update on public.sales_items for each row execute function public.set_updated_at();
```

```sql
create trigger sales_returns_set_updated_at before update on public.sales_returns for each row execute function public.set_updated_at();
```

```sql
create trigger sales_return_items_set_updated_at before update on public.sales_return_items for each row execute function public.set_updated_at();
```

```sql
create trigger expenses_set_updated_at before update on public.expenses for each row execute function public.set_updated_at();
```

```sql
create trigger payments_set_updated_at before update on public.payments for each row execute function public.set_updated_at();
```

```sql
create trigger payment_allocations_set_updated_at before update on public.payment_allocations for each row execute function public.set_updated_at();
```

```sql
create trigger roles_guard_system_role before update or delete on public.roles for each row execute function public.guard_system_role_mutation();
```

```sql
create trigger role_permissions_guard_admin before update or delete on public.role_permissions for each row execute function public.guard_system_role_permissions();
```

```sql
create trigger purchase_assign_document_number before insert or update of invoice_id on public.purchase for each row execute function public.assign_document_number();
```

```sql
create trigger sales_assign_document_number before insert or update of invoice_id on public.sales for each row execute function public.assign_document_number();
```

```sql
create trigger expenses_assign_document_number before insert or update of expense_number on public.expenses for each row execute function public.assign_document_number();
```

```sql
create trigger payments_assign_document_number before insert or update of payment_number on public.payments for each row execute function public.assign_document_number();
```

```sql
create trigger purchase_returns_assign_document_number before insert or update of return_number on public.purchase_returns for each row execute function public.assign_document_number();
```

```sql
create trigger sales_returns_assign_document_number before insert or update of return_number on public.sales_returns for each row execute function public.assign_document_number();
```

```sql
create trigger journal_entries_assign_document_number before insert or update of entry_number on public.journal_entries for each row execute function public.assign_document_number();
```

```sql
create trigger organizations_guard_created_at before update of created_at on public.organizations for each row execute function public.guard_organization_created_at();
```

```sql
create trigger role_permissions_guard_control_plane before insert or update of role_id, permission_id on public.role_permissions for each row execute function public.guard_custom_role_control_plane_permissions();
```

```sql
create trigger organization_users_guard_creator_record before insert or update or delete on public.organization_users for each row execute function public.guard_organization_creator_membership();
```

```sql
create trigger organization_users_guard_last_admin before insert or update or delete on public.organization_users for each row execute function public.guard_administrator_membership();
```

```sql
create trigger roles_guard_system_administrator before insert or update or delete on public.roles for each row execute function public.guard_system_administrator_role();
```

## Effective RLS policy inventory

All policies are listed verbatim. Policies are SELECT-only in the current migration set; no INSERT/UPDATE/DELETE policy is installed.

```sql
create policy organizations_select_member on public.organizations for select to authenticated using (public.has_org_permission(id, 'organization.read'));
```

```sql
create policy organization_users_select_member_or_self on public.organization_users for select to authenticated using (user_id = (select auth.uid()) or public.has_org_permission(organization_id, 'users.read'));
```

```sql
create policy roles_select_member on public.roles for select to authenticated using (public.has_org_permission(organization_id, 'roles.read'));
```

```sql
create policy permissions_select_authenticated on public.permissions for select to authenticated using (true);
```

```sql
create policy role_permissions_select_member on public.role_permissions for select to authenticated using ( exists ( select 1 from public.roles r where r.id = role_permissions.role_id and public.has_org_permission(r.organization_id, 'roles.read') ) );
```

```sql
create policy accounts_select_member on public.accounts for select to authenticated using (public.has_org_permission(organization_id, 'accounts.read'));
```

```sql
create policy units_of_measure_select_member on public.units_of_measure for select to authenticated using (public.has_org_permission(organization_id, 'products.read'));
```

```sql
create policy contacts_select_member on public.contacts for select to authenticated using (public.has_org_permission(organization_id, 'contacts.read'));
```

```sql
create policy products_select_member on public.products for select to authenticated using (public.has_org_permission(organization_id, 'products.read'));
```

```sql
create policy expense_categories_select_member on public.expense_categories for select to authenticated using (public.has_org_permission(organization_id, 'expenses.read'));
```

```sql
create policy number_sequences_select_member on public.number_sequences for select to authenticated using (public.has_org_permission(organization_id, 'organization.read'));
```

```sql
create policy journal_entries_select_member on public.journal_entries for select to authenticated using (public.has_org_permission(organization_id, 'journal_entries.read'));
```

```sql
create policy account_transactions_select_member on public.account_transactions for select to authenticated using (public.has_org_permission(organization_id, 'journal_entries.read'));
```

```sql
create policy inventory_transactions_select_member on public.inventory_transactions for select to authenticated using (public.has_org_permission(organization_id, 'inventory.read'));
```

```sql
create policy inventory_balances_select_member on public.inventory_balances for select to authenticated using (public.has_org_permission(organization_id, 'inventory.read'));
```

```sql
create policy purchase_select_member on public.purchase for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

```sql
create policy purchase_items_select_member on public.purchase_items for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

```sql
create policy purchase_returns_select_member on public.purchase_returns for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

```sql
create policy purchase_return_items_select_member on public.purchase_return_items for select to authenticated using (public.has_org_permission(organization_id, 'purchases.read'));
```

```sql
create policy sales_select_member on public.sales for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

```sql
create policy sales_items_select_member on public.sales_items for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

```sql
create policy sales_returns_select_member on public.sales_returns for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

```sql
create policy sales_return_items_select_member on public.sales_return_items for select to authenticated using (public.has_org_permission(organization_id, 'sales.read'));
```

```sql
create policy expenses_select_member on public.expenses for select to authenticated using (public.has_org_permission(organization_id, 'expenses.read'));
```

```sql
create policy payments_select_member on public.payments for select to authenticated using (public.has_org_permission(organization_id, 'payments.read'));
```

```sql
create policy payment_allocations_select_member on public.payment_allocations for select to authenticated using (public.has_org_permission(organization_id, 'payments.read'));
```

## Index inventory

All explicit index definitions, including unique and partial indexes:

```sql
create index organization_users_user_active_idx on public.organization_users (user_id, is_active);
```

```sql
create index organization_users_role_idx on public.organization_users (role_id);
```

```sql
create index roles_org_status_idx on public.roles (organization_id, status);
```

```sql
create index role_permissions_permission_idx on public.role_permissions (permission_id);
```

```sql
create index accounts_org_parent_idx on public.accounts (organization_id, parent_account_id);
```

```sql
create index contacts_org_name_idx on public.contacts (organization_id, name);
```

```sql
create index products_org_name_idx on public.products (organization_id, name);
```

```sql
create index expense_categories_org_name_idx on public.expense_categories (organization_id, name);
```

```sql
create index journal_entries_org_date_idx on public.journal_entries (organization_id, entry_date desc);
```

```sql
create index journal_entries_org_status_idx on public.journal_entries (organization_id, status);
```

```sql
create unique index journal_entries_one_reversal_per_entry_uq on public.journal_entries (organization_id, reversal_of_id) where reversal_of_id is not null;
```

```sql
create index account_transactions_account_idx on public.account_transactions (organization_id, account_id);
```

```sql
create index account_transactions_org_account_contact_idx on public.account_transactions (organization_id, account_id, contact_id) where contact_id is not null;
```

```sql
create index inventory_transactions_product_date_idx on public.inventory_transactions (organization_id, product_id, transaction_date desc);
```

```sql
create index purchase_supplier_date_idx on public.purchase (organization_id, supplier_id, invoice_date desc);
```

```sql
create index purchase_items_product_idx on public.purchase_items (organization_id, product_id);
```

```sql
create index purchase_returns_purchase_idx on public.purchase_returns (organization_id, purchase_id);
```

```sql
create index purchase_return_items_source_idx on public.purchase_return_items (organization_id, purchase_item_id);
```

```sql
create index sales_customer_date_idx on public.sales (organization_id, customer_id, invoice_date desc);
```

```sql
create index sales_items_product_idx on public.sales_items (organization_id, product_id);
```

```sql
create index sales_returns_sales_idx on public.sales_returns (organization_id, sales_id);
```

```sql
create index sales_return_items_source_idx on public.sales_return_items (organization_id, sales_item_id);
```

```sql
create index expenses_org_date_idx on public.expenses (organization_id, expense_date desc);
```

```sql
create index payments_org_date_idx on public.payments (organization_id, payment_date desc);
```

```sql
create index payment_allocations_document_idx on public.payment_allocations (organization_id, document_type, document_id);
```

```sql
create unique index journal_entries_one_org_opening_balance_uq on public.journal_entries (organization_id) where entry_type = 'opening_balance' and reference_type = 'organization_opening_balance';
```

```sql
create unique index journal_entries_payment_reference_uq on public.journal_entries (organization_id, reference_type, reference_id) where entry_type = 'payment' and reference_type = 'payment' and reference_id is not null;
```

```sql
create unique index journal_entries_sales_reference_uq on public.journal_entries (organization_id, reference_type, reference_id) where entry_type = 'sale' and reference_type = 'sale' and reference_id is not null;
```

```sql
create unique index if not exists organization_users_one_active_company_per_user on public.organization_users (user_id) where is_active = true;
```

```sql
create unique index if not exists organization_users_one_active_company_per_user on public.organization_users (user_id) where is_active = true;
```

## Table/function privilege statements

The SQL migrations include explicit GRANT/REVOKE statements. The full statements below are retained as the source-level privilege record; evaluate them in migration order when reconstructing ACL state.

```sql
revoke all on function public.prevent_account_hierarchy_cycle() from public, anon, authenticated;
```

```sql
revoke all on function public.is_active_org_member(uuid) from public, anon;
```

```sql
revoke all on function public.has_org_permission(uuid, text) from public, anon;
```

```sql
grant execute on function public.is_active_org_member(uuid) to authenticated;
```

```sql
grant execute on function public.has_org_permission(uuid, text) to authenticated;
```

```sql
revoke all on public.organizations, public.organization_users, public.roles, public.permissions, public.role_permissions, public.accounts, public.units_of_measure, public.contacts, public.products, public.expense_categories, public.number_sequences from anon, authenticated;
```

```sql
grant select on public.organizations, public.organization_users, public.roles, public.permissions, public.role_permissions, public.accounts, public.units_of_measure, public.contacts, public.products, public.expense_categories, public.number_sequences to authenticated;
```

```sql
revoke all on public.journal_entries, public.account_transactions, public.inventory_transactions, public.inventory_balances, public.purchase, public.purchase_items, public.purchase_returns, public.purchase_return_items, public.sales, public.sales_items, public.sales_returns, public.sales_return_items, public.expenses, public.payments, public.payment_allocations from anon, authenticated;
```

```sql
grant select on public.journal_entries, public.account_transactions, public.inventory_transactions, public.inventory_balances, public.purchase, public.purchase_items, public.purchase_returns, public.purchase_return_items, public.sales, public.sales_items, public.sales_returns, public.sales_return_items, public.expenses, public.payments, public.payment_allocations to authenticated;
```

```sql
revoke all on function public.next_document_number(uuid, text) from public, anon;
```

```sql
grant execute on function public.next_document_number(uuid, text) to authenticated;
```

```sql
revoke all on function public.create_organization_with_admin(text, text, text) from public, anon;
```

```sql
grant execute on function public.create_organization_with_admin(text, text, text) to authenticated;
```

```sql
revoke all on function public.guard_system_role_mutation() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_administrator_membership() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_system_role_permissions() from public, anon, authenticated;
```

```sql
revoke all on function public.add_organization_user_by_email(uuid, text, uuid) from public, anon;
```

```sql
revoke all on function public.update_organization_user_role(uuid, uuid, uuid) from public, anon;
```

```sql
revoke all on function public.set_organization_user_active(uuid, uuid, boolean) from public, anon;
```

```sql
grant execute on function public.add_organization_user_by_email(uuid, text, uuid) to authenticated;
```

```sql
grant execute on function public.update_organization_user_role(uuid, uuid, uuid) to authenticated;
```

```sql
grant execute on function public.set_organization_user_active(uuid, uuid, boolean) to authenticated;
```

```sql
revoke all on function public.post_manual_journal_entry(uuid, text, date, text, jsonb) from public, anon, authenticated;
```

```sql
revoke all on function public.post_purchase(uuid, uuid) from public, anon;
```

```sql
grant execute on function public.post_purchase(uuid, uuid) to authenticated;
```

```sql
revoke all on function public.post_opening_balances(uuid, date, jsonb, jsonb, jsonb, text) from public, anon;
```

```sql
grant execute on function public.post_opening_balances(uuid, date, jsonb, jsonb, jsonb, text) to authenticated;
```

```sql
revoke all on function public.post_contact_payment(uuid, uuid) from public, anon;
```

```sql
grant execute on function public.post_contact_payment(uuid, uuid) to authenticated;
```

```sql
revoke all on function public.post_sales(uuid, uuid) from public, anon;
```

```sql
grant execute on function public.post_sales(uuid, uuid) to authenticated;
```

```sql
revoke all on function public.reverse_journal_entry(uuid, uuid, date, text) from public, anon;
```

```sql
grant execute on function public.reverse_journal_entry(uuid, uuid, date, text) to authenticated;
```

```sql
revoke all on function public.post_expense(uuid, uuid) from public, anon;
```

```sql
grant execute on function public.post_expense(uuid, uuid) to authenticated;
```

```sql
revoke all on function public.post_purchase_return(uuid, uuid) from public, anon;
```

```sql
grant execute on function public.post_purchase_return(uuid, uuid) to authenticated;
```

```sql
revoke all on function public.post_sales_return(uuid, uuid) from public, anon;
```

```sql
grant execute on function public.post_sales_return(uuid, uuid) to authenticated;
```

```sql
revoke all on function public.post_confirmed_journal_entry(uuid, uuid) from public, anon;
```

```sql
grant execute on function public.post_confirmed_journal_entry(uuid, uuid) to authenticated;
```

```sql
revoke all on function public.save_draft_transaction_document(uuid, text, jsonb, jsonb, uuid) from public, anon;
```

```sql
grant execute on function public.save_draft_transaction_document(uuid, text, jsonb, jsonb, uuid) to authenticated;
```

```sql
revoke all on function public.confirm_transaction_document(uuid, text, uuid) from public, anon;
```

```sql
revoke all on function public.revert_transaction_document_to_draft(uuid, text, uuid) from public, anon;
```

```sql
revoke all on function public.void_transaction_document(uuid, text, uuid, text) from public, anon;
```

```sql
revoke all on function public.delete_draft_transaction_document(uuid, text, uuid) from public, anon;
```

```sql
grant execute on function public.confirm_transaction_document(uuid, text, uuid) to authenticated;
```

```sql
grant execute on function public.revert_transaction_document_to_draft(uuid, text, uuid) to authenticated;
```

```sql
grant execute on function public.void_transaction_document(uuid, text, uuid, text) to authenticated;
```

```sql
grant execute on function public.delete_draft_transaction_document(uuid, text, uuid) to authenticated;
```

```sql
revoke all on function public.seed_default_chart_of_accounts(uuid) from public, anon, authenticated;
```

```sql
revoke all on function public.create_organization_with_admin(text,text,text) from public, anon;
```

```sql
grant execute on function public.create_organization_with_admin(text,text,text) to authenticated;
```

```sql
revoke all on function public.next_document_number(uuid,text) from public, anon;
```

```sql
grant execute on function public.next_document_number(uuid,text) to authenticated;
```

```sql
revoke all on function public.assign_document_number() from public, anon, authenticated;
```

```sql
revoke all on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) from public, anon;
```

```sql
grant execute on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) to authenticated;
```

```sql
revoke all on function public.save_master_data(uuid,text,jsonb,uuid) from public, anon;
```

```sql
grant execute on function public.save_master_data(uuid,text,jsonb,uuid) to authenticated;
```

```sql
revoke all on function public.create_custom_role(uuid,text,text[]) from public,anon;
```

```sql
revoke all on function public.replace_custom_role_permissions(uuid,uuid,text[]) from public,anon;
```

```sql
grant execute on function public.create_custom_role(uuid,text,text[]) to authenticated;
```

```sql
grant execute on function public.replace_custom_role_permissions(uuid,uuid,text[]) to authenticated;
```

```sql
revoke all on function public.validate_payment_allocations(uuid,uuid) from public,anon,authenticated;
```

```sql
revoke all on function public.set_payment_allocations(uuid,uuid,jsonb) from public,anon;
```

```sql
grant execute on function public.set_payment_allocations(uuid,uuid,jsonb) to authenticated;
```

```sql
revoke all on function public.post_inventory_adjustment(uuid,date,text,jsonb,uuid,uuid) from public,anon;
```

```sql
grant execute on function public.post_inventory_adjustment(uuid,date,text,jsonb,uuid,uuid) to authenticated;
```

```sql
revoke all on function public.report_unapplied_payments(uuid,date) from public,anon;
```

```sql
grant execute on function public.report_unapplied_payments(uuid,date) to authenticated;
```

```sql
revoke all on function public.report_trial_balance(uuid,date,date) from public,anon;
```

```sql
revoke all on function public.report_general_ledger(uuid,uuid,date,date) from public,anon;
```

```sql
revoke all on function public.report_profit_and_loss(uuid,date,date) from public,anon;
```

```sql
revoke all on function public.report_balance_sheet(uuid,date) from public,anon;
```

```sql
revoke all on function public.report_inventory_valuation(uuid,date) from public,anon;
```

```sql
revoke all on function public.report_contact_balances(uuid,date) from public,anon;
```

```sql
revoke all on function public.report_receivables_aging(uuid,date) from public,anon;
```

```sql
revoke all on function public.report_payables_aging(uuid,date) from public,anon;
```

```sql
grant execute on function public.report_trial_balance(uuid,date,date) to authenticated;
```

```sql
grant execute on function public.report_general_ledger(uuid,uuid,date,date) to authenticated;
```

```sql
grant execute on function public.report_profit_and_loss(uuid,date,date) to authenticated;
```

```sql
grant execute on function public.report_balance_sheet(uuid,date) to authenticated;
```

```sql
grant execute on function public.report_inventory_valuation(uuid,date) to authenticated;
```

```sql
grant execute on function public.report_contact_balances(uuid,date) to authenticated;
```

```sql
grant execute on function public.report_receivables_aging(uuid,date) to authenticated;
```

```sql
grant execute on function public.report_payables_aging(uuid,date) to authenticated;
```

```sql
revoke all on function public.validate_role_assignment(uuid,uuid) from public,anon;
```

```sql
grant execute on function public.validate_role_assignment(uuid,uuid) to authenticated;
```

```sql
revoke all on function public.update_custom_role(uuid,uuid,text,text) from public,anon;
```

```sql
grant execute on function public.update_custom_role(uuid,uuid,text,text) to authenticated;
```

```sql
revoke all on function public.is_organization_creator(uuid,uuid) from public, anon, authenticated;
```

```sql
revoke all on function public.is_org_administrator(uuid) from public, anon;
```

```sql
grant execute on function public.is_org_administrator(uuid) to authenticated;
```

```sql
revoke all on function public.guard_organization_created_at() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_organization_creator_membership() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_administrator_membership() from public, anon, authenticated;
```

```sql
revoke all on function public.create_organization_with_admin(text,text,text) from public, anon;
```

```sql
grant execute on function public.create_organization_with_admin(text,text,text) to authenticated;
```

```sql
revoke all on function public.guard_custom_role_control_plane_permissions() from public, anon, authenticated;
```

```sql
revoke all on function public.validate_role_assignment(uuid,uuid) from public, anon;
```

```sql
grant execute on function public.validate_role_assignment(uuid,uuid) to authenticated;
```

```sql
revoke all on function public.add_organization_user_by_email(uuid,text,uuid) from public, anon;
```

```sql
grant execute on function public.add_organization_user_by_email(uuid,text,uuid) to authenticated;
```

```sql
revoke all on function public.update_organization_user_role(uuid,uuid,uuid) from public, anon;
```

```sql
grant execute on function public.update_organization_user_role(uuid,uuid,uuid) to authenticated;
```

```sql
revoke all on function public.set_organization_user_active(uuid,uuid,boolean) from public, anon;
```

```sql
grant execute on function public.set_organization_user_active(uuid,uuid,boolean) to authenticated;
```

```sql
revoke all on function public.transfer_organization_administrator(uuid,uuid) from public, anon;
```

```sql
grant execute on function public.transfer_organization_administrator(uuid,uuid) to authenticated;
```

```sql
revoke all on function public.create_custom_role(uuid,text,text[]) from public, anon;
```

```sql
grant execute on function public.create_custom_role(uuid,text,text[]) to authenticated;
```

```sql
revoke all on function public.replace_custom_role_permissions(uuid,uuid,text[]) from public, anon;
```

```sql
grant execute on function public.replace_custom_role_permissions(uuid,uuid,text[]) to authenticated;
```

```sql
revoke all on function public.update_custom_role(uuid,uuid,text,text) from public, anon;
```

```sql
grant execute on function public.update_custom_role(uuid,uuid,text,text) to authenticated;
```

```sql
revoke all on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) from public, anon;
```

```sql
grant execute on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) to authenticated;
```

```sql
revoke all on function public.is_organization_creator(uuid,uuid) from public, anon, authenticated;
```

```sql
revoke all on function public.is_org_administrator(uuid) from public, anon;
```

```sql
grant execute on function public.is_org_administrator(uuid) to authenticated;
```

```sql
revoke all on function public.guard_organization_created_at() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_organization_creator_membership() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_administrator_membership() from public, anon, authenticated;
```

```sql
revoke all on function public.create_organization_with_admin(text,text,text) from public, anon;
```

```sql
grant execute on function public.create_organization_with_admin(text,text,text) to authenticated;
```

```sql
revoke all on function public.guard_custom_role_control_plane_permissions() from public, anon, authenticated;
```

```sql
revoke all on function public.validate_role_assignment(uuid,uuid) from public, anon;
```

```sql
grant execute on function public.validate_role_assignment(uuid,uuid) to authenticated;
```

```sql
revoke all on function public.add_organization_user_by_email(uuid,text,uuid) from public, anon;
```

```sql
grant execute on function public.add_organization_user_by_email(uuid,text,uuid) to authenticated;
```

```sql
revoke all on function public.update_organization_user_role(uuid,uuid,uuid) from public, anon;
```

```sql
grant execute on function public.update_organization_user_role(uuid,uuid,uuid) to authenticated;
```

```sql
revoke all on function public.set_organization_user_active(uuid,uuid,boolean) from public, anon;
```

```sql
grant execute on function public.set_organization_user_active(uuid,uuid,boolean) to authenticated;
```

```sql
revoke all on function public.transfer_organization_administrator(uuid,uuid) from public, anon;
```

```sql
grant execute on function public.transfer_organization_administrator(uuid,uuid) to authenticated;
```

```sql
revoke all on function public.create_custom_role(uuid,text,text[]) from public, anon;
```

```sql
grant execute on function public.create_custom_role(uuid,text,text[]) to authenticated;
```

```sql
revoke all on function public.replace_custom_role_permissions(uuid,uuid,text[]) from public, anon;
```

```sql
grant execute on function public.replace_custom_role_permissions(uuid,uuid,text[]) to authenticated;
```

```sql
revoke all on function public.update_custom_role(uuid,uuid,text,text) from public, anon;
```

```sql
grant execute on function public.update_custom_role(uuid,uuid,text,text) to authenticated;
```

```sql
revoke all on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) from public, anon;
```

```sql
grant execute on function public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text) to authenticated;
```

```sql
revoke all on function public.guard_organization_creator_membership() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_administrator_membership() from public, anon, authenticated;
```

```sql
revoke all on function public.guard_system_administrator_role() from public, anon, authenticated;
```

```sql
revoke all on function public.create_organization_with_admin(text,text,text) from public, anon;
```

```sql
grant execute on function public.create_organization_with_admin(text,text,text) to authenticated;
```

## Important implementation boundaries recorded by the schema

These are database facts, not UI promises:

- `contacts` has no customer/supplier type discriminator.
- `payment_allocations.document_id`, `journal_entries.reference_id`, and `inventory_transactions.reference_id` are polymorphic UUID references; they are not ordinary foreign keys to all target document tables.
- `organization_users` has one `role_id`; multiple roles per membership are not represented.
- The default chart of accounts is seeded by `seed_default_chart_of_accounts`, which the final organization-creation RPC invokes.
- `post_inventory_adjustment` exists and is granted to `authenticated`; its authorization/validation is inside the function.
- Reporting RPCs exist for trial balance, general ledger, profit and loss, balance sheet, inventory valuation, contact balances, receivables aging, payables aging and unapplied payments.
- `payment_allocations` is a real table with a controlled setter/validator, but the exact operational limitations of each payment type are enforced by the posting/validation function bodies; do not infer universal invoice allocation support beyond those implementations.
- There is no accounting-period table, period column, period permission, period-close function or period-lock workflow in this migration chain.
- There are no SQL views or materialized views in the migrations.

## Source files

- [Initial bootstrap](../supabase/migrations/20261103000000_initial_database_schema.sql)
- [Membership security migration](../supabase/migrations/20261103010000_organization_membership_security.sql)
- [Permanent Administrator migration](../supabase/migrations/20261103020000_permanent_organization_administrator.sql)
- [Database architecture and security guide](DATABASE_AND_SECURITY.md)
- [Static database audit](DATABASE_AUDIT.md)
