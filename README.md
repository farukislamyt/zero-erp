# Zero ERP — Database

Zero ERP's database is a tenant-scoped PostgreSQL schema for organization management, role-based access control, accounting, inventory, purchasing, sales, returns, expenses, payments and reporting.

## Database documentation

| Document | Purpose |
|---|---|
| [Complete Database Reference](docs/DATABASE_REFERENCE.md) | Exhaustive table-by-table catalog: every column, constraint, index, trigger, RLS policy, function/RPC signature, permission key and privilege statement. |
| [Database Architecture and Security](docs/DATABASE_AND_SECURITY.md) | Effective data model, tenant isolation, Creator/Administrator invariants, RLS/RBAC and transactional workflows. |
| [Database Audit](docs/DATABASE_AUDIT.md) | Static audit findings, known limitations and verification boundary. |
| [Database Test Specification](docs/DATABASE_TEST_SPECIFICATION.md) | RPC input contracts, permissions, success/failure cases, expected ledger/inventory states and coverage plan. |

## Canonical database SQL file

The complete database bootstrap is maintained in one file:

- [`supabase/migrations/20261103000000_initial_database_schema.sql`](supabase/migrations/20261103000000_initial_database_schema.sql) — contains the complete schema, membership/RBAC security, permanent original-Creator Administrator protections, seeds, functions, triggers, RLS policies and grants.

The file is intended to initialize a **new/empty Supabase database**. It contains the effective SQL previously split across three files, in execution order, inside one transaction. Do not run it against an already populated database.

## Effective schema at a glance

- 26 public tables and 349 columns.
- 129 declared table constraints.
- 29 effective explicit indexes.
- RLS enabled on all 26 public tables with 26 installed SELECT policies.
- 37 effective triggers.
- 53 effective public functions.
- 43 seeded permission keys.
- No SQL views, materialized views, user-defined sequences, custom enum/type/domain definitions, or accounting-period subsystem.

See the [Complete Database Reference](docs/DATABASE_REFERENCE.md) for exact definitions. If prose documentation and executable SQL ever differ, the bootstrap SQL file is authoritative; update the documentation from the SQL rather than changing the database to match stale prose.

## Current database boundaries

- Each organization is a tenant. Tenant-owned references are protected by organization-scoped foreign keys where defined.
- Each membership has one role. The permission catalog is global; roles are organization-scoped.
- The original creator membership is the permanent, immutable Administrator for the organization's lifetime. Administrator transfer is not supported.
- Direct browser-role table writes are revoked; authenticated clients use explicitly granted, permission-checked RPCs.
- Database-defined routines include draft/confirm/post document handling, journal reversals, payment allocations, document numbering, opening balances and financial/operational reports. Inventory-adjustment numbering checks `inventory.adjust`; aging and unapplied-payment reports account for accounting-dated reversals in historical snapshots; manual journal references are validated against same-organization records.
- The presence of a database RPC does not by itself prove that a corresponding frontend screen or workflow exists.

## Verification

A disposable local Supabase CI environment is defined by [`supabase/config.toml`](supabase/config.toml) and [Database CI](.github/workflows/database-ci.yml). The workflow applies the canonical bootstrap to an empty local database and runs the pgTAP baseline in `supabase/tests/database`.

The pgTAP test suite now contains five files covering schema/privilege contracts, company and master-data setup, opening balances, Cash–Bank transfers, purchases, sales, expenses, inventory adjustments, manual journals and reversals, returns, payment allocations, reporting, role/member onboarding and two-tenant isolation. The detailed case-by-case contract and remaining runtime coverage are tracked in the [Database Test Specification](docs/DATABASE_TEST_SPECIFICATION.md). A workflow run must pass before runtime verification is claimed.

The CI environment is disposable and local to the GitHub Actions runner. It must never connect to Production. No new SQL migration is introduced by the test infrastructure.
