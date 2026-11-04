# Zero ERP — Database Architecture and Security

> This document describes the database that is actually defined by the repository's single canonical bootstrap SQL file. It is not a product roadmap, target schema, or statement that an application screen exists.

**Canonical detailed reference:** [Complete Database Reference](DATABASE_REFERENCE.md)  
**Static findings and limitations:** [Database Audit](DATABASE_AUDIT.md)

## 1. Canonical database source

The complete effective database is defined by one SQL file: `supabase/migrations/20261103000000_initial_database_schema.sql`. It contains the original bootstrap plus the membership/RBAC security and permanent original-Creator Administrator protections, in their required execution order, within one transaction.

This file is intended only for a new/empty Supabase database; it is not an upgrade script for an already populated database. The creator/Admin preflight checks from the former incremental file are retained in the consolidated SQL.

The historical `transfer_organization_administrator(uuid, uuid)` RPC is not part of the effective schema: the consolidated SQL drops it before commit.

## 2. Effective schema inventory

| Object | Effective state |
|---|---:|
| Public tables | 26 |
| Columns across those tables | 349 |
| Declared table constraints (inline and later ALTER constraints) | 129 |
| Explicit indexes | 29 |
| RLS-enabled tables | 26 |
| RLS policies | 26 |
| Triggers | 37 |
| Effective public functions | 53 |
| Seeded permission keys | 43 |
| Views / materialized views | 0 |
| User-defined sequences | 0 |
| Custom enum/type/domain definitions | 0 |

Every table, column, constraint, index, trigger, policy, function signature, permission key and privilege statement is catalogued in the [Complete Database Reference](DATABASE_REFERENCE.md).

## 3. Relational model

### Tenant and RBAC

- `organizations` is the tenant root.
- `organization_users` maps Supabase Auth identities (`auth.users`) to organizations. A membership has one `role_id`, not a collection of roles.
- `roles` are organization-scoped. `permissions` is a global catalog seeded by the bootstrap. `role_permissions` maps roles to permission rows.
- A partial unique index on `organization_users(user_id)` where `is_active = true` permits at most one active company membership per Auth user.
- Role assignment and permission checks are implemented in database functions, including `is_active_org_member`, `has_org_permission`, `validate_role_assignment`, `create_custom_role`, `replace_custom_role_permissions`, and `update_custom_role`.

### Accounting and inventory

- `accounts` stores the organization chart of accounts and its hierarchy.
- `journal_entries` stores journal headers and lifecycle/reversal metadata.
- `account_transactions` stores debit/credit lines. Each line must be one-sided (debit or credit), positive on the populated side, and associated with same-organization journal/account/contact records.
- `inventory_transactions` stores stock movement and cost history; `inventory_balances` stores current per-product quantity/value/cost.
- `products` links units and optional inventory, sales and COGS accounts.
- The default chart of accounts, General Expenses category and document-number sequences are seeded by `seed_default_chart_of_accounts`, which the final organization-creation RPC calls.

### Commercial documents

- Purchases: `purchase`, `purchase_items`, `purchase_returns`, `purchase_return_items`.
- Sales: `sales`, `sales_items`, `sales_returns`, `sales_return_items`.
- Expenses and settlements: `expense_categories`, `expenses`, `payments`, `payment_allocations`.
- Master data: `contacts`, `products`, `units_of_measure`, `accounts`, `expense_categories`, and `number_sequences`.

Tenant-scoped composite foreign keys are used for cross-table references so a row cannot reference a parent belonging to another organization. The full FK and CHECK definitions are listed table-by-table in the reference.

## 4. Permanent organization creator and Administrator

The final schema establishes the original creator as the sole Administrator for the lifetime of the organization.

1. `create_organization_with_admin` requires an authenticated Supabase user and serializes creation against that user's Auth row.
2. It creates the organization, system Administrator role, role-permission rows, and original creator membership with the same creation timestamp.
3. The creator membership is identified by `organization_users.created_at = organizations.created_at`.
4. The final creator-membership trigger rejects every UPDATE and DELETE to that row. This includes role, active-state, identity, organization, timestamp, and metadata changes.
5. The Administrator-membership trigger rejects later Administrator assignment or mutation. The system Administrator role is protected against later modification/deletion.
6. `transfer_organization_administrator` is dropped. No replacement/transfer RPC is installed.
7. The creator anchor remains present, so the same Auth user cannot create a second organization.

Because `organization_users.user_id` references `auth.users(id) ON DELETE CASCADE`, deleting the original Creator's Auth account would attempt to delete the protected membership and fail. Account disable/ban is distinct from hard deletion.

Database owner/superuser credentials remain outside the protection boundary: a sufficiently privileged operator can alter schema objects or disable triggers. Production database-owner credentials must therefore be restricted.

## 5. RLS and database access boundary

- RLS is enabled on all 26 public tables; the migrations do not use `FORCE ROW LEVEL SECURITY`.
- The 26 installed policies are SELECT policies. Their predicates use membership/permission helpers for tenant data; the global permission catalog has its own authenticated read policy.
- Direct browser-role table mutations are revoked by the SQL privilege statements. Mutations are exposed through explicitly granted RPCs and trigger-controlled paths.
- SECURITY DEFINER functions pin `search_path = ''`; the reference lists each function's security mode and explicit EXECUTE grants/revokes.
- RLS is not a substitute for RPC authorization. RPCs separately validate `auth.uid()`, organization membership, active organization, permission keys, referenced-row tenant ownership, and transaction state as appropriate.

## 6. RPC and trigger workflows

The full function catalog in [DATABASE_REFERENCE.md](DATABASE_REFERENCE.md#function-and-rpc-reference) records every effective signature, return type, SECURITY DEFINER status, execution exposure, migration source and purpose.

### Organization, membership and roles

- `create_organization_with_admin` creates the organization and permanent Creator Administrator.
- `add_organization_user_by_email` adds an existing email-verified Auth user; the database does not create an invitation or send an invitation email.
- `update_organization_user_role` and `set_organization_user_active` manage ordinary memberships; Creator membership changes are rejected by triggers.
- `create_custom_role`, `replace_custom_role_permissions`, `validate_role_assignment`, and `update_custom_role` implement organization role management.
- No Administrator transfer API exists in the final schema.

### Master data and organization profile

- `save_master_data` accepts the entity types `account`, `unit`, `contact`, `product`, and `expense_category`, and validates editable fields and permission keys.
- `update_organization_profile` updates the supported organization profile fields with permission and currency/timezone validation.

### Document lifecycle

- `save_draft_transaction_document` creates/updates supported draft documents.
- `confirm_transaction_document` validates and confirms eligible drafts.
- `revert_transaction_document_to_draft` reopens eligible confirmed documents.
- `void_transaction_document` voids eligible draft/confirmed documents with a reason.
- `delete_draft_transaction_document` deletes eligible drafts.
- Confirmation does not itself perform the final ledger/inventory posting; the dedicated posting functions do that.
- The exact supported document types, fields and state checks are in the SQL function bodies and the RPC catalog. Do not infer unsupported document types.

### Posting and reversals

The final schema defines posting functions for purchases, sales, purchase returns, sales returns, expenses, contact payments, inventory adjustments, opening balances and confirmed manual journals. `reverse_journal_entry` provides controlled journal reversal. These routines use organization-scoped locks and row locks where implemented in their bodies; see the SQL source for exact lock ordering and validation. Inventory adjustment numbering remains part of its posting transaction and requires `inventory.adjust`. Runtime behavior must be verified by the database CI workflow.

The legacy `post_manual_journal_entry` function remains defined but client EXECUTE is revoked. The supported manual journal path is draft save → confirm → `post_confirmed_journal_entry`.

### Number allocation

- `number_sequences` stores organization/document-type prefixes, next values, padding and active state.
- Draft purchase, sales, expense, payment, purchase-return, sales-return and manual-journal records have a NULL document number. A `BEFORE UPDATE OF status` trigger allocates the number only on the first Draft → Confirmed transition, after the confirmation RPC has completed its business validation.
- The trigger preserves an assigned number through later updates, Confirmed → Draft reversion, reconfirmation, voiding and posting. A reverted document therefore keeps its original number and does not consume another sequence value.
- `next_document_number` is an internal SECURITY DEFINER helper. Browser-authenticated clients have no direct EXECUTE privilege; the helper checks the document-specific Confirm permission (or `inventory.adjust` for inventory adjustments) and atomically increments the organization-scoped sequence.
- Inventory adjustment is a direct posting workflow rather than a saved Draft/Confirmed transaction document. Its posting RPC allocates the `inventory_adjustment` number inside the same transaction as the journal and inventory effects.

### Payments and allocations

- `payment_allocations` supports `purchase`, `purchase_return`, `sales`, `sales_return`, and `expense` document types.
- `set_payment_allocations` replaces draft allocation rows and invokes `validate_payment_allocations`.
- The validator checks allocation total, supported target document, target status, contact match, outstanding balance and payment type.
- Bank transfers cannot have document allocations. Allocation target IDs are polymorphic and therefore do not have a single conventional foreign key to all target tables.

### Reports

Reporting RPCs exist for trial balance, general ledger, profit and loss, balance sheet, inventory valuation, contact balances, receivables aging, payables aging and unapplied payments. Their exact arguments and return columns are listed in the function catalog. The three aging/unapplied-payment reports use document dates and the linked reversal journal entry's accounting `entry_date` to determine whether a payment, return, or expense reversal belongs in the requested as-of snapshot. Fully returned sales and purchases remain eligible for earlier snapshots; return amounts are applied only when their return dates are on or before the cutoff. Reversals dated after the cutoff do not erase the earlier state. This is source-level verification; historical report results have not been runtime-tested or financially reconciled.

## 7. Tenant-isolation hardening in the current SQL

- The self-read branch of `organization_users_select_member_or_self` exposes only the caller's own active membership in an active organization. The `users.read` permission branch remains available for authorized organization administrators.
- `save_draft_transaction_document` validates a supplied manual-journal `reference_id` against an explicit allowlist of reference types and requires the referenced row to belong to the same `p_organization_id`. Unsupported types, missing reference types, and cross-organization or nonexistent targets are rejected.
- The document-number allocator maps `inventory_adjustment` to `inventory.adjust`.
- Receivables and payables aging include only payments and returns whose effective dates fall on or before the requested `p_as_of_date`; a reversal changes the historical result from its linked reversal journal entry's `entry_date`, not its wall-clock `reversed_at`.
- Fully returned sales and purchases remain available to earlier as-of snapshots, with returns subtracted only from their own effective return dates.
- Unapplied-payment reporting uses the same accounting-date reversal rule as the aging reports.

These controls were reviewed statically in the canonical SQL. They have not yet been certified through live PostgreSQL/Supabase adversarial tests.

## 8. Important model boundaries

These are explicit properties of the current schema:

- `contacts` does not distinguish customer from supplier with a dedicated type column.
- `organization_users` stores one role per membership.
- `payment_allocations.document_id`, `journal_entries.reference_id`, and `inventory_transactions.reference_id` are polymorphic UUID references, not ordinary foreign keys to every possible target table.
- There are no views or materialized views in the migrations.
- There is no accounting-period table, accounting-period column, period permission, period-close RPC, or period-lock workflow.
- The SQL migrations do not create application screens, API routes outside PostgreSQL RPCs, Auth email delivery, or deployment infrastructure.

## 9. Source of detail

Use [Complete Database Reference](DATABASE_REFERENCE.md) for exact definitions. Use the migration files as the executable authority if any prose ever differs. Documentation changes must be made from the migration source; never modify the schema merely to make it match stale documentation.
