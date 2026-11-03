# Zero ERP Database Audit

**Audit date:** 2026-11-03  
**Branch:** `feat/database-migrations`  
**Scope:** Static, line-by-line review of `supabase/initial_database_schema.sql` (4,870 lines before the latest small fixes), the database smoke test, workflow, README, and database blueprint.  
**Verification boundary:** This is a source audit. It is not a live Supabase audit and does not establish that the SQL has executed successfully on a real Supabase project. PostgreSQL runtime, Auth API, concurrency, and full-year accounting tests remain required.

## Executive summary

The schema is a substantial tenant-scoped PostgreSQL foundation, but it is **not yet a complete operational ERP database**. Its core tables, organization-scoped foreign keys, read RLS, permission catalog, and several atomic posting routines are present. However, the application cannot complete several essential setup and accounting workflows because the corresponding permission-checked RPCs do not exist and direct browser-role table writes are revoked.

### Static inventory

| Object | Count | Audit result |
|---|---:|---|
| Public tables | 27 | Present |
| Public RLS policies | 27 | One SELECT policy per table; write policies intentionally absent |
| Public functions | 28 | Includes helpers, trigger functions, and business RPCs |
| Triggers | 28 | Includes timestamp, role/admin protection, hierarchy, and period-overlap guards |
| Explicit indexes | 26 | Core tenant/date/source lookups covered; review query plans at scale |
| Permission keys | 45 | Seeded global permission catalog |
| Browser write access | 0 direct table writes intended | Mutations must use RPCs |

## Implemented and structurally sound

1. **Tenant model:** business tables carry `organization_id`; most tenant-owned references use composite organization-scoped foreign keys.
2. **Identity and membership:** Supabase Auth remains the identity source; membership uses `organization_users`; there is no duplicate profile table.
3. **Organization bootstrap:** `create_organization_with_admin` creates the organization, protected Administrator role, permission assignments, and creator membership in one transaction.
4. **RBAC enforcement:** `has_org_permission` checks active membership, active organization, active role, and the requested permission.
5. **Read isolation:** SELECT RLS predicates use module read permissions; child records inherit their parent module's read permission.
6. **Write boundary:** direct table writes are revoked from `anon` and `authenticated`; exposed business writes are intended to go through permission-checked RPCs.
7. **Document lifecycle:** draft save, confirmation, revert-to-draft, void, and draft deletion RPCs exist for supported document types.
8. **Posting paths:** purchase, sales, purchase return, sales return, expense, contact payment, opening balances, manual journal confirmation/posting, and supported journal reversals have dedicated database routines.
9. **Accounting/inventory controls:** period overlap and account hierarchy cycle guards exist; posting routines validate period dates and open status; inventory balances reject negative quantity/value; posting routines update ledger and stock within the same transaction.
10. **Security-definer hygiene:** security-definer functions pin an empty search path; trigger-only functions are explicitly revoked from client roles.
11. **Administrator protection:** system Administrator role protection and last-active-Administrator protection are implemented.
12. **Sales return cap:** confirmation/posting constrains returned net value to the proportional original net value of the returned source lines.

## Fixes applied in this audit

### 1. Invalid organization timezones could be stored

**Problem:** organization creation previously checked only that the timezone string was non-empty. Invalid values could be persisted and later cause inconsistent timestamp/reporting behavior.

**Fix:** `create_organization_with_admin` now validates the trimmed timezone against PostgreSQL's `pg_timezone_names` catalog and rejects unknown names with SQLSTATE `22023`.

### 2. Disabled document-number sequences were still consumed

**Problem:** `next_document_number` incremented an existing sequence without checking `is_active`. A disabled sequence could continue allocating numbers.

**Fix:** the conflict update now runs only when the existing sequence is active. If no row is returned, the function raises SQLSTATE `55000` and does not issue a number.

### 3. Smoke tests did not verify the actual RPC exposure boundary

**Problem:** the original smoke test checked only a few RPC grants and did not check that all intended RPCs were granted to authenticated users, denied to anonymous users, or that direct table writes remained unavailable.

**Fix:** the smoke test now checks the complete intended RPC grant list, confirms the legacy one-step journal RPC remains disabled, checks for direct table write grants/anonymous table access, and exercises organization creation with both invalid and valid timezones plus the disabled-sequence rejection path.

## Critical incomplete workflows

These are genuine blockers for a complete end-to-end ERP workflow. They are not safely fixed by granting direct table writes; each needs a permission-checked, tenant-scoped, transactional RPC and corresponding tests.

| Priority | Gap | Current state / consequence | Required implementation |
|---|---|---|---|
| P0 | Accounting period creation | `accounting_periods.manage` exists, but there is no create-period RPC and direct writes are revoked. A company cannot create its first period through the client. | Create-period RPC with permission, date validation, overlap serialization, and lifecycle rules. |
| P0 | Financial-year closing | Period status supports `closed`, but there is no close RPC, P&L close journal, retained-earnings transfer, close validation, or close idempotency. | Full close workflow: pre-close checks, P&L calculation, balanced closing journal, period lock, and next-year carry-forward. |
| P0 | Master-data CRUD | No permission-checked create/update RPCs for accounts, contacts, products, units, or expense categories. Direct client writes are revoked. | Add validated create/update/activation RPCs for each master-data domain. |
| P0 | Chart-of-accounts initialization | Organization creation creates only the tenant and Administrator. It does not seed a usable chart of accounts, accounting period, cash/bank, AR/AP control, revenue, COGS, inventory, or expense accounts. | Define a reviewed default COA template and an idempotent organization setup routine; allow controlled customization. |
| P0 | Full Auth lifecycle tests | Current CI uses plain PostgreSQL and a minimal `auth.uid()` shim. It does not test real Supabase signup, email verification, login, JWT claims, refresh, or logout. | Run Supabase local stack and test Auth HTTP endpoints with real local JWTs. |
| P1 | Custom roles | `roles.manage` exists, but there is no custom-role creation or permission-editing RPC. Administrators cannot configure custom roles safely. | Add create/update role and replace-permissions RPCs; protect Administrator and prevent privilege escalation. |
| P1 | Inventory adjustments | `inventory.adjust` exists, but there is no adjustment document or posting RPC. Stock corrections cannot be performed through the supported client boundary. | Add adjustment header/lines or a controlled adjustment RPC that posts inventory and GL effects atomically. |
| P1 | Automatic numbering integration | `next_document_number` exists but `save_draft_transaction_document` does not call it. Callers can supply their own numbers; automatic sequence allocation is not part of document creation. | Allocate numbers server-side on document creation and prevent caller override where automatic numbering is configured. |
| P1 | Invoice-level payment allocation | `payment_allocations` exists, but current payment posting is contact-level and explicitly rejects payments with allocation rows. Invoice outstanding/aging cannot be computed reliably. | Implement invoice subledger allocation, over-allocation protection, unapplied balances, and reversal/unallocation semantics. |
| P1 | Reports and financial statements | `reports.read` exists, but no reporting RPC/view contract is defined in this bootstrap. | Add tested trial balance, general ledger, P&L, balance sheet, cash/bank, inventory valuation, AR/AP and aging queries. |
| P1 | Organization profile updates | `organization.update` exists, but no organization update RPC is present. | Add a permission-checked organization update RPC with currency/timezone validation. |
| P1 | Invitation of new Auth users | The membership RPC adds an already existing verified Auth user; it does not create users or send invitations. | Add a trusted server/Edge Function using Supabase Auth Admin API; never expose service-role credentials to the browser. |
| P2 | Opening customer-credit / supplier-debit balances | Opening balance routine models customer receivables and supplier payables only. Opposite balances are not supported as opening party balances. | Define explicit credit/debit party balance handling and accounting semantics before implementation. |
| P2 | Full audit event history | Current rows retain selected confirmation/post/void/reversal metadata, but there is no immutable event history. | Decide whether a dedicated audit/event log is required; do not add it without product approval. |
| P2 | Polymorphic reference enforcement | `payment_allocations.document_id`, `journal_entries.reference_id`, and `inventory_transactions.reference_id` are polymorphic and cannot be fully validated by ordinary FKs. | Add target-type validation in controlled RPCs/triggers or replace polymorphic links with explicit foreign keys. |

## Additional technical observations

- The one-step `post_manual_journal_entry` function is intentionally not executable by browser roles. Manual journals should use Draft → Confirmed → `post_confirmed_journal_entry`; do not re-enable the legacy shortcut.
- `post_contact_payment` is a contact-level settlement model. It correctly refuses invoice-allocation rows rather than silently ignoring them.
- `payment_allocations` should be treated as dormant schema until its validation and posting semantics are implemented.
- `create_organization_with_admin` does not create the initial accounting period or chart of accounts. The product onboarding workflow must not present a newly created organization as ready to transact until setup is completed.
- The current schema assigns one role per membership. Multiple roles per user per organization would require a deliberate data-model migration.
- Contact records do not currently carry a customer/supplier discriminator. Workflows must validate party role from transaction context or introduce a controlled classification model.
- The bootstrap is a one-time empty-database script, not a production migration. Never apply it to a populated database.

## Test coverage status

| Test layer | Current coverage | Status |
|---|---|---|
| Clean PostgreSQL bootstrap | Workflow applies canonical SQL to PostgreSQL 17 | Configured; runtime result must be read from GitHub Actions |
| Schema catalog smoke checks | Table/policy counts, RLS, security-definer search path, triggers, grants, write boundary | Expanded in this audit |
| Organization setup guard tests | Invalid timezone rejection and valid org/admin creation | Added to smoke test |
| Number sequence guard test | Disabled sequence must reject allocation | Added to smoke test |
| Supabase Auth integration | Real signup/verify/login/JWT/refresh/logout | Not implemented |
| Tenant isolation with multiple real users | Cross-organization read/write/RPC denial | Not implemented |
| Business transaction integration | Purchase/sales/returns/expenses/payments/journals with reconciliation | Not implemented |
| Concurrency/idempotency | Double posting, simultaneous sequence allocation, last-admin race, close-vs-post race | Not implemented |
| Full financial-year close | Close journal, retained earnings, carry-forward, next-year trial balance | Not implemented |

## Recommended implementation order

1. Finish and run the updated schema smoke test in CI.
2. Implement accounting-period creation and full financial-year closing/carry-forward.
3. Implement default COA and complete master-data CRUD RPCs.
4. Implement inventory adjustment and automatic document numbering.
5. Implement invoice-level payment allocations and financial report queries.
6. Add Supabase local-stack Auth and multi-tenant integration tests.
7. Add a deterministic full-year scenario and reconcile subledgers, inventory valuation, trial balance, P&L, balance sheet, and next-year opening balances.

**Release assessment:** do not treat the database as production-ready for full-company operations or year-end closing until the P0 gaps and the real Supabase integration tests are completed and passing.
