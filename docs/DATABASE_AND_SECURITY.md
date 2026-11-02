# Zero ERP — Database, Relationships, RPCs, and RLS

> **Documentation status:** This is the canonical design/reference document for the schema inventory provided to the project. The repository inspection available for this update did not expose SQL migrations, database DDL, PostgreSQL function definitions, or Supabase policy definitions. Therefore, the table inventory and columns below reflect the supplied schema notes, while foreign keys, RPCs, and RLS policies are classified as **relationships to implement/verify** or **recommended design**, not as confirmed deployed objects. No application code or database schema was changed by this documentation update.

## 1. System model

Zero ERP is a multi-organization ERP. An authenticated person can be a member of one or more organizations. Every business operation must be scoped to the active organization, and every referenced business record must belong to that same organization.

Core domains:

1. **Tenant and membership:** `organizations`, `organization_users`
2. **Access control (proposed):** `roles`, `permissions`, `role_permissions`
3. **Accounting setup:** `accounting_periods`, `accounts`, `number_sequences`
4. **Master data:** `contacts`, `products`, `units_of_measure`, `expense_categories`
5. **Accounting ledger:** `journal_entries`, `account_transactions`
6. **Inventory:** `inventory_transactions`, `inventory_balances`
7. **Purchasing:** `purchase`, `purchase_items`, `purchase_returns`, `purchase_return_items`
8. **Sales:** `sales`, `sales_items`, `sales_returns`, `sales_return_items`
9. **Expenses and cash/bank activity:** `expenses`, `payments`, `payment_allocations`

The supplied inventory has 24 existing tables. The three RBAC tables and `organization_users.role_id` are proposed additions; if implemented, the model will contain 27 tables.

## 2. Relationship map

The relationships below are inferred from column names and ERP semantics. Confirm each FK against the actual migrations/DDL before treating it as deployed.

### Tenant and access control

| Parent | Child / linking column | Cardinality | Notes |
| --- | --- | --- | --- |
| `organizations.id` | `organization_users.organization_id` | 1:N | Organization membership records |
| Auth user ID | `organization_users.user_id` | User-to-membership 1:N | The exact auth schema/provider FK must be verified |
| `organizations.id` | `roles.organization_id` (proposed) | 1:N | Each organization's roles are isolated |
| `roles.id` | `organization_users.role_id` (proposed) | 1:N | One role per membership in this design |
| `roles.id` | `role_permissions.role_id` (proposed) | 1:N | Role-to-permission join rows |
| `permissions.id` | `role_permissions.permission_id` (proposed) | 1:N | Global system permission catalog |
| `roles` ↔ `permissions` | `role_permissions` | M:N | Unique pair `(role_id, permission_id)` |

### Accounting setup and ledger

| Parent | Child / linking column | Cardinality | Notes |
| --- | --- | --- | --- |
| `organizations.id` | `accounting_periods.organization_id` | 1:N | Periods belong to one organization |
| `organizations.id` | `accounts.organization_id` | 1:N | Chart of accounts per organization |
| `accounts.id` | `accounts.parent_account_id` | Self-referencing 1:N | Account hierarchy; parent and child must share organization |
| `accounting_periods.id` | `journal_entries.accounting_period_id` | 1:N | Entry should fall within the period's dates |
| `journal_entries.id` | `account_transactions.journal_entry_id` | 1:N | Journal header and its debit/credit lines |
| `accounts.id` | `account_transactions.account_id` | 1:N | Each line posts to an account |
| `contacts.id` | `account_transactions.contact_id` | 1:N, optional | Contact dimension on a ledger line |
| `journal_entries.id` | `journal_entries.reversal_of_id` | Self-reference, optional | Reversal entry points to original entry |
| `journal_entries.id` | Business documents' `posted_journal_entry_id` | 1:0..N references | Purchases, sales, returns, expenses, and payments can reference posting entries; decide if one-to-one uniqueness is required |
| `organizations.id` | `number_sequences.organization_id` | 1:N | Sequence per organization and document type |

### Master data and inventory

| Parent | Child / linking column | Cardinality | Notes |
| --- | --- | --- | --- |
| `organizations.id` | `units_of_measure.organization_id` | 1:N | Organization-specific units |
| `organizations.id` | `products.organization_id` | 1:N | Product catalog |
| `units_of_measure.id` | `products.unit_id` | 1:N | Product base unit |
| `accounts.id` | `products.inventory_account_id`, `sales_account_id`, `cogs_account_id` | 1:N per role | Ledger mapping; all accounts must belong to the product's organization |
| `organizations.id` | `contacts.organization_id` | 1:N | Customers, suppliers, and counterparties |
| `organizations.id` | `inventory_balances.organization_id` | 1:N | Organization-scoped stock snapshot |
| `products.id` | `inventory_balances.product_id` | 1:N logically; usually one current balance per product | Recommended unique `(organization_id, product_id)` if one row is intended |
| `products.id` | `inventory_transactions.product_id` | 1:N | Inventory movement history |
| `contacts.id` | Purchase/sales/return/payment/expense counterparty columns | 1:N | Supplier/customer/contact references; validate exact FK columns |
| `expense_categories.id` | `expenses.expense_category_id` | 1:N | Expense classification |
| `accounts.id` | `expense_categories.expense_account_id` | 1:N | Expense category ledger mapping |

### Purchases and purchase returns

| Parent | Child / linking column | Cardinality | Notes |
| --- | --- | --- | --- |
| `purchase.id` | `purchase_items.purchase_id` | 1:N | Invoice header and lines |
| `purchase.id` | `purchase_returns.purchase_id` | 1:N | Returns against a purchase invoice |
| `purchase_returns.id` | `purchase_return_items.purchase_return_id` | 1:N | Return header and lines |
| `purchase_items.id` | `purchase_return_items.purchase_item_id` | 1:N | Links a return line to its original purchase line |
| `products.id` | `purchase_items.product_id`, `purchase_return_items.product_id` | 1:N | Purchased/returned product |
| `contacts.id` | `purchase.supplier_id`, `purchase_returns.supplier_id` | 1:N | Must resolve to a supplier/contact in the same organization |
| `accounts.id` | `purchase.payable_account_id`, `purchase_returns.payable_account_id` | 1:N | Accounts payable mapping |
| `journal_entries.id` | `purchase.posted_journal_entry_id`, `purchase_returns.posted_journal_entry_id` | 1:0..1 recommended | Posting reference |

### Sales and sales returns

| Parent | Child / linking column | Cardinality | Notes |
| --- | --- | --- | --- |
| `sales.id` | `sales_items.sales_id` | 1:N | Sales invoice header and lines |
| `sales.id` | `sales_returns.sales_id` | 1:N | Returns against a sales invoice |
| `sales_returns.id` | `sales_return_items.sales_return_id` | 1:N | Return header and lines |
| `sales_items.id` | `sales_return_items.sales_item_id` | 1:N | Links a return line to its original sales line |
| `products.id` | `sales_items.product_id`, `sales_return_items.product_id` | 1:N | Sold/returned product |
| `contacts.id` | `sales.customer_id`, `sales_returns.customer_id` | 1:N | Must resolve to a customer/contact in the same organization |
| `accounts.id` | `sales.receivable_account_id`, `sales_returns.receivable_account_id` | 1:N | Accounts receivable mapping |
| `journal_entries.id` | `sales.posted_journal_entry_id`, `sales_returns.posted_journal_entry_id` | 1:0..1 recommended | Posting reference |

### Expenses and payments

| Parent | Child / linking column | Cardinality | Notes |
| --- | --- | --- | --- |
| `expense_categories.id` | `expenses.expense_category_id` | 1:N | Category for each expense |
| `contacts.id` | `expenses.contact_id`, `payments.contact_id` | 1:N, optional | Counterparty/contact |
| `accounts.id` | `expenses.payable_account_id` | 1:N, optional | Payable/settlement account mapping |
| `accounts.id` | `payments.account_id`, `payments.settlement_account_id` | 1:N | Payment source and settlement accounts |
| `payments.id` | `payment_allocations.payment_id` | 1:N | One payment can be split across documents |
| `journal_entries.id` | `expenses.posted_journal_entry_id`, `payments.posted_journal_entry_id` | 1:0..1 recommended | Ledger posting reference |

**Polymorphic references:** `payment_allocations.document_type/document_id`, `journal_entries.reference_type/reference_id`, and `inventory_transactions.reference_type/reference_id` are polymorphic patterns. A normal SQL foreign key cannot validate `document_id` against several possible tables. Validate document type, record existence, and matching organization in a trusted database function/trigger or application service, or replace the polymorphic reference with explicit nullable FKs where appropriate.

## 3. Data integrity constraints to implement/verify

These are recommendations, not a claim that constraints currently exist.

### Tenant integrity
- All organization-owned records must have a valid `organization_id`.
- Every FK from one organization-owned record to another must remain within the same organization. A plain FK on `id` alone does not prove tenant equality. Consider composite unique keys such as `UNIQUE (organization_id, id)` and composite FKs for tenant-scoped references.
- Enforce organization-scoped uniqueness for business identifiers, e.g. account code, product code, contact number, document number, and sequence type.
- Add appropriate indexes for `organization_id`, FK columns, date filters, status filters, and frequent lookup paths.

### Ledger integrity
- `debit >= 0` and `credit >= 0`; a line should not have both debit and credit positive.
- A posted journal entry must balance: sum(debit) = sum(credit), within the chosen currency precision.
- Use a controlled posting function/transaction to prevent a header becoming posted before its lines and related document/inventory effects are committed.
- Prevent duplicate posting, and use a reversal entry rather than editing posted ledger lines.
- Prevent posting into closed accounting periods unless an explicit, authorized exception is recorded.

### Inventory integrity
- Use positive quantities for movement magnitude and store direction separately, or define and enforce one consistent sign convention.
- Prevent accidental duplicate inventory movements for the same source document/line.
- Reconcile inventory movement history with `inventory_balances`; update both atomically.
- Decide and document costing method, rounding, negative-stock policy, return costing, and treatment of non-inventory products.

### Documents and allocations
- Validate line quantities, prices, totals, discounts, and amounts on the server/database—not only in the UI.
- Ensure return quantities do not exceed eligible original quantities, accounting for previous returns.
- Ensure payment allocations are non-negative and their sum does not exceed the available/unallocated payment amount, unless over-allocation is an explicit feature.
- Define allowed status transitions and make posting/reversal idempotent.

## 4. RPC inventory

**No deployed PostgreSQL RPC/function definitions could be confirmed from the repository files available for this documentation update.** The following is a recommended RPC catalogue for Supabase/PostgreSQL. Treat these as design names, not as existing callable endpoints. Use `supabase.rpc(...)` only after the corresponding function has been created, secured, and tested.

| Proposed RPC | Purpose | Important guarantees |
| --- | --- | --- |
| `create_organization_with_admin(p_name, ...)` | Create organization, protected Administrator role, role-permission links, and creator membership | Single transaction; derive creator from `auth.uid()`; never accept arbitrary creator user ID from an untrusted client |
| `assign_member_role(p_membership_id, p_role_id)` | Assign a role to an organization membership | Caller must be authorized Administrator; role and membership must belong to the same organization |
| `create_custom_role(p_organization_id, p_name, p_status)` | Create organization-scoped custom role | Verify caller membership and role-management permission; enforce unique organization/name |
| `set_role_permissions(p_role_id, p_permission_ids)` | Replace/update permissions on a custom role | Validate each permission against global catalog; block unsafe modification of protected Administrator role |
| `post_journal_entry(p_entry_id)` | Validate and post a journal entry | Balance debits/credits; check period, organization, permissions, idempotency; commit status and posting atomically |
| `reverse_journal_entry(p_entry_id, p_date, p_reason)` | Create controlled reversal | Require authorization; preserve original entry; validate target period; prevent repeated reversal |
| `post_purchase(p_purchase_id)` | Post purchase and associated inventory/accounting effects | Validate supplier, lines, accounts, period, and tenant; atomically create ledger/inventory effects |
| `post_sales(p_sales_id)` | Post sale and associated inventory/accounting effects | Validate customer, stock policy, lines, accounts, and tenant; atomically create ledger/inventory effects |
| `post_purchase_return(p_return_id)` | Post purchase return | Validate source purchase/line quantities and tenant; atomically update stock and ledger |
| `post_sales_return(p_return_id)` | Post sales return | Validate source sale/line quantities and tenant; atomically update stock and ledger |
| `record_payment_and_allocate(p_payment, p_allocations)` | Record payment and allocate it to documents | Validate allocation totals and document ownership; atomically post accounting effects |
| `close_accounting_period(p_period_id)` | Close a period | Require permission; validate unresolved/posting rules; record who/when closed |
| `next_document_number(p_organization_id, p_document_type)` | Allocate the next document number | Use row locking or an atomic sequence operation to avoid duplicates under concurrency |

### RPC security rules
1. For user-facing operations, derive the actor from `auth.uid()` and resolve active membership server-side; do not trust a client-provided user ID.
2. Validate the caller's permission and active organization inside the function. Do not rely on a UI check.
3. Use `SECURITY INVOKER` by default. If `SECURITY DEFINER` is necessary, set a safe `search_path`, fully qualify object names, revoke default execution from `PUBLIC`, and grant execute only to intended roles.
4. Grant `EXECUTE` explicitly to intended Supabase roles (commonly `authenticated` for user operations). Do not expose privileged maintenance functions to `anon`.
5. Make financial posting functions transactional and idempotent; use row locks or unique idempotency keys where concurrent requests could duplicate effects.
6. Avoid accepting arbitrary `organization_id` as authority. If it is an input, prove the caller is an active member with the required permission in that organization.
7. Test unauthorized callers, cross-tenant IDs, duplicate calls, concurrent calls, and rollback behavior.

## 5. RLS policy catalogue

**No deployed `CREATE POLICY` definitions or RLS status could be confirmed from the available repository files.** The policy matrix below is a recommended baseline to implement and verify. Do not describe a table as protected until `relrowsecurity` and the actual policies have been checked in PostgreSQL.

### Baseline approach

- Enable RLS on every organization-owned table exposed through the Supabase Data API.
- For ordinary business tables, authorize access only when the request user has an active `organization_users` membership for the row's `organization_id`.
- For writes, also validate the requested action's permission and ensure referenced rows belong to the same organization.
- Use both `USING` and `WITH CHECK` where appropriate. `USING` controls which existing rows can be read/updated/deleted; `WITH CHECK` validates inserted or updated row values.
- Deny by default. Do not add broad `TO authenticated USING (true)` policies to tenant data.
- RLS does not replace constraints or business validation. The Supabase service role bypasses RLS, so its key must never reach browser/client code.
- Avoid policy recursion: if membership/permission checks query RLS-protected membership tables, use a carefully secured helper function or a narrowly scoped design that does not recursively invoke the same policies.

### Policy matrix (recommended)

| Table/group | SELECT | INSERT | UPDATE | DELETE |
| --- | --- | --- | --- | --- |
| `organizations` | Active member of that organization | Through trusted organization-creation RPC | Active member with organization-settings permission | Normally blocked; use controlled archival/deactivation |
| `organization_users` | Self membership and/or authorized organization Administrator | Trusted invite/join/admin flow only | Authorized Administrator; protect last Administrator and role assignment rules | Controlled removal flow; protect last Administrator |
| Proposed `roles` | Active organization member with role-read permission | Authorized Administrator/role manager; no client-created system role | Authorized role manager; protect system Administrator | Block system role deletion; custom role only if safe and unassigned |
| Proposed `permissions` | Authenticated users only if the global catalog is intended to be visible | No client writes; system migration/maintainer only | No client writes; system migration/maintainer only | No client writes |
| Proposed `role_permissions` | Active organization member with role-read permission, scoped through role's organization | Authorized role manager; validate role organization | Usually replace rows via a controlled RPC | Authorized role manager; never remove required admin access |
| All accounting/master/transaction tables | Active membership in row's organization plus read permission | Create permission and same-tenant checks | Update permission; posted financial records require controlled workflow | Deny for posted/financial history; use void/reversal/archival workflows |
| `payment_allocations` | Membership in allocation's organization | Authorized payment workflow; validate payment and target document tenant | Controlled payment workflow | Controlled unallocation only if accounting rules allow |
| Polymorphic references | Read through parent row's organization | Validate `document_type`, target existence, and organization in trusted code/RPC | Controlled workflow | Controlled workflow |

This matrix is intentionally a policy design, not ready-to-run SQL: exact helper function names and policy predicates depend on the real authentication schema, current grants, and migrations.

### Example membership predicate (illustrative only)

A policy helper may conceptually check whether `auth.uid()` has an active membership in the requested organization. Adapt the table/column names and secure the helper before deployment.

```sql
exists (
  select 1
  from public.organization_users ou
  where ou.organization_id = <row>.organization_id
    and ou.user_id = auth.uid()
    and ou.is_active = true
)
```

Do not paste this placeholder literally into a policy. Replace `<row>` with the policy table's row reference and validate function/policy recursion, grants, and performance.

### Required RLS verification

Run these checks in a trusted SQL console against the target database before declaring RLS complete:

```sql
-- Tables and whether RLS is enabled/forced
select n.nspname as schema_name,
       c.relname as table_name,
       c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r'
  and n.nspname = 'public'
order by c.relname;

-- Actual policies
select schemaname, tablename, policyname, permissive,
       roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

-- User-defined functions potentially exposed as RPCs
select n.nspname as schema_name,
       p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       p.prosecdef as security_definer,
       p.proconfig as function_settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prokind = 'f'
order by p.proname;
```

Also inspect function execute grants and table grants; a function's existence alone does not mean it is safely exposed or callable from Supabase RPC.

## 6. RBAC workflow

### Organization creation
1. Authenticated creator requests organization creation.
2. Trusted server/RPC derives the creator using `auth.uid()`.
3. In one transaction, create the organization.
4. Create the organization's protected system role named `Administrator` (`is_system_role = true`; status active).
5. Link the system-defined permission set to that role.
6. Insert the creator's active `organization_users` membership with that role's `role_id`.
7. Commit only if all steps succeed; otherwise roll back the entire operation.

### Role and permission management
- Permission definitions are maintained by system migrations/developers, not created by ordinary organization Administrators.
- An Administrator creates custom organization-scoped roles and selects permissions from the global catalog.
- Protect the system Administrator role from deletion/deactivation and ensure a tenant cannot be left with no active Administrator.
- Check that a role and membership share the same organization on every assignment.
- If a future requirement allows multiple roles per membership, replace the single `organization_users.role_id` design with a junction table; do not silently mix the two models.

## 7. Financial and inventory transaction lifecycle

Recommended lifecycle:

1. **Draft:** editable; no posted ledger effects.
2. **Validate:** verify tenant ownership, source documents, account mappings, accounting period, quantities, permissions, and totals.
3. **Post:** one trusted transaction creates journal entry/lines and inventory effects, then marks the source document posted.
4. **Reverse/return:** use controlled reversal or return documents; preserve audit history.
5. **Reconcile:** verify document totals against ledger entries, inventory movements against balances, and payment allocations against payment totals.

Do not treat this lifecycle as implemented until the application and database functions enforce it.

## 8. Test plan

### Tenant isolation
- User in organization A cannot read, update, delete, or infer rows in organization B.
- User cannot assign an organization B role to an organization A membership.
- Referenced account/product/contact/document IDs from another organization are rejected.
- Inactive membership loses access immediately.

### RBAC
- Organization creator receives Administrator automatically.
- An ordinary member cannot create roles or change role permissions.
- A custom role only grants its selected permissions.
- System Administrator role cannot be deleted/deactivated or stripped of essential access by normal role-management flows.
- At least one authorized Administrator remains after member removal/role changes.

### Accounting
- Unbalanced journals cannot post.
- Posting to a closed period is rejected.
- Concurrent/double posting does not duplicate ledger or inventory effects.
- Posted entries are corrected through reversals, not silent mutation.
- Return quantities and payment allocations cannot exceed valid source balances.

### RLS and RPC
- Test as `anon`, authenticated users with different memberships, and trusted server/service role separately.
- Verify RLS on every exposed table, including child tables and join tables.
- Verify RPC grants, `SECURITY DEFINER` settings if used, cross-tenant rejection, idempotency, and rollback on failure.
- Run the RLS/RPC inventory queries in Section 5 and record results in a verified implementation checklist.

## 9. What must be verified before calling this implementation-complete

- [ ] Actual migrations and DDL match the documented columns and constraints.
- [ ] Every intended FK, unique constraint, check constraint, and index exists.
- [ ] All public/API-exposed tenant tables have RLS enabled and tested.
- [ ] The real policy inventory is recorded; policy matrix above has been implemented or differences documented.
- [ ] The real RPC/function inventory, signatures, execute grants, and security modes are recorded.
- [ ] Organization creation and Administrator assignment are atomic.
- [ ] Journal posting, reversal, inventory updates, returns, and payment allocation are transactional and tested.
- [ ] Cross-organization negative tests pass.
- [ ] No service-role secret is exposed to client-side code.

## 10. Documentation boundary

This document distinguishes the supplied 24-table inventory from recommended relationships, RBAC additions, RPCs, and RLS policies. The actual deployed database is the source of truth. Update the verified sections only after inspecting migrations and querying the target Supabase/PostgreSQL instance; never infer deployed policies or functions from table names alone.
