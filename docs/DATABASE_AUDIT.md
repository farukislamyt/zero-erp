# Zero ERP — Database Audit

**Audit date:** 2026-11-03  
**Branch:** `feat/database-migrations`  
**Audit type:** Static source audit of the single consolidated bootstrap SQL file and its database documentation.  
**Live database status:** No Supabase project was queried or modified. No PostgreSQL migration execution or runtime test is claimed.

## 1. Scope and source of truth

Reviewed the single canonical file: `supabase/migrations/20261103000000_initial_database_schema.sql`.

That file now contains the effective SQL previously distributed across the three source files, merged in dependency order and wrapped in one transaction. The historical `transfer_organization_administrator(uuid, uuid)` function is dropped before the final COMMIT and is not part of the effective schema. The detailed, table-by-table object catalog is [DATABASE_REFERENCE.md](DATABASE_REFERENCE.md).

## 2. Effective static inventory

| Object | Count / state |
|---|---:|
| Public tables | 26 |
| Columns | 349 |
| Declared table constraints | 129 |
| Explicit indexes | 30 |
| RLS-enabled tables | 26 |
| RLS policies | 26 |
| Effective triggers | 37 |
| Effective public functions | 53 |
| Seeded permission keys | 43 |
| Views / materialized views | 0 |
| User-defined sequences | 0 |
| Custom enum/type/domain definitions | 0 |

All SECURITY DEFINER functions in the effective migration set specify an empty search path (`SET search_path = ''`). The migrations do not use `FORCE ROW LEVEL SECURITY`.

## 3. Verified implementation present in SQL

1. **Tenant model:** organization-scoped records and composite organization-scoped foreign keys protect many cross-table references.
2. **Membership/RBAC:** Supabase Auth identities are linked through `organization_users`; each membership has one role; `roles`, `permissions` and `role_permissions` implement RBAC.
3. **Permanent Creator Administrator:** the original creator membership is anchored by matching its `created_at` to `organizations.created_at`. The consolidated SQL rejects every UPDATE/DELETE of that membership, rejects later Administrator assignments, protects the system Administrator role, and drops the transfer RPC.
4. **Single active company membership:** a partial unique index limits each Auth user to one active organization membership.
5. **Master data:** `save_master_data` supports account, unit, contact, product and expense-category entities with per-entity permission and field validation.
6. **Organization profile:** `update_organization_profile` exists and validates supported profile values, including currency/timezone.
7. **Default setup:** organization creation invokes `seed_default_chart_of_accounts`, which seeds the default account hierarchy, General Expenses category and document-number sequence rows.
8. **Document lifecycle:** draft save, confirmation, revert-to-draft, void and draft deletion RPCs are present.
9. **Posting/reversal:** dedicated RPCs exist for purchases, sales, purchase returns, sales returns, expenses, contact payments, opening balances, confirmed manual journals, journal reversals and inventory adjustments.
10. **Payment allocation:** a payment allocation table, controlled setter and validator are present. Supported target document types are purchase, purchase return, sales, sales return and expense.
11. **Reporting:** RPCs exist for trial balance, general ledger, profit and loss, balance sheet, inventory valuation, contact balances, receivables aging, payables aging and unapplied payments.
12. **Numbering:** sequence storage, a permission-checked allocator and document-number triggers are present for purchase, sales, expenses, payments, returns and manual journal entries.
13. **RLS and privileges:** RLS is enabled on all 26 public tables. The installed 26 policies are SELECT policies; direct browser-role table writes are revoked and controlled RPCs are granted explicitly.

## 4. Findings requiring attention

### P1 — Inventory-adjustment numbering permission is missing

`seed_default_chart_of_accounts` creates an `inventory_adjustment` row in `number_sequences`. `post_inventory_adjustment` calls `next_document_number(p_organization_id, 'inventory_adjustment')`. However, the current `next_document_number` permission CASE expression has no `inventory_adjustment` branch. It therefore sets the required permission to NULL and raises the authorization error before allocating the number.

**Impact:** although `post_inventory_adjustment` exists and has an authenticated EXECUTE grant, its current call path cannot successfully allocate its document number.

**Documentation treatment:** the reference records the RPC as defined, and this audit explicitly records the implementation defect. This documentation-only task did not change database behavior.

### P1 — Receivables aging includes payments after the as-of date

`report_receivables_aging` filters the sales invoice and sales-return dates by `p_as_of_date`, but its payment-allocation subquery does not filter the related posted payment by `payment_date <= p_as_of_date`. A payment made after the requested historical date can therefore reduce the reported historical receivable.

`report_payables_aging` does include the payment-date cutoff in its allocation subqueries.

**Impact:** historical receivables aging can be understated. The report should apply a consistent payment-date cutoff (and the product's intended accounting-date semantics should be confirmed).

### P2 — Creator Auth hard deletion is intentionally blocked by the membership guard

`organization_users.user_id` references `auth.users(id) ON DELETE CASCADE`, while the original creator membership rejects DELETE. A hard deletion of the original creator's Auth row attempts the cascade and fails because the protected membership cannot be removed.

**Operational implication:** disable/ban the creator's Auth account rather than hard-delete it while the organization exists. If hard deletion must later be supported, the data model needs a separately retained immutable creator identity; that is not present in the current schema.

### P2 — Historical function definitions are repeated in the bootstrap

The initial bootstrap contains multiple `CREATE OR REPLACE FUNCTION` definitions for several function names. The later definition in the same bootstrap is authoritative, and subsequent migrations may replace it again. The reference documents the effective final function set rather than treating every historical definition as a separate callable RPC.

**Maintainability implication:** when changing a function, update the authoritative final definition and keep the migration history explicit. Do not infer the final behavior from the first matching definition.

## 5. Important boundaries — do not document as implemented features

- `contacts` has no dedicated customer/supplier discriminator.
- `organization_users` supports one role per membership.
- `payment_allocations.document_id`, `journal_entries.reference_id` and `inventory_transactions.reference_id` are polymorphic UUID references, not ordinary foreign keys to all possible target tables.
- The final schema contains no views or materialized views.
- No accounting-period table, accounting-period column, period permission, period-close function or period-lock workflow exists.
- The presence of a database RPC does not establish that a frontend screen or complete user workflow exists.
- The historical Administrator-transfer RPC is dropped by the final migration and must not be described as available.

## 6. Test and verification boundary

The repository branch currently contains one consolidated database SQL file and the documentation files; the earlier database smoke test and GitHub Actions SQL-test workflow were removed at the user's request. Therefore:

| Verification | Status |
|---|---|
| Static migration/source inspection | Performed |
| Documentation-to-migration inventory comparison | Performed |
| PostgreSQL clean bootstrap execution | Not performed in this documentation task |
| PostgreSQL incremental migration execution | Not performed |
| Supabase Auth/JWT integration | Not performed |
| Multi-user tenant-isolation runtime tests | Not performed |
| Concurrent posting/locking tests | Not performed |
| Financial reconciliation / full-year scenario | Not performed |

Do not describe this audit as a successful live database deployment or as a passing automated test suite.

## 7. Documentation maintenance rule

The executable bootstrap SQL is authoritative. When schema objects change:

1. Update the migration(s).
2. Rebuild the table-by-table catalog, including columns, constraints, indexes, triggers and RLS policies.
3. Reconcile every effective function signature, return type, security mode and EXECUTE grant/revoke.
4. Reconcile permission seeds and table privileges.
5. Update the architecture guide and this audit.
6. Run PostgreSQL/Supabase verification separately and record the exact result.

The [Complete Database Reference](DATABASE_REFERENCE.md) is the exhaustive object inventory; this file records only audit findings and verification boundaries.
