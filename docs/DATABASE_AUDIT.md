# Zero ERP — Database Audit

**Audit date:** 2026-11-04  
**Branch:** `feat/database-migrations`  
**Audit type:** Static source audit and follow-up verification of tenant-isolation and reporting fixes in the single consolidated bootstrap SQL file.  
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
| Explicit indexes | 29 |
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

## 4. Findings and remediation status

The following source-level defects identified in the earlier audit have been corrected in the canonical SQL file on this branch.

### Fixed — Inventory-adjustment numbering permission

`next_document_number` now maps `inventory_adjustment` to `inventory.adjust`. The allocator still requires an authenticated caller, active membership in the specified active organization, and that permission before incrementing the organization's sequence.

**Verification:** the final CASE mapping and the call from `post_inventory_adjustment` were inspected statically. No live posting test has been run.

### Fixed — Historical aging and unapplied-payment reversal cutoff

The receivables-aging, payables-aging, and unapplied-payments reports now evaluate reversals against the accounting-effective date recorded by the linked reversal journal entry (`reversal_journal_entry_id → journal_entries.entry_date`), rather than treating the current document status as if it had always applied.

- A payment reversed after the requested as-of date remains included in that historical snapshot; a payment reversed on or before the date is excluded.
- A sales or purchase invoice remains eligible when its current status is `returned`, because the return itself is applied only when its return date is on or before the requested date.
- A return reversed after the requested date remains applied to that historical snapshot; a return reversed on or before the date is excluded.
- A reversed expense or payment is treated as active for the snapshot only when its linked reversal journal entry is dated after the requested date.
- Unapplied-payment reporting follows the same reversal-date rule.

The reversal journal entry's `entry_date` is used because `reverse_journal_entry` accepts an explicit accounting reversal date. The wall-clock `reversed_at` field is audit metadata and is not the accounting cutoff.

**Verification:** final predicates and their links to the existing reversal journal entries were inspected statically. No PostgreSQL fixture execution or financial reconciliation has been run; runtime verification remains required.

### Fixed — Own inactive/historical membership metadata exposure

The self-read branch of `organization_users_select_member_or_self` now requires the caller's own membership to be active and its organization to be active. The separate `users.read` branch remains permission-scoped to the organization.

**Verification:** the final RLS predicate was inspected statically. No authenticated-JWT RLS test has been run.

### Fixed — Manual journal cross-tenant polymorphic reference validation

When a manual journal draft supplies a non-empty `reference_id`, `save_draft_transaction_document` now requires a `reference_type` and validates the target against a closed allowlist (`purchase`, `sale`, `expense`, `payment`, `purchase_return`, `sales_return`, `journal_entry`, and `inventory_adjustment`). Every lookup includes `organization_id = p_organization_id`; unsupported types and targets not found in that organization are rejected.

**Verification:** the final allowlist and tenant-scoped predicates were inspected statically. No adversarial RPC test has been run. This validation applies to the manual-journal draft RPC; the underlying polymorphic UUID column remains without a conventional FK.

### P2 — Creator Auth hard deletion remains intentionally blocked

`organization_users.user_id` references `auth.users(id) ON DELETE CASCADE`, while the original creator membership rejects DELETE. Hard deletion of the original creator's Auth row therefore attempts a cascade that the membership guard blocks.

**Operational implication:** disable/ban the creator's Auth account rather than hard-delete it while the organization exists. Supporting hard deletion would require a separately retained immutable creator identity, which is not present in the current schema.

### Maintainability — Repeated historical function definitions

The bootstrap contains multiple `CREATE OR REPLACE FUNCTION` definitions for several names. The last effective definition in execution order is authoritative. Update and inspect that final definition when changing behavior. Consolidating these definitions was deliberately deferred: removing an earlier definition without tracing intervening dependencies, trigger bindings, and privilege statements could change effective behavior. Do this only with regression coverage.

### Performance tuning — Evidence required before index changes

No speculative indexes or query rewrites were added. The repository has no representative production dataset or recorded `EXPLAIN (ANALYZE, BUFFERS)` baselines, so index changes cannot yet be shown to improve reads without imposing additional write/storage costs. Capture query plans on representative data before making performance-only schema changes.

## 5. Important boundaries and remaining operational caveats — do not document as implemented features

- `contacts` has no dedicated customer/supplier discriminator.
- `organization_users` supports one role per membership.
- `payment_allocations.document_id`, `journal_entries.reference_id` and `inventory_transactions.reference_id` are polymorphic UUID references, not ordinary foreign keys to all possible target tables. Manual-journal references are now validated by the draft RPC against same-organization targets, but the column itself remains polymorphic.
- The final schema contains no views or materialized views.
- No accounting-period table, accounting-period column, period permission, period-close function or period-lock workflow exists.
- The presence of a database RPC does not establish that a frontend screen or complete user workflow exists.
- The historical Administrator-transfer RPC is dropped by the final migration and must not be described as available.

## 6. Test and verification boundary

The repository branch currently contains one consolidated database SQL file and the documentation files; the earlier database smoke test and GitHub Actions SQL-test workflow were removed at the user's request. The remediation checks above are static source checks only. Therefore:

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
