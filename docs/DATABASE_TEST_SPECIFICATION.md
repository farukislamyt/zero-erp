# ZERO ERP — Database Test Specification

**Scope:** canonical bootstrap `supabase/migrations/20261103000000_initial_database_schema.sql` on `feat/database-migrations`  
**Purpose:** define the complete database contract and the expected automated regression coverage before changing database behavior.  
**Authority:** executable SQL is authoritative. This document describes tests; it does not grant permission to change the schema.  
**Non-goals:** no new SQL migration, no Accounting Period subsystem, no Administrator transfer, no change to Creator Administrator invariants.

## 1. Test execution contract

1. Every run starts from a new disposable Supabase local stack.
2. Apply the one canonical initial SQL file exactly once to an empty database.
3. Run catalog/privilege/seed assertions before business workflows.
4. Use isolated Auth users and at least two organizations for tenant tests.
5. Execute application RPCs as `authenticated` with JWT claims; execute catalog assertions as the database test owner.
6. Assert both persisted state and accounting side effects. An RPC returning a UUID is not proof of a correct posting.
7. Every failed workflow must leave no partial journal lines, stock movements, allocations, or status changes.
8. No test may connect to Production. No Service Role or database-owner secret may be exposed to client code.
9. CI failure is mandatory for any failed assertion, SQL error, migration error, or missing expected object.
10. This specification is broader than the initial executable pgTAP smoke suite. Cases marked **planned** are not represented as runtime-tested until executable assertions are added and CI passes.

## 2. Coverage status vocabulary

- **Bootstrap:** executable pgTAP assertion in `supabase/tests/database/001_schema_contract.test.sql`.
- **Specified:** complete expected test behavior is documented below; a dedicated runtime assertion is still required.
- **Not runtime-verified:** no successful PostgreSQL/Supabase run has yet been observed for the case.

## 3. Effective callable function/RPC contract

Parameters are listed in SQL order. Optional parameters retain their SQL defaults. “Permission” means the effective authorization check in the final function body; helper functions may additionally validate active membership, active organization, role status, target ownership, and caller authority.

| RPC / function | Input parameters | Permission / caller rule | Success contract |
|---|---|---|---|
| `is_active_org_member` | `p_organization_id uuid` | Authenticated identity; active membership in active organization | True only for current user's active membership |
| `has_org_permission` | `p_organization_id uuid, p_permission_key text` | Authenticated identity; active membership, active role and matching permission | Boolean authorization result; false for inactive/missing scope |
| `is_org_administrator` | `p_organization_id uuid` | Authenticated identity | True only for the current active organization Administrator |
| `create_organization_with_admin` | `p_name text, p_currency text DEFAULT 'BDT', p_timezone text DEFAULT 'Asia/Dhaka'` | Authenticated user; one-company/active-membership restrictions | Atomically creates tenant, permanent creator Administrator, all 43 role permissions, 22 default accounts, General Expenses category and 8 number sequences |
| `update_organization_profile` | `p_organization_id uuid, p_name text, p_phone text, p_email text, p_address text, p_city text, p_country text, p_currency text, p_timezone text, p_tin text, p_bin text` | Organization Administrator only; active organization and caller re-check after row lock | Updates supported company profile fields; trims empty optional text to NULL |
| `add_organization_user_by_email` | `p_organization_id uuid, p_email text, p_role_id uuid` | Organization Administrator only; existing verified Auth user; active custom role | Creates/reactivates ordinary membership; never creates an Auth account |
| `update_organization_user_role` | `p_organization_id uuid, p_membership_id uuid, p_role_id uuid` | Organization Administrator only | Assigns active same-organization custom role; Creator membership is immutable |
| `set_organization_user_active` | `p_organization_id uuid, p_membership_id uuid, p_is_active boolean` | Organization Administrator only | Activates/deactivates ordinary membership; Creator cannot be changed |
| `validate_role_assignment` | `p_organization_id uuid, p_role_id uuid` | Organization Administrator only | Validates active custom role in same organization; no write |
| `create_custom_role` | `p_organization_id uuid, p_name text, p_permission_keys text[]` | Organization Administrator only | Creates role and exact allowed permission set; rejects control-plane permissions |
| `replace_custom_role_permissions` | `p_organization_id uuid, p_role_id uuid, p_permission_keys text[]` | Organization Administrator only | Atomically replaces custom role permission set; Administrator permissions immutable |
| `update_custom_role` | `p_organization_id uuid, p_role_id uuid, p_name text, p_status text` | Organization Administrator only | Renames/activates/deactivates custom role; cannot deactivate while active members are assigned |
| `save_master_data` | `p_organization_id uuid, p_entity_type text, p_data jsonb, p_record_id uuid DEFAULT NULL` | Entity-specific manage permission | Creates/updates one supported master record; returns record UUID |
| `next_document_number` | `p_organization_id uuid, p_document_type text` | Entity-specific create/manage permission | Atomically allocates next formatted number; inactive sequence fails |
| `post_opening_balances` | `p_organization_id uuid, p_entry_date date, p_account_lines jsonb, p_party_balances jsonb, p_inventory_lines jsonb, p_description text DEFAULT 'Opening balances'` | `opening_balances.post` plus active member | One-time balanced opening journal plus party and inventory opening effects |
| `save_draft_transaction_document` | `p_organization_id uuid, p_document_type text, p_header jsonb, p_items jsonb DEFAULT NULL, p_document_id uuid DEFAULT NULL` | Document-specific create/manage permission | Creates/updates Draft only; allowlisted header/line fields; returns document UUID |
| `confirm_transaction_document` | `p_organization_id uuid, p_document_type text, p_document_id uuid` | Document-specific confirm permission | Draft becomes Confirmed after complete business validation; no ledger/stock posting |
| `revert_transaction_document_to_draft` | `p_organization_id uuid, p_document_type text, p_document_id uuid` | Document-specific confirm permission | Confirmed becomes Draft; no ledger/stock posting |
| `void_transaction_document` | `p_organization_id uuid, p_document_type text, p_document_id uuid, p_reason text` | Document-specific confirm permission | Draft/Confirmed becomes Void with reason and audit metadata; Posted is rejected |
| `delete_draft_transaction_document` | `p_organization_id uuid, p_document_type text, p_document_id uuid` | Document-specific create/manage permission | Deletes Draft and its child rows; allocation-linked documents cannot be deleted |
| `post_purchase` | `p_organization_id uuid, p_purchase_id uuid` | `purchases.post` | Posts Purchase, increases stock/valuation, creates balanced inventory/AP journal |
| `post_sales` | `p_organization_id uuid, p_sales_id uuid` | `sales.post` | Posts Sales, decreases stock, captures COGS, creates balanced AR/revenue/COGS/inventory journal |
| `post_purchase_return` | `p_organization_id uuid, p_purchase_return_id uuid` | `purchases.returns.post` | Posts return, reduces stock and payable/return variance as applicable |
| `post_sales_return` | `p_organization_id uuid, p_sales_return_id uuid` | `sales.returns.post` | Posts return, increases stock and reverses revenue/COGS proportionately |
| `post_expense` | `p_organization_id uuid, p_expense_id uuid` | `expenses.post` | Debits mapped expense account, credits payable account, marks Expense Posted |
| `post_contact_payment` | `p_organization_id uuid, p_payment_id uuid` | `payments.post` | Posts receipt/payment/refund/transfer according to type and account rules |
| `set_payment_allocations` | `p_organization_id uuid, p_payment_id uuid, p_allocations jsonb` | `payments.manage` | Replaces Draft Payment allocations only after validating each target and outstanding balance |
| `validate_payment_allocations` | `p_organization_id uuid, p_payment_id uuid` | Internal helper; no client EXECUTE | Validates all existing allocation rows; no write |
| `post_inventory_adjustment` | `p_organization_id uuid, p_adjustment_date date, p_reason text, p_lines jsonb, p_gain_account_id uuid DEFAULT NULL, p_loss_account_id uuid DEFAULT NULL` | `inventory.adjust` | Posts stock adjustment and balanced gain/loss journal; locks product balances in sorted order |
| `post_confirmed_journal_entry` | `p_organization_id uuid, p_journal_entry_id uuid` | `journal_entries.post` | Posts a Confirmed balanced manual Journal exactly once |
| `reverse_journal_entry` | `p_organization_id uuid, p_journal_entry_id uuid, p_reversal_date date, p_reason text` | `journal_entries.reverse` | Creates equal/opposite Reversal Journal; updates supported source document and stock state |
| `report_trial_balance` | `p_organization_id uuid, p_date_from date, p_date_to date` | `reports.read` | Account opening, movement debit/credit and closing balances |
| `report_general_ledger` | `p_organization_id uuid, p_account_id uuid, p_date_from date, p_date_to date` | `reports.read` | Account activity and running balance |
| `report_profit_and_loss` | `p_organization_id uuid, p_date_from date, p_date_to date` | `reports.read` | Revenue/expense totals for inclusive date range |
| `report_balance_sheet` | `p_organization_id uuid, p_as_of_date date` | `reports.read` | Asset/liability/equity balances at date |
| `report_inventory_valuation` | `p_organization_id uuid, p_as_of_date date DEFAULT CURRENT_DATE` | `inventory.read` | Product quantity, value and average cost at date |
| `report_contact_balances` | `p_organization_id uuid, p_as_of_date date DEFAULT CURRENT_DATE` | `reports.read` | Contact balances by control account at date |
| `report_receivables_aging` | `p_organization_id uuid, p_as_of_date date DEFAULT CURRENT_DATE` | `reports.read` | Sales outstanding in 0–30, 31–60, 61–90 and >90 day buckets |
| `report_payables_aging` | `p_organization_id uuid, p_as_of_date date DEFAULT CURRENT_DATE` | `reports.read` | Purchase/Expense outstanding in age buckets |
| `report_unapplied_payments` | `p_organization_id uuid, p_as_of_date date DEFAULT CURRENT_DATE` | `reports.read` | Unallocated receipt/payment/refund balance at date |

### Internal / trigger-only functions

The following are not normal application RPCs and must not be granted to browser roles: `set_updated_at()`, `prevent_account_hierarchy_cycle()`, `guard_system_role_mutation()`, `guard_administrator_membership()`, `guard_system_role_permissions()`, `post_manual_journal_entry(uuid,text,date,text,jsonb)` (legacy, client EXECUTE revoked), `seed_default_chart_of_accounts(uuid)`, `assign_document_number()`, `guard_organization_creator_membership()`, `guard_organization_created_at()`, `guard_custom_role_control_plane_permissions()`, and `guard_system_administrator_role()`. `is_organization_creator(uuid,uuid)` is an internal identity helper. Trigger-only functions are tested through their triggering table operation, not called directly.

## 4. JSON payload field contract

### 4.1 Master data — `save_master_data`

| `p_entity_type` | Allowed `p_data` keys | Permission | Positive test | Negative test |
|---|---|---|---|---|
| `account` | `account_code, account_name, account_type, parent_account_id, normal_balance, is_control_account, is_postable, is_active` | `accounts.manage` | Create/update same-tenant valid account | Unknown key, invalid type/normal balance, wrong-tenant parent, self/cyclic parent, postable parent, reclassify used/system account, deactivate account with ledger/mappings/children |
| `unit` | `name, is_active` | `products.manage` | Create/update Unit | Empty/duplicate name, wrong-tenant record, deactivate Unit used by active Product |
| `contact` | `contact_number, name, phone, email, address, is_active` | `contacts.manage` | Create/update Contact | Empty/duplicate number/name, wrong-tenant record, deactivate Contact with outstanding AR/AP |
| `product` | `product_code, name, unit_id, inventory_account_id, sales_account_id, cogs_account_id, is_active` | `products.manage` | Create/update Product with active Unit and correctly typed active/postable accounts | Missing Unit on create, wrong-tenant/inactive Unit, invalid account type, wrong-tenant mappings, change mappings after stock movements, deactivate with non-zero stock |
| `expense_category` | `category_code, name, expense_account_id, is_active` | `expenses.manage` | Create/update mapped Category | Missing mapping on create, non-expense/inactive/non-postable/wrong-tenant Account, duplicate code, unknown key |

For all entities: `p_data` must be a non-empty JSON object; unsupported entity types, unknown keys, invalid record IDs, inactive organization, missing membership, and missing entity permission must fail without partial writes.

### 4.2 Draft document — `save_draft_transaction_document`

| Document type | Header keys accepted | Item keys accepted | Permission |
|---|---|---|---|
| `purchase` | `invoice_id, supplier_id, invoice_date, subtotal, discount_amount, total_amount, payable_account_id` | `line_number, product_id, quantity, unit_cost, line_total` | `purchases.create` |
| `sales` | `invoice_id, customer_id, invoice_date, subtotal, discount_amount, total_amount, receivable_account_id` | `line_number, product_id, quantity, unit_price, line_total` | `sales.create` |
| `expense` | `expense_number, expense_category_id, contact_id, payable_account_id, expense_date, amount, description` | None | `expenses.manage` |
| `payment` | `payment_number, payment_type, contact_id, payment_date, amount, account_id, settlement_account_id, description` | None | `payments.manage` |
| `purchase_return` | `return_number, purchase_id, supplier_id, return_date, subtotal, discount_amount, total_amount, payable_account_id, purchase_return_variance_account_id` | `line_number, purchase_item_id, product_id, quantity, unit_cost, line_total` | `purchases.returns.create` |
| `sales_return` | `return_number, sales_id, customer_id, return_date, subtotal, discount_amount, total_amount, receivable_account_id` | `line_number, sales_item_id, product_id, quantity, unit_price, line_total` | `sales.returns.create` |
| `journal_entry` | `entry_number, entry_date, entry_type, reference_type, reference_id, description` | `account_id, line_number, description, debit, credit, contact_id` | `journal_entries.create` |

Common negative cases: non-object Header, non-array Items, unknown Header key, unsupported Document Type, empty required Header, non-Draft update, wrong-tenant document ID, invalid JSON UUID/numeric conversion, unauthorized permission, and non-empty Items for Expense/Payment. Manual Journal must be `entry_type='manual'`; if `reference_id` is supplied, `reference_type` is required and must be a supported same-tenant target (`purchase`, `sale`, `expense`, `payment`, `purchase_return`, `sales_return`, `journal_entry`, `inventory_adjustment`).

## 5. Field-by-field input validation

### 5.1 Company and identity

- `create_organization_with_admin`: `p_name` non-empty after trim, 1–160 chars; `p_currency` uppercase three-letter code; `p_timezone` must exist in PostgreSQL timezone catalog. Missing Auth identity, already-created company, or another active membership must fail.
- `update_organization_profile`: organization UUID must identify an active tenant; Administrator-only; `p_name` 1–160 chars; currency uppercase 3 letters; timezone valid; optional phone/email/address/city/country/TIN/BIN trimmed and empty strings stored as NULL.
- Membership RPCs: organization UUID, membership UUID, role UUID and email must resolve within the same tenant; email trimmed and valid (3–254 chars, @ after first character); target role active and custom; Creator cannot be modified; duplicate member, unverified/missing Auth user, active membership in another tenant, non-Administrator caller, and role permissions beyond Administrator policy fail.
- Role RPCs: role name 1–100 chars; status only `active|inactive`; permission array cannot be NULL; every permission key must exist and be within caller/Administrator authority; `users.manage` and `roles.manage` reserved to system Administrator; System Administrator role/permissions immutable.

### 5.2 Opening balances

All three payloads must be JSON arrays and must parse completely (record count equals array length).

- `p_organization_id`: active organization with `opening_balances.post`.
- `p_entry_date`: required accounting date.
- `p_account_lines`: each row has `account_id uuid, debit numeric, credit numeric, description text`; account same tenant, active and postable; debit/credit non-negative, exactly one side positive, each amount rounded to 4 decimals.
- `p_party_balances`: each row has `contact_id uuid, party_type text, account_id uuid, amount numeric, description text, balance_side text`; `party_type` is `customer|supplier`; contact active and same tenant; account is an active/postable control account and Asset for customer or Liability for supplier; amount positive and rounded to 4 decimals; optional `balance_side` is `debit|credit` (defaults to debit for customer and credit for supplier).
- `p_inventory_lines`: each row has `product_id uuid, quantity numeric, unit_cost numeric`; product same tenant, active and mapped to active/postable Inventory Asset; quantity positive and rounded to 6 decimals; unit cost non-negative and rounded to 6 decimals; duplicate product rows are rejected (combine into one row); total value is rounded to 4 decimals.
- `p_description`: optional; default `Opening balances`.
- One-time rule: a second opening post or opening post after disallowed accounting activity fails. All GL, party and stock effects are one transaction.

`p_description` is optional and defaults to `Opening balances`. Ordinary GL lines may not directly use AR/AP control accounts, party control accounts, or inventory control accounts; those balances must be represented by their detailed party/inventory rows. A party control account cannot also be an inventory control account. All three arrays must be supplied, even when an array is empty.

### 5.3 Inventory adjustment

- `p_organization_id`: active tenant; `inventory.adjust`.
- `p_adjustment_date`: required date.
- `p_reason`: non-empty, at least 3 trimmed characters.
- `p_lines`: non-empty JSON array; each line has `product_id uuid, direction text, quantity numeric, unit_cost numeric`.
- `product_id`: active Product in same tenant, mapped to active/postable inventory asset account.
- `direction`: exactly `increase|decrease`.
- `quantity`: positive.
- `unit_cost`: positive for increase; decrease uses current weighted average.
- `p_gain_account_id`: optional; defaults to seeded 4300; must be active/postable revenue.
- `p_loss_account_id`: optional; defaults to seeded 5300; must be active/postable expense.
- Reject malformed rows, missing products, unsupported direction, negative/zero quantity, missing/zero increase cost, insufficient stock for decrease, zero-value movement, negative inventory value, or invalid gain/loss account.
- Success: one posted adjustment Journal, paired inventory movement(s), updated stock snapshot and balanced gain/loss journal lines.

### 5.4 Payment allocations

Each `p_allocations` JSON array row requires `document_type text, document_id uuid, allocated_amount numeric`. Only `purchase|purchase_return|sales|sales_return|expense` are accepted; ID required; amount positive. Payment must be Draft; transfer cannot have rows; total allocation cannot exceed payment amount. Target must be same-tenant and Posted/Partially Returned as allowed, contact must match, and allocation must not exceed current outstanding amount. Setter replacement must be atomic: if any row fails, prior allocations remain unchanged.

## 6. Expected posting state and accounting invariants

| Workflow | Expected journal | Expected inventory | Expected document state |
|---|---|---|---|
| Opening GL/party | Balanced Opening Balance Journal; party control balances carry Contact IDs | Opening stock transactions and balance rows | One-time opening event recorded |
| Purchase | Debit inventory asset; credit payable control | Stock IN; weighted average cost recalculated | Purchase Posted; journal link set |
| Purchase Return | Debit payable/return variance as dictated by original cost/discount; credit inventory and variance as applicable | Stock OUT; quantity/value/average cost updated | Return Posted; Purchase Partially Returned/Returned |
| Sales | Debit receivable; credit sales revenue; debit COGS; credit inventory | Stock OUT at captured cost; weighted average balance reduced | Sales Posted; COGS captured; journal link set |
| Sales Return | Debit sales return/contra-revenue and inventory; credit receivable and COGS reversal as implemented | Stock IN; returned COGS restored; average cost updated | Return Posted; Sales Partially Returned/Returned |
| Expense | Debit mapped expense account; credit payable account | No stock change | Expense Posted; journal link set |
| Receipt | Debit cash/bank; credit AR control with Contact | No stock change | Payment Posted; linked allocation rows retained |
| Supplier payment | Debit AP control with Contact; credit cash/bank | No stock change | Payment Posted |
| Customer refund | Debit refund settlement/counter-account and credit cash/bank as dictated by refund account type | No stock change | Payment Posted |
| Supplier refund | Debit cash/bank and credit payable/refund control as dictated by refund account type | No stock change | Payment Posted |
| Bank transfer | Debit destination cash/bank; credit source cash/bank | No stock change; no contact/allocation | Payment Posted |
| Inventory increase | Debit inventory asset; credit adjustment gain | Stock IN; quantity/value increase; average cost recalculated | Adjustment Journal Posted |
| Inventory decrease | Debit adjustment loss; credit inventory asset | Stock OUT; quantity/value decrease; negative stock prohibited | Adjustment Journal Posted |
| Manual Journal | User-supplied balanced lines, minimum two; one-sided debit/credit; contact same tenant | No stock change | Journal Posted |
| Reversal | New Journal mirrors original debit/credit lines | Reverse corresponding original stock movement if supported; no negative stock | Original status Reversed; reversal link/date/user/reason set |

For every posting: journal debit total equals journal credit total; every journal line account is active/postable and same tenant; no duplicate posting; status and posted journal ID transition atomically; any error rolls back every side effect.

## 7. Lifecycle test matrix

For each supported `document_type` (`purchase`, `sales`, `expense`, `payment`, `purchase_return`, `sales_return`, `journal_entry`):

1. **Create Draft:** valid payload returns UUID, status Draft, correct child count; the document number is NULL and the corresponding `number_sequences.next_number` is unchanged.
2. **Update Draft:** only allowlisted fields change; document number remains NULL before first confirmation and cannot be client-selected; child replacement is atomic.
3. **Confirm:** after all business validation succeeds, valid complete document becomes Confirmed with `confirmed_at/by` and receives exactly one sequence number in the same transaction; no journal, stock movement, balance or posted timestamp appears.
4. **Invalid Confirm:** missing line, wrong total, inactive/wrong-tenant contact/account/product, bad source return, oversold/over-returned quantity or unbalanced journal fails and remains Draft.
5. **Revert:** Confirmed becomes Draft; its assigned number is retained; reconfirmation reuses that number without advancing the sequence; no posting effects.
6. **Void:** Draft/Confirmed becomes Void with trimmed reason >=3 and audit fields; a Draft void has no number, while a Confirmed void retains its number; Posted/Voided fails.
7. **Delete:** Draft and children removed; an unconfirmed Draft deletion consumes no number; Confirmed/Posted fails; payment-allocation-linked document fails until allocations are removed.
8. **Authorization:** missing create/confirm/post permission fails independently at each RPC.
9. **Tenant:** foreign-tenant ID is indistinguishable from missing target and produces no mutation.
10. **Direct-write hardening:** direct authenticated INSERT/UPDATE/DELETE against transactional tables is denied; direct non-Draft INSERT is rejected by trigger; client-supplied number fields are rejected by the draft RPC allowlist and never become persisted numbers.
11. **Concurrency:** two simultaneous confirm/post requests produce at most one posting and one set of effects.

## 8. RPC-specific test case catalogue

### 8.1 Organization, membership and RBAC

- **ORG-001** Valid create with defaults: BDT/Asia-Dhaka, one active Creator Administrator, 43 permissions, 22 default accounts, one General Expenses category, 8 number sequences.
- **ORG-002** Valid explicit currency/timezone; persisted values match.
- **ORG-003–005** Empty/blank/over-160 name, invalid/lowercase currency, invalid timezone: SQLSTATE 22023; no organization or seed residue.
- **ORG-006** Unauthenticated create: 42501.
- **ORG-007** Same Auth user creates second company: 23505.
- **ORG-008** User with another active membership attempts company creation: 23505.
- **ORG-009** Concurrent company creation by same Auth user: exactly one success.
- **ORG-010** Creator membership update/delete/reassignment/deactivation: 42501.
- **ORG-011** Organization creator timestamp update: 42501.
- **ORG-012** Later Administrator membership insert/assignment: rejected.
- **ORG-013** Administrator Role rename/deactivate/delete or permission removal: rejected.
- **ORG-014** Profile update valid all 11 arguments; blank optional text becomes NULL.
- **ORG-015–017** Profile invalid name/currency/timezone, inactive organization, non-Administrator: rejected.
- **RBAC-001** Add existing verified user with valid custom role.
- **RBAC-002–006** Invalid email, missing/unverified Auth user, duplicate member, inactive/wrong-tenant role: rejected.
- **RBAC-007** Reactivate eligible historical membership in place; Creator historical membership remains immutable.
- **RBAC-008–010** Non-Administrator add/change/deactivate attempt; cross-tenant membership/role; active member assigned to another active organization: rejected.
- **RBAC-011** Change ordinary membership to valid custom role; Creator membership unchanged.
- **RBAC-012** Deactivate/reactivate ordinary membership; inactive member loses RPC and RLS access.
- **RBAC-013** Custom role with allowed subset; permission rows exactly match request.
- **RBAC-014–017** Empty/invalid/unknown permission, duplicate role name, control-plane permission grant, permission caller does not hold: rejected atomically.
- **RBAC-018** Replace permissions success; previous set removed and new set exact.
- **RBAC-019–021** Replace system Administrator permissions, grant users.manage/roles.manage, wrong-tenant role: rejected.
- **RBAC-022** Rename custom role and set inactive when no active members.
- **RBAC-023–025** Invalid status/name, duplicate name, deactivate role with active members, mutate system role: rejected.
- **RBAC-026** validate_role_assignment accepts active custom role and rejects inactive/system/foreign role or non-Administrator caller.

### 8.2 Master data and numbering

- **MD-001–005** Create each of account/unit/contact/product/expense_category with complete valid payload; returned ID exists in same tenant.
- **MD-006–010** Update each entity by valid same-tenant ID; only allowlisted keys change.
- **MD-011** Null/non-object/empty JSON and unsupported entity type: rejected.
- **MD-012** Unknown key for each entity: rejected.
- **MD-013–020** Account type/normal balance mismatch; invalid parent; parent postable; cycle; reclassify system/used account; deactivate ledger-used/mapped/parent account: rejected.
- **MD-021–024** Duplicate/blank Unit; deactivate Unit used by active Product; wrong-tenant Unit: rejected.
- **MD-025–028** Duplicate/blank Contact; deactivate Contact with outstanding AR/AP; wrong-tenant Contact: rejected.
- **MD-029–034** Product missing/inactive/wrong-tenant Unit; invalid inventory/sales/COGS account type; mapping change after stock movement; deactivate non-zero stock: rejected.
- **MD-035–038** Expense category missing/invalid/inactive/wrong-tenant expense account; duplicate code: rejected.
- **NUM-001–008** Each seeded sequence has the expected prefix/padding; business-document sequences advance only on first successful confirmation, while inventory adjustment advances inside its posting RPC.
- **NUM-009–011** Unauthorized document confirmation/posting, unknown internal type and inactive sequence: rejected; counter unchanged.
- **NUM-012** Concurrent confirmations/postings produce unique numbers; sequence-row locking prevents duplicates and transaction failures roll back allocation.
- **NUM-013** Updating a document cannot change an assigned number.
- **NUM-014–018** Drafts have NULL numbers; first confirmation allocates once; invalid confirmation does not allocate; revert/reconfirm retains the number; direct authenticated allocator execution is denied; direct non-Draft INSERT and client-selected numbers are rejected; inventory-adjustment number allocation is atomic with posting.
- **NUM-014** Creating/updating a Draft does not allocate a number; client-supplied number fields are ignored.
- **NUM-015** First successful confirmation allocates exactly one number; failed confirmation leaves the sequence unchanged.
- **NUM-016** Revert and reconfirm retain the original number without another increment; void/delete preserve the no-gap policy.
- **NUM-017** Authenticated clients cannot directly execute `next_document_number`; document confirmation and inventory adjustment posting remain the only supported allocation paths.
- **NUM-018** Inventory adjustment allocates its number atomically with its posting transaction; a failed posting rolls back the sequence change.

### 8.3 Opening balances

- **OPEN-001** Balanced GL opening lines post once; journal balanced and correct account lines.
- **OPEN-002** Customer AR and Supplier AP opening party rows have correct contact/control-account linkage.
- **OPEN-003** Inventory opening creates expected IN transactions and balance quantity/value/average cost.
- **OPEN-004** Combined GL + party + inventory opening is atomic.
- **OPEN-005–010** Null/non-array payload, malformed record count, missing/foreign/inactive/non-postable account, wrong control-account type, invalid contact/product, bad precision/negative values: rejected.
- **OPEN-011** Unbalanced debit/credit: rejected.
- **OPEN-012** Duplicate account/party/product lines and incompatible control-account mappings: rejected according to SQL invariant.
- **OPEN-013** Second opening post or disallowed prior activity: rejected.
- **OPEN-014** Unauthorized/inactive tenant: rejected.
- **OPEN-015** Failure in final stage leaves zero journal/transactions/balances from that call.

### 8.4 Purchase and Purchase Return

- **PUR-001** Save valid Purchase Draft with Supplier, Date, payable account and one or more lines.
- **PUR-002–008** Missing/foreign/inactive Supplier; invalid/foreign/inactive Product; invalid quantity/cost/line total; subtotal/discount/total mismatch; discount > subtotal; unknown header/line key: rejected at the appropriate save/confirm stage.
- **PUR-009** Confirm valid Purchase: Confirmed audit fields; no stock/journal yet.
- **PUR-010** Post confirmed Purchase: stock IN, weighted average cost correct, balanced inventory/AP journal, posted link and status.
- **PUR-011–014** Post Draft/Voided/Posted twice, missing permission, wrong tenant, inactive Account: rejected without side effects.
- **PUR-015** Multi-line same product purchase aggregates stock/value correctly.
- **PR-001** Create Return Draft against posted Purchase and original item.
- **PR-002–006** Wrong source, supplier/payable mismatch, item mismatch, return quantity > remaining, cumulative amount > purchase total: rejected.
- **PR-007** Confirm Return without stock/journal side effect.
- **PR-008** Post Return: stock OUT, average cost/value correct, balanced return/variance journal, source Purchase status changes.
- **PR-009–012** Duplicate/over-return/insufficient stock/foreign tenant/unauthorized post: rejected atomically.
- **PR-013** Reverse Purchase Return: inverse journal, stock restored if valid, Purchase status recalculated.
- **PR-014** Reversal after affected stock consumed: rejected; no partial journal/stock change.

### 8.5 Sales and Sales Return

- **SAL-001** Save valid Sales Draft with Customer, date, receivable account and lines.
- **SAL-002–008** Missing/foreign/inactive Customer/Product, bad quantity/price/line total, invalid totals/discount, unknown fields: rejected at appropriate stage.
- **SAL-009** Confirm valid Sales: Confirmed audit fields; no ledger/stock movement.
- **SAL-010** Post Sales: stock OUT, COGS captured from current average cost, AR/revenue/COGS/inventory journal balanced.
- **SAL-011–015** Insufficient stock, wrong account mapping, duplicate post, non-confirmed status, unauthorized/foreign tenant: rejected without partial effects.
- **SAL-016** Concurrent sales for same stock: no negative stock; row lock behavior correct.
- **SR-001** Create Sales Return Draft referencing original Sales Item.
- **SR-002–006** Source not posted, customer/receivable mismatch, returned item mismatch, quantity exceeds remaining, return total exceeds discounted net line value: rejected.
- **SR-007** Confirm valid Return without posting effects.
- **SR-008** Post Return: stock IN, revenue/AR/COGS reversal balanced, captured COGS restored correctly, Sales status updated.
- **SR-009–012** Duplicate/cumulative over-return/invalid stock mapping/unauthorized: rejected atomically.
- **SR-013** Reverse Sales Return: inverse journal and stock OUT; Sales status recalculated.
- **SR-014** Reversal that would make stock negative: rejected atomically.

### 8.6 Expense and Payments

- **EXP-001** Save Expense Draft with Category, Date, positive Amount, Payable Account and optional Contact.
- **EXP-002–005** Missing/foreign/inactive category, unmapped/non-expense category account, non-liability payable account, wrong/inactive Contact: confirm/post rejected.
- **EXP-006** Confirm valid Expense; no journal until posting.
- **EXP-007** Post Expense: debit mapped expense account, credit payable; contact appears only for contact-linked payable control account; balanced journal.
- **EXP-008–010** Post wrong status/twice/without permission; contact/account mismatch: rejected atomically.
- **EXP-011** Reverse Expense; inverse journal and historical payable cutoff correct.
- **PAY-001** Save Receipt Draft with contact, cash/bank asset account, AR control account.
- **PAY-002** Save Supplier Payment Draft with contact, cash/bank asset account, AP control account.
- **PAY-003** Save Customer/Supplier Refund Draft with correct control-account type.
- **PAY-004** Save Bank Transfer Draft with no contact and two distinct cash/bank asset accounts.
- **PAY-005–010** Invalid payment type, missing contact for non-transfer, contact on transfer, same source/destination, inactive/non-postable/non-asset cash account, invalid settlement control account: rejected at confirm/post.
- **PAY-011** Receipt amount <= current customer AR; post debit cash/credit AR with matching contact.
- **PAY-012** Supplier payment amount <= current AP; post debit AP/credit cash with matching contact.
- **PAY-013–014** Customer/Supplier Refund account direction and balance rules; journal balanced.
- **PAY-015** Bank Transfer debit destination/credit source; no contact/allocation.
- **PAY-016–018** Receipt/payment above outstanding balance, wrong contact, wrong account type: rejected.
- **PAY-019** Reverse each supported payment type; balances and historical unapplied snapshot match reversal journal entry date.

### 8.7 Payment allocation

- **ALLOC-001** Receipt → posted Sales invoice; customer match and partial/full outstanding allocation.
- **ALLOC-002** Supplier Payment → posted Purchase; supplier match.
- **ALLOC-003** Supplier Payment → posted Expense; contact match.
- **ALLOC-004** Customer Refund → posted Sales Return; asset settlement account.
- **ALLOC-005** Supplier Refund → posted Purchase Return; liability settlement account.
- **ALLOC-006–012** Non-array/null/malformed row, unsupported type, null UUID, zero/negative amount, payment not Draft, transfer allocation, allocation sum > payment amount: rejected.
- **ALLOC-013–017** Wrong target state, foreign target, wrong contact, wrong payment type, wrong refund settlement type: rejected.
- **ALLOC-018** Outstanding amount over-allocation including allocations from other Posted payments: rejected.
- **ALLOC-019** Replacing allocation array succeeds and old set is replaced exactly.
- **ALLOC-020** Any failed replacement rolls back deletes and inserts; old allocation set remains intact.
- **ALLOC-021** Concurrent allocations against one document cannot exceed outstanding amount.
- **ALLOC-022** Payment reversal removes its effect from historical as-of snapshots only from reversal journal entry date onward.

### 8.8 Inventory adjustment and Journal/Reversal

- **INV-001** Increase adjustment with valid Product, quantity and positive cost: stock/value/average cost and gain journal correct.
- **INV-002** Decrease adjustment within available stock: stock/value decrease at current average cost and loss journal correct.
- **INV-003–009** Null/empty lines, malformed record, unsupported direction, zero/negative quantity, missing increase cost, invalid gain/loss account, foreign/inactive Product: rejected.
- **INV-010** Decrease greater than stock: rejected, no negative quantity/value.
- **INV-011** Duplicate Product lines lock/process deterministically and produce consistent aggregate balances.
- **INV-012** Concurrent adjustments lock balances in deterministic product order; no lost update.
- **JRN-001** Manual Journal Draft with at least two valid lines and balanced debit/credit.
- **JRN-002–007** Unsupported reference type, reference ID without type, cross-tenant reference, non-manual entry type, unbalanced/one-sided-invalid lines, inactive/non-postable/foreign account/contact: rejected.
- **JRN-008** Confirmed manual journal posts once and creates exactly its balanced lines.
- **JRN-009–011** Draft post, unbalanced post, duplicate post, unauthorized post: rejected.
- **REV-001** Reverse posted manual Journal: exact opposite lines and original status Reversed.
- **REV-002** Reverse supported Expense/Payment/Purchase Return/Sales Return/Adjustment; source status and stock effects correctly reversed.
- **REV-003–008** Missing/wrong-tenant Journal, not Posted, already reversed, unsupported entry type (Purchase/Sales/Opening Balance), missing/short reason, null date: rejected.
- **REV-009** Inventory reversal blocked when stock has already been consumed and reversal would create negative stock.
- **REV-010** Reversal journal entry date, not wall-clock `reversed_at`, controls historical report cutoffs.
- **REV-011** Any failure leaves original Journal/source document/stock untouched.

### 8.9 Reporting

For every report, test authorized role, denied role, inactive member, inactive organization, wrong-tenant ID, null/invalid dates, inclusive/exclusive boundaries and empty result behavior.

- **RPT-001 Trial Balance:** opening + debit movement − credit movement = closing per normal balance; total debit/credit reconcile.
- **RPT-002 General Ledger:** date range, opening balance, chronological lines, running balance; invalid account rejected.
- **RPT-003 P&L:** revenue and expense movement only in date range; account normal-balance sign correct.
- **RPT-004 Balance Sheet:** asset/liability/equity as-of date; accounting equation reconciles with retained result as implemented.
- **RPT-005 Inventory Valuation:** historical quantity/value from dated movement; zero quantity returns zero average; reconcile to inventory control account.
- **RPT-006 Contact Balances:** correct contact/control-account grouping and sign.
- **RPT-007 Receivables Aging:** 0–30/31–60/61–90/>90 boundaries; receipts/returns applied on accounting-effective dates; later reversal does not rewrite earlier snapshot.
- **RPT-008 Payables Aging:** Purchase/Expense outstanding; supplier payment/return/expense reversal cutoffs.
- **RPT-009 Unapplied Payments:** only receipt/payment/refund; allocation subtraction and reversal-date cutoff; transfers excluded.

## 9. Cross-cutting security, transaction and concurrency cases

- **SEC-001** RLS enabled on all 26 public tables.
- **SEC-002** Every SECURITY DEFINER function pins empty search_path.
- **SEC-003** `anon` cannot execute privileged RPCs.
- **SEC-004** `authenticated` has EXECUTE only on intended exposed functions.
- **SEC-005** Browser roles have no direct INSERT/UPDATE/DELETE on public business tables.
- **SEC-006** Two-tenant read/write isolation for every tenant-owned table and RPC.
- **SEC-007** Inactive membership and inactive organization cannot call tenant RPCs or read own historical membership metadata.
- **SEC-008** Creator anchor and Administrator protections survive direct trusted SQL attempts as well as RPC attempts.
- **SEC-009** Custom roles cannot receive `users.manage` or `roles.manage`.
- **SEC-010** Legacy `post_manual_journal_entry` has no client EXECUTE; transfer RPC absent.
- **TX-001** Every posting function is atomic across header status, journal, ledger, inventory and source-document changes.
- **TX-002** Injected constraint failure in final write rolls back earlier writes.
- **TX-003** Duplicate posting calls result in one posted journal only.
- **TX-004** Row locks prevent double allocation/over-return/oversell.
- **TX-005** Number allocation concurrent calls do not duplicate identifiers.
- **TX-006** Reversal and new posting races preserve ledger/stock integrity.
- **TX-007** Lock ordering across multi-product stock operations avoids avoidable deadlocks.

## 10. CI implementation and executable coverage

Workflow: `.github/workflows/database-ci.yml`

Local Supabase config: `supabase/config.toml`

Executable pgTAP suites:

| Test file | Executable coverage |
|---|---|
| `001_schema_contract.test.sql` | Catalog inventory, all-table RLS/policies, permission seeds, triggers/indexes, SECURITY DEFINER search_path, browser-role write revocation, exposed RPC grants, Creator Administrator bootstrap/invariants, default COA/category/sequences, custom-role restriction, internal-only number allocator exposure and basic report RPC access |
| `002_core_workflows.test.sql` | Company bootstrap, account/contact/unit/product creation, opening GL and inventory balances, Cash–Bank transfer Draft/Confirm/Post, debit/credit ledger lines, source/destination/final balances, total asset preservation, duplicate posting rejection, repeated opening-balance rejection, same-account transfer rejection, custom role/member onboarding and least-privilege denial |
| `003_commerce_accounting_workflows.test.sql` | Supplier/customer/product setup, opening inventory, Draft-without-number and confirmation-stage numbering for purchase/sales/expense/manual journal, number immutability through posting, inventory-adjustment posting number, stock quantity and valuation, balanced journals, manual journal reversal, oversell rejection with no stock mutation, and financial/inventory report reconciliation |
| `004_returns_and_payment_allocations.test.sql` | Purchase return lifecycle and source/stock effects, sales return lifecycle and source/stock effects, customer receipt allocation/posting, supplier payment allocation/posting |
| `005_tenant_isolation.test.sql` | Two independent organizations, active membership and permission scoping, RLS tenant read isolation, cross-tenant master-data write denial and no-write-on-failure |

The first file is the schema/privilege gate. The additional files exercise real authenticated RPC calls against a fresh local Supabase database and assert persisted business state, ledger lines, stock balances and report results. Each file uses isolated deterministic Auth fixtures and rolls back its test data. No production project or secret is used.

### Coverage still required before calling the database fully tested

The executable suite is a materially expanded integration baseline, not yet exhaustive. The following specification areas remain to be implemented as dedicated runtime assertions:

1. Full field-by-field invalid-input matrix for every RPC and every JSON payload key, including all malformed/null/unknown-key combinations.
2. Membership deactivation/reactivation, role replacement/update edge cases, inactive role restrictions and Creator/Administrator adversarial trigger attempts.
3. All customer/supplier refund variants, payment reversal, unapplied payment snapshots and all allocation target types (purchase return, sales return and expense).
4. Over-return, repeated-return, cross-tenant return/payment references and all source-document state permutations.
5. Every report's exact historical cutoff boundaries, date inclusivity, aging buckets and contact/account reconciliation.
6. RLS tests across every tenant-owned table, inactive memberships/organizations and every exposed RPC permission boundary.
7. Rollback fault injection after partial writes, duplicate concurrent posting, concurrent allocation/over-return/oversell, number-sequence contention and reversal/posting races.
8. CI artifact/log retention and a machine-readable test summary grouped by test ID.

A test case is runtime-verified only when it is represented by an executable assertion and a successful GitHub Actions run for the relevant commit. Merely appearing in this specification does not make it tested.

## 11. Acceptance criteria

- Canonical SQL file unchanged; no new migration file.
- Clean Supabase local bootstrap succeeds.
- pgTAP baseline passes.
- Workflow runs on branch push, pull request and manual dispatch.
- All tests use disposable local containers.
- No production secrets or project references.
- Every test case eventually has an executable test ID and recorded CI result.
- Runtime verification is reported only after a real workflow run succeeds.
