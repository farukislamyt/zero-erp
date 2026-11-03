# Zero ERP

Zero ERP is a multi-organization ERP system designed to support accounting, purchasing, sales, inventory, expenses, payments, and returns.

## Technology Stack

- **Application framework:** Next.js
- **Database:** PostgreSQL
- **Backend platform:** Supabase
- **Deployment:** Vercel
- **Source control:** GitHub

## Overview

The database schema contains 27 tables total: 24 business tables plus three RBAC tables. The production data model uses role-based access control (RBAC) with `roles`, `permissions`, and `role_permissions`, plus `organization_users.role_id`. Each organization has a protected Administrator role automatically assigned to its creator. Administrators manage organization-specific custom roles and assign permissions from the system-managed catalog. Tenant isolation is enforced through organization-scoped relationships, database constraints, RPC authorization, and Row-Level Security (RLS).

This README and the database blueprint define the target relational model, tenant isolation, authorization, integrity rules, and transactional workflows.

## Table of Contents

- [Modules](#modules)
- [Database Schema](#database-schema)
- [Database Blueprint](docs/DATABASE_AND_SECURITY.md)
- [Accounting and Posting](#accounting-and-posting)
- [Inventory](#inventory)
- [Organization Isolation and Security](#organization-isolation-and-security)
- [Technology and Deployment](#technology-and-deployment)
- [Local Development](#local-development)
- [Documentation Notes](#documentation-notes)

## Modules

- Organization and membership management
- Role-based access control with a protected Administrator role and organization-specific custom roles
- Accounting periods and chart of accounts
- General ledger and journal entries
- Product catalog and units of measure
- Contacts for customers, suppliers, and other counterparties
- Purchase invoices and purchase returns
- Sales invoices and sales returns
- Inventory movements and valuation
- Expense categories and expense records
- Payments and payment allocations
- Organization-specific document numbering

These modules are inferred from the supplied database schema. Their availability in the user interface and implementation completeness must be verified in the application.

## Database Blueprint

For the logical ER diagram, schema dependency order, relationship map, table inventory, integrity constraints, RPC contracts, RLS policy matrix, verification SQL, RBAC workflow, and production release checklist, see the [Database Blueprint](docs/DATABASE_AND_SECURITY.md).

## Database Schema


The executable bootstrap SQL is maintained in **[`supabase/initial_database_schema.sql`](supabase/initial_database_schema.sql)**. It consolidates the complete database schema, seed data, RLS policies, grants, and posting RPCs into one ordered script. Run it only once against a new/empty Supabase database; do not run it as an upgrade against a database that already contains these objects.

### Organization and configuration

| Table | Purpose | Notable columns |
| --- | --- | --- |
| `organizations` | Organization profile and defaults | `name`, `currency`, `timezone`, `tin`, `bin`, `is_active` |
| `organization_users` | Links users to organizations and, assigns a role within that organization | `organization_id`, `user_id`, `role_id`, `is_active` |
| `units_of_measure` | Product measurement units | `name`, `is_active` |
| `accounting_periods` | Accounting date ranges and closure state | `start_date`, `end_date`, `status`, `closed_at`, `closed_by` |
| `number_sequences` | Document number configuration | `document_type`, `prefix`, `next_number`, `padding` |

### Access control

| Table | Purpose | Notable columns |
| --- | --- | --- |
| `roles` | Organization-scoped roles, including a protected predefined Administrator role | `organization_id`, `name`, `status`, `is_system_role` |
| `permissions` | Global catalog of granular application actions | `permission_key`, `name`, `module`, `description` |
| `role_permissions` | Many-to-many mapping between roles and permissions | `role_id`, `permission_id` |

The permission catalog is global and roles are organization-specific. Each organization has a predefined, protected `Administrator` role; the organization creator receives that role automatically. Administrators create custom roles and select permissions from the system-managed catalog. `role_permissions` maps roles to permissions, and `organization_users.role_id` assigns one role to each membership.

### General ledger

| Table | Purpose | Notable columns |
| --- | --- | --- |
| `accounts` | Chart of accounts and hierarchy | `account_code`, `account_name`, `account_type`, `parent_account_id`, `normal_balance`, `is_postable` |
| `journal_entries` | Journal entry headers and lifecycle | `entry_number`, `accounting_period_id`, `entry_date`, `entry_type`, `status`, `confirmed_at`, `confirmed_by`, `posted_at`, `posted_by`, `voided_at`, `voided_by`, `void_reason`, `reversal_of_id` |
| `account_transactions` | Debit/credit journal lines | `journal_entry_id`, `account_id`, `line_number`, `debit`, `credit`, `contact_id` |

### Products, contacts, and inventory

| Table | Purpose | Notable columns |
| --- | --- | --- |
| `products` | Product records and related ledger accounts | `product_code`, `name`, `unit_id`, `inventory_account_id`, `sales_account_id`, `cogs_account_id` |
| `contacts` | Business contact records | `contact_number`, `name`, `phone`, `email`, `address` |
| `inventory_balances` | Current quantity and valuation summary | `product_id`, `quantity`, `average_cost`, `inventory_value` |
| `inventory_transactions` | Inventory movement and cost history | `transaction_number`, `product_id`, `transaction_date`, `transaction_type`, `direction`, `quantity`, `unit_cost`, `total_value`, `average_cost_after` |

### Purchases and purchase returns

| Table | Purpose | Notable columns |
| --- | --- | --- |
| `purchase` | Purchase invoice header | `invoice_id`, `supplier_id`, `invoice_date`, `status`, `confirmed_at`, `confirmed_by`, `posted_by`, `voided_at`, `voided_by`, `void_reason`, `subtotal`, `discount_amount`, `total_amount`, `payable_account_id`, `posted_journal_entry_id` |
| `purchase_items` | Purchase invoice lines | `purchase_id`, `line_number`, `product_id`, `quantity`, `unit_cost`, `line_total` |
| `purchase_returns` | Purchase return header | `return_number`, `purchase_id`, `supplier_id`, `return_date`, `total_amount`, `posted_journal_entry_id` |
| `purchase_return_items` | Purchase return lines | `purchase_return_id`, `purchase_item_id`, `product_id`, `quantity`, `unit_cost`, `line_total` |

### Sales and sales returns

| Table | Purpose | Notable columns |
| --- | --- | --- |
| `sales` | Sales invoice header | `invoice_id`, `customer_id`, `invoice_date`, `status`, `confirmed_at`, `confirmed_by`, `posted_by`, `voided_at`, `voided_by`, `void_reason`, `subtotal`, `discount_amount`, `total_amount`, `receivable_account_id`, `posted_journal_entry_id` |
| `sales_items` | Sales lines and cost-of-goods-sold values | `sales_id`, `line_number`, `product_id`, `quantity`, `unit_price`, `line_total`, `cogs_unit_cost`, `cogs_total` |
| `sales_returns` | Sales return header | `return_number`, `sales_id`, `customer_id`, `return_date`, `total_amount`, `posted_journal_entry_id` |
| `sales_return_items` | Sales return lines and cost values | `sales_return_id`, `sales_item_id`, `product_id`, `quantity`, `unit_price`, `line_total`, `cogs_unit_cost`, `cogs_total` |

### Expenses and payments

| Table | Purpose | Notable columns |
| --- | --- | --- |
| `expense_categories` | Expense classification and ledger mapping | `category_code`, `name`, `expense_account_id`, `is_active` |
| `expenses` | Expense records | `expense_number`, `expense_category_id`, `contact_id`, `payable_account_id`, `expense_date`, `amount`, `status`, `confirmed_at`, `confirmed_by`, `posted_by`, `voided_at`, `voided_by`, `void_reason`, `posted_journal_entry_id` |
| `payments` | Payment records and ledger accounts | `payment_number`, `payment_type`, `contact_id`, `payment_date`, `amount`, `account_id`, `settlement_account_id`, `status`, `confirmed_at`, `confirmed_by`, `posted_by`, `voided_at`, `voided_by`, `void_reason`, `posted_journal_entry_id` |
| `payment_allocations` | Allocates payments to referenced documents | `payment_id`, `document_type`, `document_id`, `allocated_amount` |


### Complete Column Reference

The complete data model documents 24 business tables plus three RBAC tables (27 total), including the membership role reference.

<details>
<summary>organizations (14 columns)</summary>

`id`, `name`, `phone`, `email`, `address`, `city`, `country`, `currency`, `timezone`, `tin`, `bin`, `is_active`, `created_at`, `updated_at`

</details>

<details>
<summary>organization_users (7 columns)</summary>

`id`, `organization_id`, `user_id`, `role_id`, `is_active`, `created_at`, `updated_at`.

`role_id` references `roles.id`. This design assigns one role per user membership. If multiple roles per user per organization are required later, use a separate membership-role junction table.

</details>

<details>
<summary>roles (7 columns)</summary>

`id`, `organization_id`, `name`, `status`, `is_system_role`, `created_at`, `updated_at`

</details>

<details>
<summary>permissions (7 columns)</summary>

`id`, `permission_key`, `name`, `description`, `module`, `created_at`, `updated_at`

</details>

<details>
<summary>role_permissions (4 columns)</summary>

`id`, `role_id`, `permission_id`, `created_at`

</details>

<details>
<summary>units_of_measure (6 columns)</summary>

`id`, `organization_id`, `name`, `is_active`, `created_at`, `updated_at`

</details>

<details>
<summary>accounting_periods (10 columns)</summary>

`id`, `organization_id`, `name`, `start_date`, `end_date`, `status`, `closed_at`, `closed_by`, `created_at`, `updated_at`

</details>

<details>
<summary>accounts (13 columns)</summary>

`id`, `organization_id`, `account_code`, `account_name`, `account_type`, `parent_account_id`, `normal_balance`, `is_control_account`, `is_system_account`, `is_postable`, `is_active`, `created_at`, `updated_at`

</details>

<details>
<summary>products (12 columns)</summary>

`id`, `organization_id`, `product_code`, `name`, `unit_id`, `inventory_account_id`, `sales_account_id`, `cogs_account_id`, `is_active`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>contacts (11 columns)</summary>

`id`, `organization_id`, `contact_number`, `name`, `phone`, `email`, `address`, `is_active`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>number_sequences (9 columns)</summary>

`id`, `organization_id`, `document_type`, `prefix`, `next_number`, `padding`, `is_active`, `created_at`, `updated_at`

</details>

<details>
<summary>journal_entries (15 columns)</summary>

`id`, `organization_id`, `entry_number`, `accounting_period_id`, `entry_date`, `entry_type`, `status`, `reference_type`, `reference_id`, `description`, `posted_at`, `reversal_of_id`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>account_transactions (10 columns)</summary>

`id`, `organization_id`, `journal_entry_id`, `account_id`, `line_number`, `description`, `debit`, `credit`, `contact_id`, `created_at`

</details>

<details>
<summary>purchase (14 columns)</summary>

`id`, `organization_id`, `invoice_id`, `supplier_id`, `invoice_date`, `status`, `subtotal`, `discount_amount`, `total_amount`, `payable_account_id`, `posted_journal_entry_id`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>purchase_items (10 columns)</summary>

`id`, `organization_id`, `purchase_id`, `line_number`, `product_id`, `quantity`, `unit_cost`, `line_total`, `created_at`, `updated_at`

</details>

<details>
<summary>sales (14 columns)</summary>

`id`, `organization_id`, `invoice_id`, `customer_id`, `invoice_date`, `status`, `subtotal`, `discount_amount`, `total_amount`, `receivable_account_id`, `posted_journal_entry_id`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>sales_items (12 columns)</summary>

`id`, `organization_id`, `sales_id`, `line_number`, `product_id`, `quantity`, `unit_price`, `line_total`, `cogs_unit_cost`, `cogs_total`, `created_at`, `updated_at`

</details>

<details>
<summary>inventory_balances (7 columns)</summary>

`id`, `organization_id`, `product_id`, `quantity`, `average_cost`, `inventory_value`, `updated_at`

</details>

<details>
<summary>inventory_transactions (16 columns)</summary>

`id`, `organization_id`, `transaction_number`, `product_id`, `transaction_date`, `transaction_type`, `direction`, `quantity`, `unit_cost`, `total_value`, `reference_type`, `reference_id`, `unit_cost_before`, `average_cost_after`, `created_by`, `created_at`

</details>

<details>
<summary>expense_categories (8 columns)</summary>

`id`, `organization_id`, `category_code`, `name`, `expense_account_id`, `is_active`, `created_at`, `updated_at`

</details>

<details>
<summary>expenses (14 columns)</summary>

`id`, `organization_id`, `expense_number`, `expense_category_id`, `contact_id`, `payable_account_id`, `expense_date`, `amount`, `description`, `status`, `posted_journal_entry_id`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>payments (15 columns)</summary>

`id`, `organization_id`, `payment_number`, `payment_type`, `contact_id`, `payment_date`, `amount`, `account_id`, `settlement_account_id`, `status`, `posted_journal_entry_id`, `description`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>payment_allocations (8 columns)</summary>

`id`, `organization_id`, `payment_id`, `document_type`, `document_id`, `allocated_amount`, `created_at`, `updated_at`

</details>

<details>
<summary>purchase_returns (15 columns)</summary>

`id`, `organization_id`, `return_number`, `purchase_id`, `supplier_id`, `return_date`, `status`, `subtotal`, `discount_amount`, `total_amount`, `payable_account_id`, `posted_journal_entry_id`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>purchase_return_items (11 columns)</summary>

`id`, `organization_id`, `purchase_return_id`, `line_number`, `purchase_item_id`, `product_id`, `quantity`, `unit_cost`, `line_total`, `created_at`, `updated_at`

</details>

<details>
<summary>sales_returns (15 columns)</summary>

`id`, `organization_id`, `return_number`, `sales_id`, `customer_id`, `return_date`, `status`, `subtotal`, `discount_amount`, `total_amount`, `receivable_account_id`, `posted_journal_entry_id`, `created_by`, `created_at`, `updated_at`

</details>

<details>
<summary>sales_return_items (13 columns)</summary>

`id`, `organization_id`, `sales_return_id`, `line_number`, `sales_item_id`, `product_id`, `quantity`, `unit_price`, `line_total`, `cogs_unit_cost`, `cogs_total`, `created_at`, `updated_at`

</details>

**Schema note:** This reference summarizes the tables and columns supplied for documentation. It does not define SQL types or prove that foreign keys, unique constraints, indexes, check constraints, triggers, or row-level security (RLS) policies exist. Confirm those details in the actual migrations or database DDL.

## Accounting and Posting

The ledger model separates journal headers (`journal_entries`) from journal lines (`account_transactions`). Business documents include a `posted_journal_entry_id` reference where applicable.

Required accounting controls:

1. A posted journal entry must have at least the required lines and total debits equal to total credits.
2. The entry date must be valid for its accounting period.
3. Posting to a closed accounting period must be blocked unless an explicit, authorized exception exists.
4. Posting must be atomic: the business document, journal entry, journal lines, and related inventory effects must succeed or fail together.
5. Prevent duplicate posting and use controlled reversal entries to correct posted activity.
6. Validate that accounts, contacts, products, periods, and source documents belong to the same organization.

Transaction documents follow Draft → Confirmed → Posted. Drafts may be edited/deleted; Confirmed documents are locked but may be reverted to Draft; Draft/Confirmed documents may be voided with a reason; Posted records cannot be edited or hard-deleted and require a controlled reversal/return. Confirmation itself has no ledger or inventory impact; posting is the only source-document step that applies those effects. See [Database Blueprint](docs/DATABASE_AND_SECURITY.md#financial-and-inventory-transaction-lifecycle) for enforced RPCs and known posting-coverage limitations.

## Inventory

The schema separates movement history (`inventory_transactions`) from the current summary (`inventory_balances`). Product and sales line records also include fields related to inventory, sales, and cost of goods sold.

Document and test the exact rules for:

- Purchase receipts and stock increases
- Sales and stock decreases
- Purchase and sales returns
- Inventory adjustments
- Average-cost calculations and rounding
- Negative stock and non-inventory products
- Reconciliation between transaction history and balance snapshots

The presence of valuation fields does not, by itself, establish which costing algorithm or transaction timing is implemented.

## Organization Isolation and Security

Most business tables include `organization_id`. This is useful for multi-tenant data partitioning, but tenant isolation must be enforced by database policies and application authorization.

Required controls:

- Enable and test Supabase RLS policies on tables exposed through the Supabase API.
- Verify the authenticated user's organization membership for every read and write.
- Never trust a client-supplied `organization_id` without server-side or database authorization.
- Scope record access by both record ID and organization ID.
- Validate organization ownership for every referenced record.
- Consider organization-scoped unique constraints for account codes, product codes, contact numbers, and document numbers.
- Keep elevated Supabase service-role credentials server-side only.
- Store secrets in local environment files and deployment settings, never in source control.
- Test cross-organization access explicitly.

The supplied `organization_users` schema does not currently include a role column. The defined RBAC design adds `role_id` to `organization_users` so each membership has one role per organization. When an organization is created, the trusted server-side workflow must create the organization, create its predefined `Administrator` role, assign the system-defined permissions to that role, and create the creator's membership with that role. These steps must be atomic so an organization cannot be left without its initial Administrator.

### RBAC model

- `roles`: organization-scoped role definitions with `id`, `organization_id`, `name`, `status`, `is_system_role`, `created_at`, and `updated_at`. Create one protected `Administrator` role per organization. `is_system_role` explicitly identifies protected system roles; do not rely only on the role name. Administrators can create custom roles for their organization.
- `permissions`: a global catalog of granular actions with `id`, `permission_key`, `name`, `description`, `module`, `created_at`, and `updated_at`. Permission definitions must be system-managed; Administrators select from this catalog when configuring custom roles. Example keys include `sales.read`, `sales.create`, `sales.post`, `inventory.read`, and `users.manage`.
- `role_permissions`: join table associating roles with permission definitions, using `role_id` and `permission_id` foreign keys. Fields: `id`, `role_id`, `permission_id`, and `created_at`.
- `organization_users.role_id`: defined foreign key to `roles.id`, assigning a role to that membership. Validate that the assigned role belongs to the same organization as the membership.

Production database constraints: enforce unique `(organization_id, name)` on `roles`; unique `permission_key` on `permissions`; unique `(role_id, permission_id)` on `role_permissions`; foreign keys from `role_permissions.role_id` to `roles.id`, from `role_permissions.permission_id` to `permissions.id`, and from `organization_users.role_id` to `roles.id`. Prevent ordinary role-management operations from deleting or deactivating the system Administrator role or removing critical administrative permissions. Ensure an organization cannot be left without an authorized Administrator.

Authorization must be deny-by-default and enforced server-side and, where applicable, through Supabase RLS. Check the user's active organization membership and required permission for every protected action. A permission record alone does not enforce access. Because `roles` are organization-scoped while `permissions` are global, ensure all role assignments and permission checks remain within the active organization. Frontend controls may hide unavailable actions, but must not be the only enforcement layer.

## Technology and Deployment

### Next.js

Next.js is the web application framework. Follow the project’s existing routing, server/client component, and data-access conventions.

### Supabase and PostgreSQL

Supabase provides the PostgreSQL platform and may provide authentication or other backend services depending on configuration. Use migrations to version database changes and test schema updates in a non-production environment.

### Vercel

Vercel is the deployment target. Configure environment variables for each relevant environment and verify the production build and database connectivity before releasing changes.

## Local Development

The exact package manager, scripts, and migration commands have not been verified in this README. Check the repository's `package.json`, lockfile, and migration setup before using commands.

General workflow:

1. Clone the repository:
   ```bash
   git clone https://github.com/farukislamyt/zero-erp.git
   cd zero-erp
   ```
2. Install dependencies using the package manager specified by the repository.
3. Configure the required environment variables.
4. Apply database migrations using the project's established migration workflow.
5. Run the development command defined in `package.json`.
6. Run the available lint, type-check, test, and production-build scripts before submitting changes.

### Environment variables

Use only the variables required by the actual application. A Supabase setup may use variables such as:

| Variable | Purpose | Security |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project endpoint | Intended to be public |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` or a publishable key | Client-side Supabase access, if used | Must be protected by RLS and permissions |
| `SUPABASE_SERVICE_ROLE_KEY` | Elevated server-side access, if required | Secret; server only |
| `DATABASE_URL` | Direct PostgreSQL connection, if required by server tooling | Secret; never commit it |

Do not add unused variables just because they appear in this example. Never expose service-role credentials or database passwords to browser code.

## Documentation Notes

The following details must be added after confirming them from the codebase:

- Actual supported Node.js version and package manager
- Exact install, development, lint, test, type-check, and build commands
- Database migration and seed-data procedure
- Authentication and organization membership flow
- Implemented Supabase RLS policies
- Document status values and posting/reversal rules
- Inventory costing method and stock movement timing
- Screenshots or a demo link
- License and contribution requirements

## Contributing

Keep changes focused and consistent with the existing codebase. Include migrations for database changes, explain any effects on existing data, and run the available checks before opening a pull request.

## License

A license has not been specified in the supplied project information. Add the chosen license before distributing or reusing the project publicly.
