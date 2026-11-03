-- Remove accounting periods from an existing Zero ERP database.
-- This drops period metadata and the journal-entry period reference; financial
-- journal/document data and transaction dates are preserved.
BEGIN;

DROP FUNCTION IF EXISTS public.post_manual_journal_entry(uuid, text, uuid, date, text, jsonb);
DROP FUNCTION IF EXISTS public.post_opening_balances(uuid, uuid, date, jsonb, jsonb, jsonb, text);
DROP FUNCTION IF EXISTS public.post_contact_payment(uuid, uuid, uuid);

ALTER TABLE public.journal_entries
  DROP CONSTRAINT IF EXISTS journal_entries_period_same_org_fk;
DROP INDEX IF EXISTS public.journal_entries_period_idx;
ALTER TABLE public.journal_entries
  DROP COLUMN IF EXISTS accounting_period_id;

DROP TABLE IF EXISTS public.accounting_periods;
DROP FUNCTION IF EXISTS public.prevent_overlapping_accounting_periods();

DELETE FROM public.role_permissions
WHERE permission_id IN (
  SELECT id FROM public.permissions
  WHERE permission_key IN ('accounting_periods.read', 'accounting_periods.manage')
);
DELETE FROM public.permissions
WHERE permission_key IN ('accounting_periods.read', 'accounting_periods.manage');

-- Replace period-dependent posting routines with date-based versions.
create or replace function public.post_manual_journal_entry(
  p_organization_id uuid,
  p_entry_number text,
  p_entry_date date,
  p_description text,
  p_lines jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_journal_entry_id uuid;
  v_line_count integer;
  v_invalid_line_count integer;
  v_debit_total numeric(20, 4);
  v_credit_total numeric(20, 4);
begin
  v_user_id := (select auth.uid());

  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'Authentication is required to post a journal entry.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'journal_entries.create')
     or not public.has_org_permission(p_organization_id, 'journal_entries.post') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to create and post journal entries for this organization.';
  end if;

  if p_entry_number is null
     or pg_catalog.length(pg_catalog.btrim(p_entry_number)) not between 1 and 80 then
    raise exception using errcode = '22023',
      message = 'Entry number must contain between 1 and 80 characters.';
  end if;

  if p_entry_date is null then
    raise exception using errcode = '22023',
      message = 'Entry date is required.';
  end if;

  if p_lines is null or pg_catalog.jsonb_typeof(p_lines) <> 'array' then
    raise exception using errcode = '22023',
      message = 'Journal lines must be provided as a JSON array.';
  end if;

  if pg_catalog.jsonb_array_length(p_lines) < 2 then
    raise exception using errcode = '22023',
      message = 'At least two journal lines are required.';
  end if;

  select
    pg_catalog.count(*)::integer,
    pg_catalog.count(*) filter (
      where x.account_id is null
         or x.debit is null
         or x.credit is null
         or x.debit < 0
         or x.credit < 0
         or not ((x.debit > 0 and x.credit = 0) or (x.credit > 0 and x.debit = 0))
    )::integer,
    coalesce(pg_catalog.sum(x.debit), 0),
    coalesce(pg_catalog.sum(x.credit), 0)
  into v_line_count, v_invalid_line_count, v_debit_total, v_credit_total
  from pg_catalog.jsonb_to_recordset(p_lines) as x(
    account_id uuid,
    description text,
    debit numeric,
    credit numeric,
    contact_id uuid
  );

  if v_line_count <> pg_catalog.jsonb_array_length(p_lines) then
    raise exception using errcode = '22023',
      message = 'Journal lines could not be parsed.';
  end if;

  if v_invalid_line_count > 0 then
    raise exception using errcode = '22023',
      message = 'Each journal line must contain an account, non-negative amounts, and exactly one positive debit or credit.';
  end if;

  if v_debit_total <= 0 or v_debit_total <> v_credit_total then
    raise exception using errcode = '23514',
      message = 'Journal entry is not balanced: total debits must equal total credits and be greater than zero.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_lines) as x(
      account_id uuid,
      description text,
      debit numeric,
      credit numeric,
      contact_id uuid
    )
    left join public.accounts a
      on a.organization_id = p_organization_id
     and a.id = x.account_id
    where a.id is null or not a.is_active or not a.is_postable
  ) then
    raise exception using errcode = '23503',
      message = 'Every journal line must reference an active, postable account in this organization.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_lines) as x(
      account_id uuid,
      description text,
      debit numeric,
      credit numeric,
      contact_id uuid
    )
    left join public.contacts c
      on c.organization_id = p_organization_id
     and c.id = x.contact_id
    where x.contact_id is not null and (c.id is null or not c.is_active)
  ) then
    raise exception using errcode = '23503',
      message = 'Each contact on a journal line must be active and belong to this organization.';
  end if;

  insert into public.journal_entries (
    organization_id,
    entry_number,
    entry_date,
    entry_type,
    status,
    description,
    confirmed_at,
    confirmed_by,
    posted_at,
    posted_by,
    created_by
  )
  values (
    p_organization_id,
    pg_catalog.btrim(p_entry_number),
    p_entry_date,
    'manual',
    'posted',
    nullif(pg_catalog.btrim(coalesce(p_description, '')), ''),
    pg_catalog.now(),
    v_user_id,
    pg_catalog.now(),
    v_user_id,
    v_user_id
  )
  returning id into v_journal_entry_id;

  insert into public.account_transactions (
    organization_id,
    journal_entry_id,
    account_id,
    line_number,
    description,
    debit,
    credit,
    contact_id
  )
  select
    p_organization_id,
    v_journal_entry_id,
    x.account_id,
    x.ordinality::integer,
    nullif(pg_catalog.btrim(coalesce(x.description, '')), ''),
    x.debit,
    x.credit,
    x.contact_id
  from pg_catalog.jsonb_to_recordset(p_lines) with ordinality as x(
    account_id uuid,
    description text,
    debit numeric,
    credit numeric,
    contact_id uuid,
    ordinality bigint
  );

  return v_journal_entry_id;
end;
$$;

create or replace function public.post_purchase(
  p_organization_id uuid,
  p_purchase_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_purchase public.purchase%rowtype;
  v_supplier_active boolean;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_line_net numeric(20,4);
  v_allocated numeric(20,4) := 0;
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_journal_id uuid;
  v_line record;
  v_last_line integer;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication is required to post a purchase.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'purchases.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post purchases for this organization.';
  end if;

  select p.* into v_purchase
  from public.purchase p
  where p.organization_id = p_organization_id and p.id = p_purchase_id
  for update;

  if not found then
    raise exception using errcode = '23503', message = 'Purchase document was not found in this organization.';
  end if;
  if v_purchase.status <> 'confirmed' or v_purchase.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted purchase can be posted.';
  end if;

  select c.is_active into v_supplier_active
  from public.contacts c
  where c.organization_id = p_organization_id and c.id = v_purchase.supplier_id;
  if coalesce(v_supplier_active, false) is not true then
    raise exception using errcode = '23503', message = 'Supplier must be active and belong to this organization.';
  end if;

  select count(*)::integer, coalesce(sum(pi.line_total), 0), max(pi.line_number)
  into v_line_count, v_subtotal, v_last_line
  from public.purchase_items pi
  where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id;

  if v_line_count < 1 then
    raise exception using errcode = '23514', message = 'A purchase must contain at least one item.';
  end if;
  if v_subtotal <> v_purchase.subtotal then
    raise exception using errcode = '23514', message = 'Purchase subtotal must equal the sum of item line totals.';
  end if;
  if v_purchase.discount_amount > v_subtotal
     or v_purchase.total_amount <> v_subtotal - v_purchase.discount_amount
     or v_purchase.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Purchase totals are inconsistent or net total is not positive.';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.organization_id = p_organization_id
      and a.id = v_purchase.payable_account_id
      and a.is_active and a.is_postable and a.is_control_account
      and a.account_type = 'liability'
  ) then
    raise exception using errcode = '23503', message = 'Payable account must be an active, postable liability account.';
  end if;

  if exists (
    select 1
    from public.purchase_items pi
    join public.products pr on pr.organization_id = pi.organization_id and pr.id = pi.product_id
    left join public.accounts a on a.organization_id = pr.organization_id and a.id = pr.inventory_account_id
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
      and (not pr.is_active or a.id is null or not a.is_active or not a.is_postable
        or a.account_type <> 'asset'
        or pi.line_total <> round(pi.quantity * pi.unit_cost, 4))
  ) then
    raise exception using errcode = '23514',
      message = 'Each item requires an active product, a postable inventory asset account, and a consistent line total.';
  end if;

  -- Lock stock rows in stable order to reduce deadlocks when purchases overlap.
  for v_line in
    select distinct pi.product_id
    from public.purchase_items pi
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
    order by pi.product_id
  loop
    insert into public.inventory_balances (organization_id, product_id, quantity, average_cost, inventory_value)
    values (p_organization_id, v_line.product_id, 0, 0, 0)
    on conflict (organization_id, product_id) do nothing;

    select b.quantity, b.inventory_value into v_balance_quantity, v_balance_value
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    if v_balance_quantity < 0 or v_balance_value < 0 then
      raise exception using errcode = '23514',
        message = 'Negative inventory balance must be reconciled before purchase posting.';
    end if;
  end loop;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description, posted_at, posted_by, created_by
  )
  values (
    p_organization_id,
    'PUR-' || pg_catalog.replace(p_purchase_id::text, '-', ''),
    v_purchase.invoice_date, 'purchase', 'posted',
    'purchase', p_purchase_id, 'Purchase invoice ' || v_purchase.invoice_id,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  -- Apply proportional discount allocation with final-line rounding adjustment.
  for v_line in
    select pi.id, pi.product_id, pi.quantity, pi.line_total, pi.line_number,
           pr.inventory_account_id
    from public.purchase_items pi
    join public.products pr on pr.organization_id = pi.organization_id and pr.id = pi.product_id
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
    order by pi.line_number
  loop
    if v_line.line_number = v_last_line then
      v_line_net := v_purchase.total_amount - v_allocated;
    else
      v_line_net := round(v_line.line_total * v_purchase.total_amount / v_subtotal, 4);
      v_allocated := v_allocated + v_line_net;
    end if;

    select b.quantity, b.inventory_value into v_balance_quantity, v_balance_value
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    v_new_quantity := v_balance_quantity + v_line.quantity;
    v_new_value := v_balance_value + v_line_net;
    v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity, 6) end;

    update public.inventory_balances
    set quantity = v_new_quantity, inventory_value = v_new_value,
        average_cost = v_new_average, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_line.product_id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'PUR-' || pg_catalog.replace(p_purchase_id::text, '-', '') || '-' || v_line.line_number::text,
      v_line.product_id, v_purchase.invoice_date, 'purchase', 'in', v_line.quantity,
      round(v_line_net / v_line.quantity, 6), v_line_net,
      'purchase', p_purchase_id,
      case when v_balance_quantity = 0 then null else round(v_balance_value / v_balance_quantity, 6) end,
      v_new_average, v_user_id
    );
  end loop;

  -- Ledger debit amounts use the same allocation formula and rounding residue as stock valuation.
  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  select p_organization_id, v_journal_id, g.inventory_account_id,
         row_number() over (order by g.inventory_account_id)::integer,
         'Inventory received - ' || v_purchase.invoice_id, g.debit_amount, 0, v_purchase.supplier_id
  from (
    select pr.inventory_account_id,
           sum(case
             when pi.line_number = v_last_line then
               v_purchase.total_amount - coalesce((
                 select sum(round(pi2.line_total * v_purchase.total_amount / v_subtotal, 4))
                 from public.purchase_items pi2
                 where pi2.organization_id = p_organization_id
                   and pi2.purchase_id = p_purchase_id
                   and pi2.line_number <> v_last_line
               ), 0)
             else round(pi.line_total * v_purchase.total_amount / v_subtotal, 4)
           end) as debit_amount
    from public.purchase_items pi
    join public.products pr on pr.organization_id = pi.organization_id and pr.id = pi.product_id
    where pi.organization_id = p_organization_id and pi.purchase_id = p_purchase_id
    group by pr.inventory_account_id
  ) g
  where g.debit_amount > 0;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_purchase.payable_account_id,
    (select count(*)::integer + 1
     from public.account_transactions atx
     where atx.organization_id = p_organization_id and atx.journal_entry_id = v_journal_id),
    'Accounts payable - ' || v_purchase.invoice_id, 0, v_purchase.total_amount, v_purchase.supplier_id
  );

  update public.purchase
  set status = 'posted', posted_journal_entry_id = v_journal_id, posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_purchase_id;

  return v_journal_id;
end;
$$;

create or replace function public.post_opening_balances(
  p_organization_id uuid,
  p_entry_date date,
  p_account_lines jsonb,
  p_party_balances jsonb,
  p_inventory_lines jsonb,
  p_description text default 'Opening balances'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_journal_entry_id uuid;
  v_debit_total numeric(20,4) := 0;
  v_credit_total numeric(20,4) := 0;
  v_inventory_value numeric(20,4) := 0;
  v_entry_number text;
  v_product record;
begin
  v_user_id := (select auth.uid());

  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'Authentication is required to post opening balances.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'opening_balances.post') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to post opening balances for this organization.';
  end if;

  if p_entry_date is null then
    raise exception using errcode = '22023',
      message = 'Opening balance date is required.';
  end if;

  if p_account_lines is null or pg_catalog.jsonb_typeof(p_account_lines) <> 'array'
     or p_party_balances is null or pg_catalog.jsonb_typeof(p_party_balances) <> 'array'
     or p_inventory_lines is null or pg_catalog.jsonb_typeof(p_inventory_lines) <> 'array' then
    raise exception using errcode = '22023',
      message = 'Account, party, and inventory lines must each be supplied as JSON arrays.';
  end if;

  -- Serialize organization-level opening posts and prevent a second opening balance.
  perform 1
  from public.organizations o
  where o.id = p_organization_id
    and o.is_active
  for update;

  if not found then
    raise exception using errcode = '23503',
      message = 'Active organization was not found.';
  end if;

  if exists (
    select 1 from public.journal_entries je
    where je.organization_id = p_organization_id
      and je.entry_type = 'opening_balance'
      and je.reference_type = 'organization_opening_balance'
  ) then
    raise exception using errcode = '23514',
      message = 'Opening balances have already been posted for this organization. Use a reversal or adjustment for corrections.';
  end if;

  if exists (
    select 1 from public.journal_entries je
    where je.organization_id = p_organization_id
      and je.status in ('posted', 'reversed')
      and not (je.entry_type = 'opening_balance'
        and je.reference_type = 'organization_opening_balance')
  ) or exists (
    select 1 from public.inventory_transactions it
    where it.organization_id = p_organization_id
  ) then
    raise exception using errcode = '23514',
      message = 'Opening balances must be initialized before operational ledger or inventory posting. Use controlled adjustments after operations begin.';
  end if;

  -- Validate ordinary GL lines. Accounts also used by party/inventory detail
  -- lines are rejected below to avoid double-counting those control balances.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as x(
      account_id uuid, debit numeric, credit numeric, description text
    )
    where x.account_id is null
       or x.debit is null
       or x.credit is null
       or x.debit < 0
       or x.credit < 0
       or x.debit <> round(x.debit, 4)
       or x.credit <> round(x.credit, 4)
       or not ((x.debit > 0 and x.credit = 0) or (x.credit > 0 and x.debit = 0))
  ) then
    raise exception using errcode = '22023',
      message = 'Each GL line must contain an account, non-negative amounts, and exactly one positive debit or credit.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as x(
      account_id uuid, debit numeric, credit numeric, description text
    )
    left join public.accounts a
      on a.organization_id = p_organization_id
     and a.id = x.account_id
    where a.id is null
       or not a.is_active
       or not a.is_postable
  ) then
    raise exception using errcode = '23503',
      message = 'GL lines must reference active, postable accounts in this organization.';
  end if;

  -- Validate customer/supplier summary balances. Contacts do not carry a
  -- customer-vs-supplier discriminator in the current schema, so party_type
  -- is supplied explicitly by the caller and the contact must belong to this org.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_party_balances) as x(
      contact_id uuid, party_type text, account_id uuid, amount numeric, description text
    )
    where x.contact_id is null
       or x.party_type is null
       or x.party_type not in ('customer', 'supplier')
       or x.account_id is null
       or x.amount is null
       or x.amount <= 0
       or x.amount <> round(x.amount, 4)
  ) then
    raise exception using errcode = '22023',
      message = 'Each party balance must include a contact, customer/supplier type, control account, and positive amount.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_party_balances) as x(
      contact_id uuid, party_type text, account_id uuid, amount numeric, description text
    )
    left join public.contacts c
      on c.organization_id = p_organization_id
     and c.id = x.contact_id
    left join public.accounts a
      on a.organization_id = p_organization_id
     and a.id = x.account_id
    where c.id is null or not c.is_active
       or a.id is null or not a.is_active or not a.is_postable
       or not a.is_control_account
       or (x.party_type = 'customer' and a.account_type <> 'asset')
       or (x.party_type = 'supplier' and a.account_type <> 'liability')
  ) then
    raise exception using errcode = '23503',
      message = 'Customer balances require an active receivable asset control account; supplier balances require an active payable liability control account. Contacts and accounts must belong to this organization.';
  end if;

  -- Validate inventory lines. One opening line per product keeps the initial
  -- valuation deterministic with the current product-level inventory schema.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    where x.product_id is null
       or x.quantity is null or x.quantity <= 0
       or x.quantity <> round(x.quantity, 6)
       or x.unit_cost is null or x.unit_cost < 0
       or x.unit_cost <> round(x.unit_cost, 6)
  ) then
    raise exception using errcode = '22023',
      message = 'Each inventory line must include a product, positive quantity, and non-negative unit cost.';
  end if;

  if exists (
    select x.product_id
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    group by x.product_id
    having pg_catalog.count(*) > 1
  ) then
    raise exception using errcode = '22023',
      message = 'Duplicate products are not allowed in opening inventory lines; combine their quantities into one line.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    left join public.products pr
      on pr.organization_id = p_organization_id
     and pr.id = x.product_id
    left join public.accounts a
      on a.organization_id = pr.organization_id
     and a.id = pr.inventory_account_id
    where pr.id is null or not pr.is_active
       or a.id is null or not a.is_active or not a.is_postable
       or a.account_type <> 'asset'
  ) then
    raise exception using errcode = '23503',
      message = 'Every opening inventory product must be active and mapped to an active, postable inventory asset account in this organization.';
  end if;

  -- A single account cannot serve both the party control and inventory control
  -- subledgers in the same opening post.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_party_balances) as party(
      contact_id uuid, party_type text, account_id uuid, amount numeric, description text
    )
    join pg_catalog.jsonb_to_recordset(p_inventory_lines) as inv(
      product_id uuid, quantity numeric, unit_cost numeric
    ) on true
    join public.products pr
      on pr.organization_id = p_organization_id
     and pr.id = inv.product_id
    where party.account_id = pr.inventory_account_id
  ) then
    raise exception using errcode = '23514',
      message = 'A party control account cannot also be used as an inventory control account.';
  end if;

  -- AR/AP control balances must be represented by contact-tagged party lines.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as gl(account_id uuid)
    join public.accounts a
      on a.organization_id = p_organization_id and a.id = gl.account_id
    where a.is_control_account and a.account_type in ('asset', 'liability')
  ) then
    raise exception using errcode = '23514',
      message = 'Opening GL lines cannot use receivable/payable control accounts directly. Supply contact-tagged party balances instead.';
  end if;

  -- Prevent a GL line from duplicating a party control or product inventory account.
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_account_lines) as gl(account_id uuid)
    where gl.account_id in (
      select party.account_id
      from pg_catalog.jsonb_to_recordset(p_party_balances) as party(
        contact_id uuid, party_type text, account_id uuid, amount numeric, description text
      )
      union
      select pr.inventory_account_id
      from pg_catalog.jsonb_to_recordset(p_inventory_lines) as inv(
        product_id uuid, quantity numeric, unit_cost numeric
      )
      join public.products pr
        on pr.organization_id = p_organization_id
       and pr.id = inv.product_id
    )
  ) then
    raise exception using errcode = '23514',
      message = 'Do not enter a party or inventory control account again in ordinary GL lines; those balances are derived from the detail lines.';
  end if;

  select
    coalesce(pg_catalog.sum(x.debit), 0),
    coalesce(pg_catalog.sum(x.credit), 0)
  into v_debit_total, v_credit_total
  from pg_catalog.jsonb_to_recordset(p_account_lines) as x(
    account_id uuid, debit numeric, credit numeric, description text
  );

  select
    v_debit_total
      + coalesce(pg_catalog.sum(case when x.party_type = 'customer' then x.amount else 0 end), 0),
    v_credit_total
      + coalesce(pg_catalog.sum(case when x.party_type = 'supplier' then x.amount else 0 end), 0)
  into v_debit_total, v_credit_total
  from pg_catalog.jsonb_to_recordset(p_party_balances) as x(
    contact_id uuid, party_type text, account_id uuid, amount numeric, description text
  );

  select coalesce(pg_catalog.sum(round(x.quantity * x.unit_cost, 4)), 0)
    into v_inventory_value
  from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
    product_id uuid, quantity numeric, unit_cost numeric
  );

  v_debit_total := v_debit_total + v_inventory_value;

  if v_debit_total <= 0 or v_debit_total <> v_credit_total then
    raise exception using errcode = '23514',
      message = pg_catalog.format(
        'Opening balances are not balanced. Debits: %s; credits: %s.',
        v_debit_total, v_credit_total
      );
  end if;

  -- Lock/create product balance rows in stable product order. Opening stock is
  -- an initialization, so pre-existing non-zero stock must be reconciled first.
  for v_product in
    select x.product_id
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    order by x.product_id
  loop
    insert into public.inventory_balances (
      organization_id, product_id, quantity, average_cost, inventory_value
    )
    values (p_organization_id, v_product.product_id, 0, 0, 0)
    on conflict (organization_id, product_id) do nothing;

    perform 1
    from public.inventory_balances b
    where b.organization_id = p_organization_id
      and b.product_id = v_product.product_id
    for update;

    if exists (
      select 1
      from public.inventory_balances b
      where b.organization_id = p_organization_id
        and b.product_id = v_product.product_id
        and (b.quantity <> 0 or b.inventory_value <> 0)
    ) then
      raise exception using errcode = '23514',
        message = 'Opening inventory can only initialize products with zero existing stock. Reconcile existing stock before posting.';
    end if;
  end loop;

  v_entry_number := 'OB-' || pg_catalog.substr(
    pg_catalog.replace(p_organization_id::text, '-', ''), 1, 12
  );

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, v_entry_number, p_entry_date,
    'opening_balance', 'posted', 'organization_opening_balance',
    p_organization_id, nullif(pg_catalog.btrim(coalesce(p_description, '')), ''),
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_entry_id;

  -- Post ordinary GL lines, customer/supplier control balances, and inventory
  -- control balances into the same journal and account ledger.
  with journal_lines as (
    select
      1 as sort_group,
      x.ordinality as sort_order,
      x.account_id,
      nullif(pg_catalog.btrim(coalesce(x.description, '')), '') as description,
      x.debit,
      x.credit,
      null::uuid as contact_id
    from pg_catalog.jsonb_to_recordset(p_account_lines) with ordinality as x(
      account_id uuid, debit numeric, credit numeric, description text, ordinality bigint
    )

    union all

    select
      2,
      x.ordinality,
      x.account_id,
      coalesce(nullif(pg_catalog.btrim(coalesce(x.description, '')), ''),
        case when x.party_type = 'customer' then 'Opening receivable' else 'Opening payable' end),
      case when x.party_type = 'customer' then x.amount else 0 end,
      case when x.party_type = 'supplier' then x.amount else 0 end,
      x.contact_id
    from pg_catalog.jsonb_to_recordset(p_party_balances) with ordinality as x(
      contact_id uuid, party_type text, account_id uuid, amount numeric,
      description text, ordinality bigint
    )

    union all

    select
      3,
      row_number() over (order by pr.inventory_account_id),
      pr.inventory_account_id,
      'Opening inventory',
      sum(round(x.quantity * x.unit_cost, 4)),
      0::numeric,
      null::uuid
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    join public.products pr
      on pr.organization_id = p_organization_id
     and pr.id = x.product_id
    group by pr.inventory_account_id
    having sum(round(x.quantity * x.unit_cost, 4)) > 0
  )
  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  select
    p_organization_id,
    v_journal_entry_id,
    jl.account_id,
    row_number() over (order by jl.sort_group, jl.sort_order)::integer,
    jl.description,
    jl.debit,
    jl.credit,
    jl.contact_id
  from journal_lines jl
  where jl.debit > 0 or jl.credit > 0;

  -- Initialize product-level stock balances and record auditable stock movements.
  with inventory_totals as (
    select
      x.product_id,
      sum(x.quantity) as quantity,
      sum(round(x.quantity * x.unit_cost, 4)) as inventory_value
    from pg_catalog.jsonb_to_recordset(p_inventory_lines) as x(
      product_id uuid, quantity numeric, unit_cost numeric
    )
    group by x.product_id
  )
  update public.inventory_balances b
  set quantity = t.quantity,
      inventory_value = t.inventory_value,
      average_cost = case
        when t.quantity = 0 then 0
        else round(t.inventory_value / t.quantity, 6)
      end,
      updated_at = pg_catalog.now()
  from inventory_totals t
  where b.organization_id = p_organization_id
    and b.product_id = t.product_id;

  insert into public.inventory_transactions (
    organization_id, transaction_number, product_id, transaction_date,
    transaction_type, direction, quantity, unit_cost, total_value,
    reference_type, reference_id, unit_cost_before, average_cost_after, created_by
  )
  select
    p_organization_id,
    'OB-' || pg_catalog.substr(pg_catalog.replace(p_organization_id::text, '-', ''), 1, 12)
      || '-' || x.ordinality::text,
    x.product_id,
    p_entry_date,
    'opening_balance',
    'in',
    x.quantity,
    x.unit_cost,
    round(x.quantity * x.unit_cost, 4),
    'organization_opening_balance',
    p_organization_id,
    null,
    round(x.unit_cost, 6),
    v_user_id
  from pg_catalog.jsonb_to_recordset(p_inventory_lines) with ordinality as x(
    product_id uuid, quantity numeric, unit_cost numeric, ordinality bigint
  );

  return v_journal_entry_id;
end;
$$;

create or replace function public.post_contact_payment(
  p_organization_id uuid,
  p_payment_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_payment public.payments%rowtype;
  v_cash_account public.accounts%rowtype;
  v_settlement_account public.accounts%rowtype;
  v_outstanding numeric(20,4);
  v_journal_entry_id uuid;
  v_entry_number text;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'payments.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post payments for this organization.';
  end if;

  select * into v_payment
  from public.payments
  where organization_id = p_organization_id and id = p_payment_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Payment was not found in this organization.';
  end if;
  if v_payment.status <> 'confirmed' or v_payment.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted payment can be posted.';
  end if;

  select * into v_cash_account
  from public.accounts
  where organization_id = p_organization_id and id = v_payment.account_id;
  if not found or not v_cash_account.is_active or not v_cash_account.is_postable
     or v_cash_account.account_type <> 'asset' or v_cash_account.is_control_account then
    raise exception using errcode = '23514', message = 'The payment account must be an active, postable cash/bank asset account.';
  end if;

  if v_payment.contact_id is not null then
    perform 1 from public.contacts
    where organization_id = p_organization_id and id = v_payment.contact_id and is_active
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Payment contact must be active and belong to this organization.';
    end if;
  end if;

  v_entry_number := 'PMT-' || pg_catalog.replace(v_payment.id::text, '-', '');

  if v_payment.payment_type = 'transfer' then
    if v_payment.contact_id is not null or v_payment.settlement_account_id is null
       or v_payment.account_id = v_payment.settlement_account_id then
      raise exception using errcode = '22023', message = 'A transfer requires two different cash/bank accounts and no contact.';
    end if;
    select * into v_settlement_account
    from public.accounts
    where organization_id = p_organization_id and id = v_payment.settlement_account_id;
    if not found or not v_settlement_account.is_active or not v_settlement_account.is_postable
       or v_settlement_account.account_type <> 'asset' or v_settlement_account.is_control_account then
      raise exception using errcode = '23514', message = 'Transfer destination must be an active, postable cash/bank asset account.';
    end if;

    insert into public.journal_entries (
      organization_id, entry_number, entry_date,
      entry_type, status, reference_type, reference_id, description,
      posted_at, posted_by, created_by
    )
    values (
      p_organization_id, v_entry_number, v_payment.payment_date,
      'payment', 'posted', 'payment', v_payment.id,
      coalesce(nullif(pg_catalog.btrim(v_payment.description), ''), 'Bank transfer ' || v_payment.payment_number),
      pg_catalog.now(), v_user_id, v_user_id
    )
    returning id into v_journal_entry_id;

    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
    )
    values
      (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 1,
       'Transfer in - ' || v_payment.payment_number, v_payment.amount, 0, null),
      (p_organization_id, v_journal_entry_id, v_payment.account_id, 2,
       'Transfer out - ' || v_payment.payment_number, 0, v_payment.amount, null);

  elsif v_payment.payment_type in ('receipt','payment','refund') then
    if v_payment.contact_id is null or v_payment.settlement_account_id is null
       or v_payment.account_id = v_payment.settlement_account_id then
      raise exception using errcode = '22023', message = 'A contact and a separate receivable/payable control account are required.';
    end if;
    select * into v_settlement_account
    from public.accounts
    where organization_id = p_organization_id and id = v_payment.settlement_account_id;
    if not found or not v_settlement_account.is_active or not v_settlement_account.is_postable
       or not v_settlement_account.is_control_account then
      raise exception using errcode = '23514', message = 'Settlement account must be an active, postable control account.';
    end if;

    if v_payment.payment_type = 'receipt' then
      if v_settlement_account.account_type <> 'asset' then
        raise exception using errcode = '23514', message = 'A receipt requires an accounts receivable asset control account.';
      end if;
      select coalesce(sum(atx.debit - atx.credit),0) into v_outstanding
      from public.account_transactions atx
      join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
      where atx.organization_id = p_organization_id
        and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
        and je.status in ('posted', 'reversed');
      if v_outstanding < v_payment.amount then
        raise exception using errcode = '23514', message = 'Receipt amount exceeds the current customer receivable balance.';
      end if;
    elsif v_payment.payment_type = 'payment' then
      if v_settlement_account.account_type <> 'liability' then
        raise exception using errcode = '23514', message = 'A supplier payment requires an accounts payable liability control account.';
      end if;
      select coalesce(sum(atx.credit - atx.debit),0) into v_outstanding
      from public.account_transactions atx
      join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
      where atx.organization_id = p_organization_id
        and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
        and je.status in ('posted', 'reversed');
      if v_outstanding < v_payment.amount then
        raise exception using errcode = '23514', message = 'Payment amount exceeds the current supplier payable balance.';
      end if;
    elsif v_payment.payment_type = 'refund' then
      if v_settlement_account.account_type = 'asset' then
        select coalesce(sum(atx.debit - atx.credit),0) into v_outstanding
        from public.account_transactions atx
        join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
        where atx.organization_id = p_organization_id
          and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
          and je.status in ('posted', 'reversed');
        if v_outstanding >= 0 or abs(v_outstanding) < v_payment.amount then
          raise exception using errcode = '23514', message = 'Customer refund requires a sufficient credit balance in accounts receivable.';
        end if;
      elsif v_settlement_account.account_type = 'liability' then
        select coalesce(sum(atx.credit - atx.debit),0) into v_outstanding
        from public.account_transactions atx
        join public.journal_entries je on je.organization_id = atx.organization_id and je.id = atx.journal_entry_id
        where atx.organization_id = p_organization_id
          and atx.account_id = v_payment.settlement_account_id and atx.contact_id = v_payment.contact_id
          and je.status in ('posted', 'reversed');
        if v_outstanding >= 0 or abs(v_outstanding) < v_payment.amount then
          raise exception using errcode = '23514', message = 'Supplier refund requires a sufficient debit balance in accounts payable.';
        end if;
      else
        raise exception using errcode = '23514', message = 'Refund settlement must be an accounts receivable or payable control account.';
      end if;
    end if;

    insert into public.journal_entries (
      organization_id, entry_number, entry_date,
      entry_type, status, reference_type, reference_id, description,
      posted_at, posted_by, created_by
    )
    values (
      p_organization_id, v_entry_number, v_payment.payment_date,
      'payment', 'posted', 'payment', v_payment.id,
      coalesce(nullif(pg_catalog.btrim(v_payment.description), ''),
        case v_payment.payment_type
          when 'receipt' then 'Customer receipt ' || v_payment.payment_number
          when 'payment' then 'Supplier payment ' || v_payment.payment_number
          else 'Contact refund ' || v_payment.payment_number
        end),
      pg_catalog.now(), v_user_id, v_user_id
    )
    returning id into v_journal_entry_id;

    if v_payment.payment_type = 'receipt' then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 1, 'Receipt ' || v_payment.payment_number, v_payment.amount, 0, null),
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 2, 'Receivable settled - ' || v_payment.payment_number, 0, v_payment.amount, v_payment.contact_id);
    elsif v_payment.payment_type = 'payment' then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 1, 'Payable settled - ' || v_payment.payment_number, v_payment.amount, 0, v_payment.contact_id),
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 2, 'Payment ' || v_payment.payment_number, 0, v_payment.amount, null);
    elsif v_settlement_account.account_type = 'asset' then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 1, 'Customer refund ' || v_payment.payment_number, v_payment.amount, 0, v_payment.contact_id),
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 2, 'Refund paid ' || v_payment.payment_number, 0, v_payment.amount, null);
    else
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_entry_id, v_payment.account_id, 1, 'Supplier refund received ' || v_payment.payment_number, v_payment.amount, 0, null),
        (p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 2, 'Supplier refund credited ' || v_payment.payment_number, 0, v_payment.amount, v_payment.contact_id);
    end if;
  else
    raise exception using errcode = '22023', message = 'Unsupported payment type.';
  end if;


  if exists (
    select 1 from public.payment_allocations pa
    where pa.organization_id = p_organization_id and pa.payment_id = p_payment_id
  ) then
    raise exception using errcode = '0A000',
      message = 'Invoice-wise payment allocations are not enabled in the current contact-level control-account model.';
  end if;

  update public.payments
  set status = 'posted', posted_journal_entry_id = v_journal_entry_id,
      posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_payment_id;

  return v_journal_entry_id;
end;
$function$;

create or replace function public.post_sales(
  p_organization_id uuid,
  p_sales_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_sales public.sales%rowtype;
  v_customer_active boolean;
  v_receivable public.accounts%rowtype;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_allocated_revenue numeric(20,4) := 0;
  v_line_revenue numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_line_cost numeric(20,4);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_journal_id uuid;
  v_line record;
  v_last_line integer;
  v_line_number integer := 0;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication is required to post a sales invoice.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'sales.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post sales for this organization.';
  end if;

  select s.* into v_sales
  from public.sales s
  where s.organization_id = p_organization_id and s.id = p_sales_id
  for update;

  if not found then
    raise exception using errcode = '23503', message = 'Sales invoice was not found in this organization.';
  end if;
  if v_sales.status <> 'confirmed' or v_sales.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted sales invoice can be posted.';
  end if;

  select c.is_active into v_customer_active
  from public.contacts c
  where c.organization_id = p_organization_id and c.id = v_sales.customer_id
  for update;
  if coalesce(v_customer_active, false) is not true then
    raise exception using errcode = '23503', message = 'Customer must be active and belong to this organization.';
  end if;

  select a.* into v_receivable
  from public.accounts a
  where a.organization_id = p_organization_id and a.id = v_sales.receivable_account_id;
  if not found or not v_receivable.is_active or not v_receivable.is_postable
     or not v_receivable.is_control_account or v_receivable.account_type <> 'asset' then
    raise exception using errcode = '23503',
      message = 'Receivable account must be an active, postable asset control account.';
  end if;

  select count(*)::integer, coalesce(sum(si.line_total), 0), max(si.line_number)
  into v_line_count, v_subtotal, v_last_line
  from public.sales_items si
  where si.organization_id = p_organization_id and si.sales_id = p_sales_id;

  if v_line_count < 1 then
    raise exception using errcode = '23514', message = 'A sales invoice must contain at least one item.';
  end if;
  if v_subtotal <> v_sales.subtotal then
    raise exception using errcode = '23514', message = 'Sales subtotal must equal the sum of item line totals.';
  end if;
  if v_sales.discount_amount > v_subtotal
     or v_sales.total_amount <> v_subtotal - v_sales.discount_amount
     or v_sales.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Sales totals are inconsistent or net total is not positive.';
  end if;

  if exists (
    select 1
    from public.sales_items si
    join public.products pr on pr.organization_id = si.organization_id and pr.id = si.product_id
    left join public.accounts sa on sa.organization_id = pr.organization_id and sa.id = pr.sales_account_id
    left join public.accounts ia on ia.organization_id = pr.organization_id and ia.id = pr.inventory_account_id
    left join public.accounts ca on ca.organization_id = pr.organization_id and ca.id = pr.cogs_account_id
    where si.organization_id = p_organization_id and si.sales_id = p_sales_id
      and (
        not pr.is_active
        or sa.id is null or not sa.is_active or not sa.is_postable or sa.account_type <> 'revenue'
        or ia.id is null or not ia.is_active or not ia.is_postable or ia.account_type <> 'asset'
        or ca.id is null or not ca.is_active or not ca.is_postable or ca.account_type <> 'expense'
        or si.line_total <> round(si.quantity * si.unit_price, 4)
      )
  ) then
    raise exception using errcode = '23514',
      message = 'Each item requires an active product, valid revenue/inventory/COGS accounts, and a consistent line total.';
  end if;

  -- Lock each product balance in deterministic order and reject insufficient stock.
  for v_line in
    select distinct si.product_id
    from public.sales_items si
    where si.organization_id = p_organization_id and si.sales_id = p_sales_id
    order by si.product_id
  loop
    select b.quantity, b.inventory_value, b.average_cost
    into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    if not found then
      raise exception using errcode = '23514',
        message = 'Opening stock or a prior stock receipt is required before this product can be sold.';
    end if;

    if v_balance_quantity < (
      select coalesce(sum(si.quantity), 0)
      from public.sales_items si
      where si.organization_id = p_organization_id
        and si.sales_id = p_sales_id and si.product_id = v_line.product_id
    ) then
      raise exception using errcode = '23514',
        message = 'Insufficient stock to post this sales invoice.';
    end if;
    if v_balance_quantity < 0 or v_balance_value < 0 then
      raise exception using errcode = '23514',
        message = 'Negative inventory balance must be reconciled before sales posting.';
    end if;
  end loop;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description, posted_at, posted_by, created_by
  )
  values (
    p_organization_id,
    'SAL-' || pg_catalog.replace(p_sales_id::text, '-', ''),
    v_sales.invoice_date, 'sale', 'posted',
    'sale', p_sales_id, 'Sales invoice ' || v_sales.invoice_id,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  -- Allocate net sales revenue to products/accounts; last line absorbs rounding residue.
  for v_line in
    select si.id, si.product_id, si.quantity, si.line_total, si.line_number,
           pr.sales_account_id, pr.inventory_account_id, pr.cogs_account_id
    from public.sales_items si
    join public.products pr on pr.organization_id = si.organization_id and pr.id = si.product_id
    where si.organization_id = p_organization_id and si.sales_id = p_sales_id
    order by si.line_number
  loop
    if v_line.line_number = v_last_line then
      v_line_revenue := v_sales.total_amount - v_allocated_revenue;
    else
      v_line_revenue := round(v_line.line_total * v_sales.total_amount / v_subtotal, 4);
      v_allocated_revenue := v_allocated_revenue + v_line_revenue;
    end if;

    select b.quantity, b.inventory_value, b.average_cost
    into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    v_line_cost := case when v_line.quantity = v_balance_quantity
      then v_balance_value else round(v_line.quantity * v_average_cost, 4) end;
    v_new_quantity := v_balance_quantity - v_line.quantity;
    v_new_value := v_balance_value - v_line_cost;

    if v_new_quantity < 0 or v_new_value < 0 then
      raise exception using errcode = '23514',
        message = 'Sales would create a negative stock quantity or inventory value.';
    end if;

    update public.inventory_balances
    set quantity = v_new_quantity,
        inventory_value = v_new_value,
        average_cost = case when v_new_quantity = 0 then 0 else v_average_cost end,
        updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_line.product_id;

    update public.sales_items
    set cogs_unit_cost = v_average_cost,
        cogs_total = v_line_cost,
        updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_line.id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'SAL-' || pg_catalog.replace(p_sales_id::text, '-', '') || '-' || v_line.line_number::text,
      v_line.product_id, v_sales.invoice_date, 'sale', 'out', v_line.quantity,
      v_average_cost, v_line_cost, 'sale', p_sales_id,
      v_average_cost, case when v_new_quantity = 0 then 0 else v_average_cost end, v_user_id
    );

    -- Revenue line, net of the proportionally allocated invoice discount.
    if v_line_revenue > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number,
        description, debit, credit, contact_id
      )
      values (
        p_organization_id, v_journal_id, v_line.sales_account_id, v_line_number + 1,
        'Sales revenue - ' || v_sales.invoice_id, 0, v_line_revenue, null
      );
      v_line_number := v_line_number + 1;
    end if;

    -- COGS debit and inventory credit are posted per invoice line.
    if v_line_cost > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number,
        description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_id, v_line.cogs_account_id, v_line_number + 1,
         'Cost of goods sold - ' || v_sales.invoice_id, v_line_cost, 0, null),
        (p_organization_id, v_journal_id, v_line.inventory_account_id, v_line_number + 2,
         'Inventory issued - ' || v_sales.invoice_id, 0, v_line_cost, null);
      v_line_number := v_line_number + 2;
    end if;
  end loop;

  -- Receivable debit is the single contact-tagged customer balance line.
  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_sales.receivable_account_id,
    v_line_number + 1, 'Accounts receivable - ' || v_sales.invoice_id,
    v_sales.total_amount, 0, v_sales.customer_id
  );

  update public.sales
  set status = 'posted', posted_journal_entry_id = v_journal_id, posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_sales_id;

  return v_journal_id;
end;
$$;

create or replace function public.reverse_journal_entry(
  p_organization_id uuid,
  p_journal_entry_id uuid,
  p_reversal_date date,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_original public.journal_entries%rowtype;
  v_reversal_id uuid;
  v_source_status text;
  v_source_purchase_id uuid;
  v_source_sales_id uuid;
  v_inventory record;
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_direction text;
  v_txn_line integer := 0;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'journal_entries.reverse') then
    raise exception using errcode = '42501', message = 'You are not authorized to reverse journal entries for this organization.';
  end if;
  if p_reversal_date is null or p_reason is null or pg_catalog.length(pg_catalog.btrim(p_reason)) < 3 then
    raise exception using errcode = '22023', message = 'A reversal date and reason of at least three characters are required.';
  end if;

  select * into v_original
  from public.journal_entries
  where organization_id = p_organization_id and id = p_journal_entry_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Original journal entry was not found in this organization.';
  end if;
  if v_original.status <> 'posted' or v_original.reversal_of_id is not null
     or v_original.entry_type not in ('manual','expense','payment','purchase_return','sales_return') then
    raise exception using errcode = '23514',
      message = 'Only posted manual, expense, payment, and return journals can be reversed here. Purchase and sales invoices require return documents; opening balances require a controlled adjustment.';
  end if;
  if exists (
    select 1 from public.journal_entries
    where organization_id = p_organization_id and reversal_of_id = p_journal_entry_id
  ) then
    raise exception using errcode = '23514', message = 'This journal entry has already been reversed.';
  end if;

  if v_original.entry_type = 'expense' then
    select e.status into v_source_status
    from public.expenses e
    where e.organization_id = p_organization_id and e.id = v_original.reference_id
      and e.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Expense source document is missing, already reversed, or no longer posted.';
    end if;
  elsif v_original.entry_type = 'payment' then
    select p.status into v_source_status
    from public.payments p
    where p.organization_id = p_organization_id and p.id = v_original.reference_id
      and p.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Payment source document is missing, already reversed, or no longer posted.';
    end if;
  elsif v_original.entry_type = 'purchase_return' then
    select pr.status, pr.purchase_id into v_source_status, v_source_purchase_id
    from public.purchase_returns pr
    where pr.organization_id = p_organization_id and pr.id = v_original.reference_id
      and pr.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Purchase return source document is missing, already reversed, or no longer posted.';
    end if;
    perform 1 from public.purchase
    where organization_id = p_organization_id and id = v_source_purchase_id
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Original purchase for this return no longer exists.';
    end if;
  elsif v_original.entry_type = 'sales_return' then
    select sr.status, sr.sales_id into v_source_status, v_source_sales_id
    from public.sales_returns sr
    where sr.organization_id = p_organization_id and sr.id = v_original.reference_id
      and sr.posted_journal_entry_id = p_journal_entry_id
    for update;
    if v_source_status is distinct from 'posted' then
      raise exception using errcode = '23514', message = 'Sales return source document is missing, already reversed, or no longer posted.';
    end if;
    perform 1 from public.sales
    where organization_id = p_organization_id and id = v_source_sales_id
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Original sales invoice for this return no longer exists.';
    end if;
  end if;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, reversal_of_id, created_by
  )
  values (
    p_organization_id,
    'REV-' || pg_catalog.replace(p_journal_entry_id::text,'-',''),
    p_reversal_date, 'reversal', 'posted',
    'journal_entry_reversal', p_journal_entry_id,
    'Reversal of ' || v_original.entry_number || ': ' || pg_catalog.btrim(p_reason),
    pg_catalog.now(), v_user_id, p_journal_entry_id, v_user_id
  )
  returning id into v_reversal_id;

  if v_original.entry_type in ('purchase_return','sales_return') then
    if not exists (
      select 1 from public.inventory_transactions it
      where it.organization_id = p_organization_id
        and it.reference_type = v_original.reference_type
        and it.reference_id = v_original.reference_id
    ) then
      raise exception using errcode = '23514', message = 'Return journal has no inventory movements to reverse.';
    end if;

    for v_inventory in
      select distinct it.product_id
      from public.inventory_transactions it
      where it.organization_id = p_organization_id
        and it.reference_type = v_original.reference_type
        and it.reference_id = v_original.reference_id
      order by it.product_id
    loop
      perform 1 from public.inventory_balances b
      where b.organization_id = p_organization_id and b.product_id = v_inventory.product_id
      for update;
      if not found then
        raise exception using errcode = '23514', message = 'Inventory balance is missing for a returned product.';
      end if;
    end loop;

    for v_inventory in
      select it.*
      from public.inventory_transactions it
      where it.organization_id = p_organization_id
        and it.reference_type = v_original.reference_type
        and it.reference_id = v_original.reference_id
      order by it.product_id, it.transaction_number
    loop
      select b.quantity, b.inventory_value, b.average_cost
        into v_balance_quantity, v_balance_value, v_average_cost
      from public.inventory_balances b
      where b.organization_id = p_organization_id and b.product_id = v_inventory.product_id
      for update;

      if v_original.entry_type = 'purchase_return' then
        v_direction := 'in';
        v_new_quantity := v_balance_quantity + v_inventory.quantity;
        v_new_value := v_balance_value + v_inventory.total_value;
      else
        v_direction := 'out';
        v_new_quantity := v_balance_quantity - v_inventory.quantity;
        v_new_value := v_balance_value - v_inventory.total_value;
        if v_new_quantity < 0 or v_new_value < 0 then
          raise exception using errcode = '23514', message = 'Cannot reverse this sales return because the returned stock has already been consumed.';
        end if;
      end if;
      v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity,6) end;

      update public.inventory_balances
      set quantity = v_new_quantity, inventory_value = v_new_value,
          average_cost = v_new_average, updated_at = pg_catalog.now()
      where organization_id = p_organization_id and product_id = v_inventory.product_id;

      v_txn_line := v_txn_line + 1;
      insert into public.inventory_transactions (
        organization_id, transaction_number, product_id, transaction_date,
        transaction_type, direction, quantity, unit_cost, total_value,
        reference_type, reference_id, unit_cost_before, average_cost_after, created_by
      )
      values (
        p_organization_id,
        'REV-' || pg_catalog.replace(v_reversal_id::text,'-','') || '-' || v_txn_line::text,
        v_inventory.product_id, p_reversal_date, 'adjustment', v_direction,
        v_inventory.quantity, v_inventory.unit_cost, v_inventory.total_value,
        'journal_entry_reversal', v_reversal_id, v_average_cost, v_new_average, v_user_id
      );
    end loop;
  end if;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  select
    p_organization_id, v_reversal_id, atx.account_id,
    row_number() over (order by atx.line_number)::integer,
    'Reversal: ' || coalesce(atx.description, v_original.entry_number),
    atx.credit, atx.debit, atx.contact_id
  from public.account_transactions atx
  where atx.organization_id = p_organization_id and atx.journal_entry_id = p_journal_entry_id;

  if not exists (
    select 1 from public.account_transactions
    where organization_id = p_organization_id and journal_entry_id = v_reversal_id
  ) then
    raise exception using errcode = '23514', message = 'Original journal entry has no ledger lines to reverse.';
  end if;

  update public.journal_entries
  set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
      reversed_at = pg_catalog.now(), reversed_by = v_user_id,
      reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_journal_entry_id;

  if v_original.entry_type = 'expense' then
    update public.expenses
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;
  elsif v_original.entry_type = 'payment' then
    update public.payments
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;
  elsif v_original.entry_type = 'purchase_return' then
    update public.purchase_returns
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;

    if exists (
      select 1 from public.purchase_returns pr
      where pr.organization_id = p_organization_id and pr.purchase_id = v_source_purchase_id and pr.status = 'posted'
    ) then
      if exists (
        select 1 from public.purchase_items pi
        where pi.organization_id = p_organization_id and pi.purchase_id = v_source_purchase_id
          and pi.quantity > coalesce((
            select sum(pri.quantity)
            from public.purchase_return_items pri
            join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
            where pri.organization_id = p_organization_id and pri.purchase_item_id = pi.id and pr.status = 'posted'
          ),0)
      ) then
        update public.purchase set status = 'partially_returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_purchase_id;
      else
        update public.purchase set status = 'returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_purchase_id;
      end if;
    else
      update public.purchase set status = 'posted', updated_at = pg_catalog.now()
      where organization_id = p_organization_id and id = v_source_purchase_id;
    end if;
  elsif v_original.entry_type = 'sales_return' then
    update public.sales_returns
    set status = 'reversed', reversal_journal_entry_id = v_reversal_id,
        reversed_at = pg_catalog.now(), reversed_by = v_user_id,
        reversal_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_original.reference_id;

    if exists (
      select 1 from public.sales_returns sr
      where sr.organization_id = p_organization_id and sr.sales_id = v_source_sales_id and sr.status = 'posted'
    ) then
      if exists (
        select 1 from public.sales_items si
        where si.organization_id = p_organization_id and si.sales_id = v_source_sales_id
          and si.quantity > coalesce((
            select sum(sri.quantity)
            from public.sales_return_items sri
            join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
            where sri.organization_id = p_organization_id and sri.sales_item_id = si.id and sr.status = 'posted'
          ),0)
      ) then
        update public.sales set status = 'partially_returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_sales_id;
      else
        update public.sales set status = 'returned', updated_at = pg_catalog.now()
        where organization_id = p_organization_id and id = v_source_sales_id;
      end if;
    else
      update public.sales set status = 'posted', updated_at = pg_catalog.now()
      where organization_id = p_organization_id and id = v_source_sales_id;
    end if;
  end if;

  return v_reversal_id;
end;
$function$;

create or replace function public.post_expense(
  p_organization_id uuid,
  p_expense_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_expense public.expenses%rowtype;
  v_expense_account_id uuid;
  v_category_active boolean;
  v_expense_account public.accounts%rowtype;
  v_payable_account public.accounts%rowtype;
  v_journal_id uuid;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'expenses.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post expenses for this organization.';
  end if;

  select * into v_expense
  from public.expenses
  where organization_id = p_organization_id and id = p_expense_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Expense was not found in this organization.';
  end if;
  if v_expense.status <> 'confirmed' or v_expense.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted expense can be posted.';
  end if;
  if v_expense.amount <= 0 or v_expense.payable_account_id is null then
    raise exception using errcode = '23514', message = 'Expense amount and payable account are required before posting.';
  end if;

  select ec.expense_account_id, ec.is_active
    into v_expense_account_id, v_category_active
  from public.expense_categories ec
  where ec.organization_id = p_organization_id and ec.id = v_expense.expense_category_id;
  if not found or not v_category_active or v_expense_account_id is null then
    raise exception using errcode = '23503', message = 'Expense category must be active and mapped to an expense account.';
  end if;

  select * into v_expense_account
  from public.accounts
  where organization_id = p_organization_id and id = v_expense_account_id;
  if not found or not v_expense_account.is_active or not v_expense_account.is_postable
     or v_expense_account.account_type <> 'expense' then
    raise exception using errcode = '23514', message = 'Expense category account must be an active, postable expense account.';
  end if;

  select * into v_payable_account
  from public.accounts
  where organization_id = p_organization_id and id = v_expense.payable_account_id;
  if not found or not v_payable_account.is_active or not v_payable_account.is_postable
     or v_payable_account.account_type <> 'liability' then
    raise exception using errcode = '23514', message = 'Expense payable account must be an active, postable liability account.';
  end if;

  if v_expense.contact_id is not null then
    if not v_payable_account.is_control_account then
      raise exception using errcode = '23514', message = 'A contact-linked expense requires a payable control account.';
    end if;
    perform 1 from public.contacts
    where organization_id = p_organization_id and id = v_expense.contact_id and is_active
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'Expense contact must be active and belong to this organization.';
    end if;
  elsif v_payable_account.is_control_account then
    raise exception using errcode = '23514', message = 'A payable control account requires an expense contact.';
  end if;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, 'EXP-' || pg_catalog.replace(p_expense_id::text, '-', ''),
    v_expense.expense_date, 'expense', 'posted',
    'expense', p_expense_id,
    coalesce(nullif(pg_catalog.btrim(v_expense.description), ''), 'Expense ' || v_expense.expense_number),
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  values
    (p_organization_id, v_journal_id, v_expense_account.id, 1,
     'Expense - ' || v_expense.expense_number, v_expense.amount, 0, null),
    (p_organization_id, v_journal_id, v_payable_account.id, 2,
     'Expense payable - ' || v_expense.expense_number, 0, v_expense.amount, v_expense.contact_id);

  update public.expenses
  set status = 'posted', posted_journal_entry_id = v_journal_id,
      posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_expense_id;
  return v_journal_id;
end;
$function$;

create or replace function public.post_purchase_return(
  p_organization_id uuid,
  p_purchase_return_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_return public.purchase_returns%rowtype;
  v_purchase public.purchase%rowtype;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_inventory_value numeric(20,4) := 0;
  v_variance numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_return_quantity numeric(20,6);
  v_line_value numeric(20,4);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_journal_id uuid;
  v_line_number integer := 1;
  v_product record;
  v_account record;
  v_variance_account public.accounts%rowtype;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'purchases.returns.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post purchase returns for this organization.';
  end if;

  select * into v_return from public.purchase_returns
  where organization_id = p_organization_id and id = p_purchase_return_id for update;
  if not found then
    raise exception using errcode = '23503', message = 'Purchase return was not found in this organization.';
  end if;
  if v_return.status <> 'confirmed' or v_return.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted purchase return can be posted.';
  end if;

  select * into v_purchase from public.purchase
  where organization_id = p_organization_id and id = v_return.purchase_id for update;
  if not found or v_purchase.status not in ('posted','partially_returned') then
    raise exception using errcode = '23514', message = 'Purchase return requires a posted purchase that has not been fully returned.';
  end if;
  if v_return.supplier_id <> v_purchase.supplier_id
     or v_return.payable_account_id <> v_purchase.payable_account_id then
    raise exception using errcode = '23514', message = 'Purchase return supplier and payable account must match the original purchase.';
  end if;

  if v_return.total_amount + coalesce((
    select sum(pr.total_amount) from public.purchase_returns pr
    where pr.organization_id = p_organization_id and pr.purchase_id = v_purchase.id and pr.status = 'posted'
  ),0) > v_purchase.total_amount then
    raise exception using errcode = '23514', message = 'Cumulative purchase returns cannot exceed the original purchase total.';
  end if;

  select count(*)::integer, coalesce(sum(line_total),0)
    into v_line_count, v_subtotal
  from public.purchase_return_items
  where organization_id = p_organization_id and purchase_return_id = p_purchase_return_id;
  if v_line_count < 1 or v_subtotal <> v_return.subtotal
     or v_return.discount_amount > v_subtotal
     or v_return.total_amount <> v_subtotal - v_return.discount_amount
     or v_return.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Purchase return items, subtotal, discount, and total are inconsistent.';
  end if;

  if exists (
    select 1
    from public.purchase_return_items ri
    join public.purchase_items pi on pi.organization_id = ri.organization_id and pi.id = ri.purchase_item_id
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
      and (pi.purchase_id <> v_purchase.id or pi.product_id <> ri.product_id
        or pi.unit_cost <> ri.unit_cost or ri.line_total <> round(ri.quantity * ri.unit_cost,4)
        or ri.quantity + coalesce((
          select sum(pri.quantity)
          from public.purchase_return_items pri
          join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
          where pri.organization_id = p_organization_id and pri.purchase_item_id = ri.purchase_item_id
            and pr.status = 'posted'
        ),0) > pi.quantity)
  ) then
    raise exception using errcode = '23514', message = 'Return quantity or unit cost exceeds the unreturned quantity/cost of the original purchase item.';
  end if;


  if exists (
    select 1
    from public.purchase_return_items ri
    join public.purchase_items pi on pi.organization_id = ri.organization_id and pi.id = ri.purchase_item_id
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
    group by ri.purchase_item_id, pi.quantity
    having sum(ri.quantity) + coalesce((
      select sum(pri.quantity)
      from public.purchase_return_items pri
      join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
      where pri.organization_id = p_organization_id and pri.purchase_item_id = ri.purchase_item_id and pr.status = 'posted'
    ),0) > pi.quantity
  ) then
    raise exception using errcode = '23514', message = 'Combined return lines cannot exceed the remaining quantity of an original purchase item.';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.organization_id = p_organization_id and a.id = v_return.payable_account_id
      and a.is_active and a.is_postable and a.is_control_account and a.account_type = 'liability'
  ) then
    raise exception using errcode = '23514', message = 'Purchase return payable account must be an active liability control account.';
  end if;

  if exists (
    select 1 from public.purchase_return_items ri
    join public.products pr on pr.organization_id = ri.organization_id and pr.id = ri.product_id
    left join public.accounts ia on ia.organization_id = pr.organization_id and ia.id = pr.inventory_account_id
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
      and (ia.id is null or not ia.is_active or not ia.is_postable or ia.account_type <> 'asset')
  ) then
    raise exception using errcode = '23514', message = 'Every returned product must be active and mapped to an active, postable inventory asset account.';
  end if;

  for v_product in
    select ri.product_id, sum(ri.quantity) as quantity
    from public.purchase_return_items ri
    where ri.organization_id = p_organization_id and ri.purchase_return_id = p_purchase_return_id
    group by ri.product_id order by ri.product_id
  loop
    select b.quantity, b.inventory_value, b.average_cost
      into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_product.product_id
    for update;
    if not found then
      raise exception using errcode = '23514', message = 'Returned product has no inventory balance to reduce.';
    end if;
    v_return_quantity := v_product.quantity;
    v_line_value := case when v_return_quantity = v_balance_quantity
      then v_balance_value else round(v_return_quantity * v_average_cost,4) end;
    if v_balance_quantity < v_return_quantity or v_balance_value < v_line_value then
      raise exception using errcode = '23514', message = 'Insufficient on-hand quantity or inventory value for this purchase return.';
    end if;
    v_new_quantity := v_balance_quantity - v_return_quantity;
    v_new_value := v_balance_value - v_line_value;
    v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity,6) end;
    update public.inventory_balances
    set quantity = v_new_quantity, inventory_value = v_new_value,
        average_cost = v_new_average, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_product.product_id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'PR-' || pg_catalog.replace(p_purchase_return_id::text,'-','') || '-' || pg_catalog.replace(v_product.product_id::text,'-',''),
      v_product.product_id, v_return.return_date, 'purchase_return', 'out',
      v_return_quantity, v_average_cost, v_line_value,
      'purchase_return', p_purchase_return_id, v_average_cost, v_new_average, v_user_id
    );
    v_inventory_value := v_inventory_value + v_line_value;
  end loop;

  v_variance := v_return.total_amount - v_inventory_value;
  if v_variance <> 0 then
    select * into v_variance_account
    from public.accounts
    where organization_id = p_organization_id and id = v_return.purchase_return_variance_account_id;
    if not found or not v_variance_account.is_active or not v_variance_account.is_postable
       or (v_variance > 0 and v_variance_account.account_type <> 'revenue')
       or (v_variance < 0 and v_variance_account.account_type <> 'expense') then
      raise exception using errcode = '23514',
        message = 'Purchase return requires a postable revenue variance account when supplier credit exceeds inventory carrying value, or an expense variance account when it is lower.';
    end if;
  end if;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, 'PR-' || pg_catalog.replace(p_purchase_return_id::text,'-',''),
    v_return.return_date, 'purchase_return', 'posted',
    'purchase_return', p_purchase_return_id, 'Purchase return ' || v_return.return_number,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_return.payable_account_id, v_line_number,
    'Supplier credit - ' || v_return.return_number, v_return.total_amount, 0, v_return.supplier_id
  );
  v_line_number := v_line_number + 1;

  for v_account in
    select pr.inventory_account_id as account_id, sum(it.total_value) as amount
    from public.inventory_transactions it
    join public.products pr on pr.organization_id = it.organization_id and pr.id = it.product_id
    where it.organization_id = p_organization_id
      and it.reference_type = 'purchase_return' and it.reference_id = p_purchase_return_id
    group by pr.inventory_account_id order by pr.inventory_account_id
  loop
    if v_account.amount > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values (p_organization_id, v_journal_id, v_account.account_id, v_line_number,
        'Inventory returned to supplier - ' || v_return.return_number, 0, v_account.amount, null);
      v_line_number := v_line_number + 1;
    end if;
  end loop;

  if v_variance > 0 then
    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
    )
    values (p_organization_id, v_journal_id, v_variance_account.id, v_line_number,
      'Purchase return price variance - ' || v_return.return_number, 0, v_variance, null);
  elsif v_variance < 0 then
    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
    )
    values (p_organization_id, v_journal_id, v_variance_account.id, v_line_number,
      'Purchase return price variance - ' || v_return.return_number, abs(v_variance), 0, null);
  end if;

  update public.purchase_returns
  set status = 'posted', posted_journal_entry_id = v_journal_id, posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_purchase_return_id;

  if exists (
    select 1 from public.purchase_items pi
    where pi.organization_id = p_organization_id and pi.purchase_id = v_purchase.id
      and pi.quantity > coalesce((
        select sum(pri.quantity)
        from public.purchase_return_items pri
        join public.purchase_returns pr on pr.organization_id = pri.organization_id and pr.id = pri.purchase_return_id
        where pri.organization_id = p_organization_id and pri.purchase_item_id = pi.id and pr.status = 'posted'
      ),0)
  ) then
    update public.purchase set status = 'partially_returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_purchase.id;
  else
    update public.purchase set status = 'returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_purchase.id;
  end if;
  return v_journal_id;
end;
$function$;

create or replace function public.post_sales_return(
  p_organization_id uuid,
  p_sales_return_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_return public.sales_returns%rowtype;
  v_sales public.sales%rowtype;
  v_line_count integer;
  v_subtotal numeric(20,4);
  v_allocated_revenue numeric(20,4) := 0;
  v_line_revenue numeric(20,4);
  v_line_cost numeric(20,4);
  v_previously_returned_quantity numeric(20,6);
  v_previously_returned_cogs numeric(20,4);
  v_remaining_quantity numeric(20,6);
  v_remaining_cogs numeric(20,4);
  v_balance_quantity numeric(20,6);
  v_balance_value numeric(20,4);
  v_average_cost numeric(20,6);
  v_new_quantity numeric(20,6);
  v_new_value numeric(20,4);
  v_new_average numeric(20,6);
  v_journal_id uuid;
  v_line_number integer := 1;
  v_last_line integer;
  v_line record;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'sales.returns.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post sales returns for this organization.';
  end if;

  select * into v_return from public.sales_returns
  where organization_id = p_organization_id and id = p_sales_return_id for update;
  if not found then
    raise exception using errcode = '23503', message = 'Sales return was not found in this organization.';
  end if;
  if v_return.status <> 'confirmed' or v_return.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted sales return can be posted.';
  end if;

  select * into v_sales from public.sales
  where organization_id = p_organization_id and id = v_return.sales_id for update;
  if not found or v_sales.status not in ('posted','partially_returned') then
    raise exception using errcode = '23514', message = 'Sales return requires a posted sales invoice that has not been fully returned.';
  end if;
  if v_return.customer_id <> v_sales.customer_id
     or v_return.receivable_account_id <> v_sales.receivable_account_id then
    raise exception using errcode = '23514', message = 'Sales return customer and receivable account must match the original sales invoice.';
  end if;

  if v_return.total_amount + coalesce((
    select sum(sr.total_amount) from public.sales_returns sr
    where sr.organization_id = p_organization_id and sr.sales_id = v_sales.id and sr.status = 'posted'
  ),0) > v_sales.total_amount then
    raise exception using errcode = '23514', message = 'Cumulative sales returns cannot exceed the original sales invoice total.';
  end if;

  select count(*)::integer, coalesce(sum(line_total),0), max(line_number)
    into v_line_count, v_subtotal, v_last_line
  from public.sales_return_items
  where organization_id = p_organization_id and sales_return_id = p_sales_return_id;
  if v_line_count < 1 or v_subtotal <> v_return.subtotal
     or v_return.discount_amount > v_subtotal
     or v_return.total_amount <> v_subtotal - v_return.discount_amount
     or v_return.total_amount <= 0 then
    raise exception using errcode = '23514', message = 'Sales return items, subtotal, discount, and total are inconsistent.';
  end if;

  if v_return.total_amount > coalesce((
    select round(sum(ri.line_total * v_sales.total_amount / nullif(v_sales.subtotal, 0)), 4)
    from public.sales_return_items ri
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
      and v_sales.subtotal > 0
  ), 0) then
    raise exception using errcode = '23514',
      message = 'Sales return total cannot exceed the original net value of the returned lines after allocating the invoice discount.';
  end if;

  if exists (
    select 1
    from public.sales_return_items ri
    join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
      and (si.sales_id <> v_sales.id or si.product_id <> ri.product_id
        or si.unit_price <> ri.unit_price or ri.line_total <> round(ri.quantity * ri.unit_price,4)
        or ri.quantity + coalesce((
          select sum(sri.quantity)
          from public.sales_return_items sri
          join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
          where sri.organization_id = p_organization_id and sri.sales_item_id = ri.sales_item_id and sr.status = 'posted'
        ),0) > si.quantity)
  ) then
    raise exception using errcode = '23514', message = 'Return quantity or unit price exceeds the unreturned quantity/price of the original sales item.';
  end if;


  if exists (
    select 1
    from public.sales_return_items ri
    join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
    group by ri.sales_item_id, si.quantity
    having sum(ri.quantity) + coalesce((
      select sum(sri.quantity)
      from public.sales_return_items sri
      join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
      where sri.organization_id = p_organization_id and sri.sales_item_id = ri.sales_item_id and sr.status = 'posted'
    ),0) > si.quantity
  ) then
    raise exception using errcode = '23514', message = 'Combined return lines cannot exceed the remaining quantity of an original sales item.';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.organization_id = p_organization_id and a.id = v_return.receivable_account_id
      and a.is_active and a.is_postable and a.is_control_account and a.account_type = 'asset'
  ) then
    raise exception using errcode = '23514', message = 'Sales return receivable account must be an active asset control account.';
  end if;

  if exists (
    select 1
    from public.sales_return_items ri
    join public.products pr on pr.organization_id = ri.organization_id and pr.id = ri.product_id
    left join public.accounts sa on sa.organization_id = pr.organization_id and sa.id = pr.sales_account_id
    left join public.accounts ia on ia.organization_id = pr.organization_id and ia.id = pr.inventory_account_id
    left join public.accounts ca on ca.organization_id = pr.organization_id and ca.id = pr.cogs_account_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
      and (sa.id is null or not sa.is_active or not sa.is_postable or sa.account_type <> 'revenue'
        or ia.id is null or not ia.is_active or not ia.is_postable or ia.account_type <> 'asset'
        or ca.id is null or not ca.is_active or not ca.is_postable or ca.account_type <> 'expense')
  ) then
    raise exception using errcode = '23514', message = 'Returned products require active, postable revenue, inventory, and COGS account mappings.';
  end if;

  for v_line in
    select distinct ri.product_id
    from public.sales_return_items ri
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
    order by ri.product_id
  loop
    perform 1 from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;
    if not found then
      raise exception using errcode = '23514', message = 'Returned product has no inventory balance row.';
    end if;
  end loop;

  insert into public.journal_entries (
    organization_id, entry_number, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, posted_by, created_by
  )
  values (
    p_organization_id, 'SR-' || pg_catalog.replace(p_sales_return_id::text,'-',''),
    v_return.return_date, 'sales_return', 'posted',
    'sales_return', p_sales_return_id, 'Sales return ' || v_return.return_number,
    pg_catalog.now(), v_user_id, v_user_id
  )
  returning id into v_journal_id;

  for v_line in
    select ri.id, ri.sales_item_id, ri.product_id, ri.quantity, ri.line_total, ri.line_number,
           si.cogs_unit_cost, si.quantity as sold_quantity, si.cogs_total as sold_cogs_total,
           pr.sales_account_id, pr.inventory_account_id, pr.cogs_account_id
    from public.sales_return_items ri
    join public.sales_items si on si.organization_id = ri.organization_id and si.id = ri.sales_item_id
    join public.products pr on pr.organization_id = ri.organization_id and pr.id = ri.product_id
    where ri.organization_id = p_organization_id and ri.sales_return_id = p_sales_return_id
    order by ri.line_number
  loop
    if v_line.line_number = v_last_line then
      v_line_revenue := v_return.total_amount - v_allocated_revenue;
    else
      v_line_revenue := round(v_line.line_total * v_return.total_amount / v_subtotal,4);
      v_allocated_revenue := v_allocated_revenue + v_line_revenue;
    end if;
    select coalesce(sum(sri.quantity),0), coalesce(sum(sri.cogs_total),0)
      into v_previously_returned_quantity, v_previously_returned_cogs
    from public.sales_return_items sri
    join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
    where sri.organization_id = p_organization_id
      and sri.sales_item_id = v_line.sales_item_id
      and sr.status = 'posted';

    v_remaining_quantity := v_line.sold_quantity - v_previously_returned_quantity;
    v_remaining_cogs := v_line.sold_cogs_total - v_previously_returned_cogs;
    if v_line.quantity = v_remaining_quantity then
      v_line_cost := v_remaining_cogs;
    else
      v_line_cost := least(
        round(v_line.quantity * v_remaining_cogs / v_remaining_quantity,4),
        v_remaining_cogs
      );
    end if;

    select b.quantity, b.inventory_value, b.average_cost
      into v_balance_quantity, v_balance_value, v_average_cost
    from public.inventory_balances b
    where b.organization_id = p_organization_id and b.product_id = v_line.product_id
    for update;

    v_new_quantity := v_balance_quantity + v_line.quantity;
    v_new_value := v_balance_value + v_line_cost;
    v_new_average := case when v_new_quantity = 0 then 0 else round(v_new_value / v_new_quantity,6) end;

    update public.inventory_balances
    set quantity = v_new_quantity, inventory_value = v_new_value,
        average_cost = v_new_average, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and product_id = v_line.product_id;

    update public.sales_return_items
    set cogs_unit_cost = v_line.cogs_unit_cost, cogs_total = v_line_cost, updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_line.id;

    insert into public.inventory_transactions (
      organization_id, transaction_number, product_id, transaction_date,
      transaction_type, direction, quantity, unit_cost, total_value,
      reference_type, reference_id, unit_cost_before, average_cost_after, created_by
    )
    values (
      p_organization_id,
      'SR-' || pg_catalog.replace(p_sales_return_id::text,'-','') || '-' || v_line.line_number::text,
      v_line.product_id, v_return.return_date, 'sales_return', 'in',
      v_line.quantity, v_line.cogs_unit_cost, v_line_cost,
      'sales_return', p_sales_return_id, v_average_cost, v_new_average, v_user_id
    );

    if v_line_revenue > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values (p_organization_id, v_journal_id, v_line.sales_account_id, v_line_number,
        'Sales return - ' || v_return.return_number, v_line_revenue, 0, null);
      v_line_number := v_line_number + 1;
    end if;

    if v_line_cost > 0 then
      insert into public.account_transactions (
        organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
      )
      values
        (p_organization_id, v_journal_id, v_line.inventory_account_id, v_line_number,
         'Inventory returned by customer - ' || v_return.return_number, v_line_cost, 0, null),
        (p_organization_id, v_journal_id, v_line.cogs_account_id, v_line_number + 1,
         'Reverse cost of goods sold - ' || v_return.return_number, 0, v_line_cost, null);
      v_line_number := v_line_number + 2;
    end if;
  end loop;

  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number, description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_return.receivable_account_id,
    v_line_number, 'Customer credit - ' || v_return.return_number, 0, v_return.total_amount, v_return.customer_id
  );

  update public.sales_returns
  set status = 'posted', posted_journal_entry_id = v_journal_id,
      posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_sales_return_id;

  if exists (
    select 1 from public.sales_items si
    where si.organization_id = p_organization_id and si.sales_id = v_sales.id
      and si.quantity > coalesce((
        select sum(sri.quantity)
        from public.sales_return_items sri
        join public.sales_returns sr on sr.organization_id = sri.organization_id and sr.id = sri.sales_return_id
        where sri.organization_id = p_organization_id and sri.sales_item_id = si.id and sr.status = 'posted'
      ),0)
  ) then
    update public.sales set status = 'partially_returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_sales.id;
  else
    update public.sales set status = 'returned', updated_at = pg_catalog.now()
    where organization_id = p_organization_id and id = v_sales.id;
  end if;
  return v_journal_id;
end;
$function$;

create or replace function public.post_confirmed_journal_entry(
  p_organization_id uuid,
  p_journal_entry_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_entry public.journal_entries%rowtype;
  v_line_count integer;
  v_debit numeric(20,4);
  v_credit numeric(20,4);
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'journal_entries.post') then
    raise exception using errcode = '42501', message = 'You are not authorized to post journal entries for this organization.';
  end if;

  select * into v_entry
  from public.journal_entries
  where organization_id = p_organization_id and id = p_journal_entry_id
  for update;
  if not found then
    raise exception using errcode = '23503', message = 'Journal entry was not found in this organization.';
  end if;
  if v_entry.entry_type <> 'manual' or v_entry.status <> 'confirmed' or v_entry.posted_at is not null then
    raise exception using errcode = '23514', message = 'Only a confirmed, unposted manual journal entry can be posted by this function.';
  end if;

  select count(*)::integer, coalesce(sum(atx.debit), 0), coalesce(sum(atx.credit), 0)
    into v_line_count, v_debit, v_credit
  from public.account_transactions atx
  where atx.organization_id = p_organization_id and atx.journal_entry_id = p_journal_entry_id;
  if v_line_count < 2 or v_debit <= 0 or v_debit <> v_credit then
    raise exception using errcode = '23514', message = 'Journal entry must have at least two lines and balanced debits and credits.';
  end if;

  if exists (
    select 1
    from public.account_transactions atx
    join public.accounts a on a.organization_id = atx.organization_id and a.id = atx.account_id
    where atx.organization_id = p_organization_id
      and atx.journal_entry_id = p_journal_entry_id
      and (not a.is_active or not a.is_postable)
  ) then
    raise exception using errcode = '23514', message = 'All journal accounts must be active and postable before posting.';
  end if;

  if exists (
    select 1
    from public.account_transactions atx
    left join public.contacts c
      on c.organization_id = atx.organization_id and c.id = atx.contact_id
    where atx.organization_id = p_organization_id
      and atx.journal_entry_id = p_journal_entry_id
      and atx.contact_id is not null
      and (c.id is null or not c.is_active)
  ) then
    raise exception using errcode = '23514', message = 'Every journal contact must be active and belong to this organization.';
  end if;

  update public.journal_entries
  set status = 'posted', posted_at = pg_catalog.now(), posted_by = v_user_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_journal_entry_id;

  return p_journal_entry_id;
end;
$$;

create or replace function public.save_draft_transaction_document(
  p_organization_id uuid,
  p_document_type text,
  p_header jsonb,
  p_items jsonb default null,
  p_document_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_table text;
  v_child_table text;
  v_parent_column text;
  v_permission text;
  v_allowed_header text[];
  v_child_columns text[];
  v_document_id uuid := coalesce(p_document_id, pg_catalog.gen_random_uuid());
  v_status text;
  v_key text;
  v_columns text;
  v_values text;
  v_set_clause text;
  v_child_column_list text;
  v_child_value_list text;
  v_sql text;
begin
  if v_user_id is null or not public.is_active_org_member(p_organization_id) then
    raise exception using errcode = '42501', message = 'An authenticated active organization member is required.';
  end if;
  if p_header is null or pg_catalog.jsonb_typeof(p_header) <> 'object'
     or (p_items is not null and pg_catalog.jsonb_typeof(p_items) <> 'array') then
    raise exception using errcode = '22023', message = 'Document header must be a JSON object and items must be a JSON array.';
  end if;

  case p_document_type
    when 'purchase' then
      v_table := 'purchase'; v_child_table := 'purchase_items'; v_parent_column := 'purchase_id';
      v_permission := 'purchases.create';
      v_allowed_header := array['invoice_id','supplier_id','invoice_date','subtotal','discount_amount','total_amount','payable_account_id'];
      v_child_columns := array['line_number','product_id','quantity','unit_cost','line_total'];
    when 'sales' then
      v_table := 'sales'; v_child_table := 'sales_items'; v_parent_column := 'sales_id';
      v_permission := 'sales.create';
      v_allowed_header := array['invoice_id','customer_id','invoice_date','subtotal','discount_amount','total_amount','receivable_account_id'];
      v_child_columns := array['line_number','product_id','quantity','unit_price','line_total'];
    when 'expense' then
      v_table := 'expenses'; v_permission := 'expenses.manage';
      v_allowed_header := array['expense_number','expense_category_id','contact_id','payable_account_id','expense_date','amount','description'];
      v_child_columns := array[]::text[];
    when 'payment' then
      v_table := 'payments';
      v_permission := 'payments.manage';
      v_allowed_header := array['payment_number','payment_type','contact_id','payment_date','amount','account_id','settlement_account_id','description'];
      v_child_columns := array[]::text[];
    when 'purchase_return' then
      v_table := 'purchase_returns'; v_child_table := 'purchase_return_items'; v_parent_column := 'purchase_return_id';
      v_permission := 'purchases.returns.create';
      v_allowed_header := array['return_number','purchase_id','supplier_id','return_date','subtotal','discount_amount','total_amount','payable_account_id','purchase_return_variance_account_id'];
      v_child_columns := array['line_number','purchase_item_id','product_id','quantity','unit_cost','line_total'];
    when 'sales_return' then
      v_table := 'sales_returns'; v_child_table := 'sales_return_items'; v_parent_column := 'sales_return_id';
      v_permission := 'sales.returns.create';
      v_allowed_header := array['return_number','sales_id','customer_id','return_date','subtotal','discount_amount','total_amount','receivable_account_id'];
      v_child_columns := array['line_number','sales_item_id','product_id','quantity','unit_price','line_total'];
    when 'journal_entry' then
      v_table := 'journal_entries'; v_child_table := 'account_transactions'; v_parent_column := 'journal_entry_id';
      v_permission := 'journal_entries.create';
      v_allowed_header := array['entry_number','entry_date','entry_type','reference_type','reference_id','description'];
      v_child_columns := array['account_id','line_number','description','debit','credit','contact_id'];
    else
      raise exception using errcode = '22023', message = 'Unsupported transaction document type.';
  end case;

  if not public.has_org_permission(p_organization_id, v_permission) then
    raise exception using errcode = '42501', message = 'You do not have permission to create or update this draft document.';
  end if;

  if p_document_type = 'journal_entry' then
    if p_header ? 'entry_type' and p_header->>'entry_type' <> 'manual' then
      raise exception using errcode = '22023', message = 'User-created draft journal entries must have entry_type manual.';
    end if;
    p_header := p_header || pg_catalog.jsonb_build_object('entry_type', 'manual');
  end if;

  for v_key in select pg_catalog.jsonb_object_keys(p_header)
  loop
    if not (v_key = any(v_allowed_header)) then
      raise exception using errcode = '22023', message = pg_catalog.format('Header field %s is not editable through this draft function.', v_key);
    end if;
  end loop;

  if p_document_id is null then
    if pg_catalog.jsonb_object_length(p_header) = 0 then
      raise exception using errcode = '22023', message = 'A new draft requires header fields.';
    end if;
    select
      pg_catalog.string_agg(pg_catalog.format('%I', k), ', ' order by k),
      pg_catalog.string_agg(
        pg_catalog.format('(pg_catalog.jsonb_populate_record(null::public.%I, $3)).%I', v_table, k),
        ', ' order by k
      )
    into v_columns, v_values
    from pg_catalog.jsonb_object_keys(p_header) as keys(k);

    v_sql := pg_catalog.format(
      'insert into public.%I (id, organization_id, created_by, %s) values ($1, $2, $4, %s)',
      v_table, v_columns, v_values
    );
    execute v_sql using v_document_id, p_organization_id, p_header, v_user_id;
  else
    execute pg_catalog.format(
      'select status from public.%I where organization_id = $1 and id = $2 for update', v_table
    ) into v_status using p_organization_id, v_document_id;
    if v_status is null then
      raise exception using errcode = '23503', message = 'Draft document was not found in this organization.';
    end if;
    if v_status <> 'draft' then
      raise exception using errcode = '23514', message = 'Only draft documents can be edited.';
    end if;

    select pg_catalog.string_agg(
      pg_catalog.format('%I = (pg_catalog.jsonb_populate_record(null::public.%I, $3)).%I', k, v_table, k),
      ', ' order by k
    )
    into v_set_clause
    from pg_catalog.jsonb_object_keys(p_header) as keys(k);

    if v_set_clause is null then
      v_set_clause := 'updated_at = pg_catalog.now()';
    else
      v_set_clause := v_set_clause || ', updated_at = pg_catalog.now()';
    end if;
    execute pg_catalog.format(
      'update public.%I set %s where organization_id = $1 and id = $2 and status = ''draft''',
      v_table, v_set_clause
    ) using p_organization_id, v_document_id, p_header;
  end if;

  if v_child_table is null then
    if p_items is not null and pg_catalog.jsonb_array_length(p_items) > 0 then
      raise exception using errcode = '22023', message = 'This document type does not accept line items.';
    end if;
  elsif p_items is not null then
    execute pg_catalog.format(
      'delete from public.%I where organization_id = $1 and %I = $2',
      v_child_table, v_parent_column
    ) using p_organization_id, v_document_id;

    if pg_catalog.jsonb_array_length(p_items) > 0 then
      select
        pg_catalog.string_agg(pg_catalog.format('%I', c), ', ' order by ord),
        pg_catalog.string_agg(pg_catalog.format('x.%I', c), ', ' order by ord)
      into v_child_column_list, v_child_value_list
      from pg_catalog.unnest(v_child_columns) with ordinality as cols(c, ord);

      v_sql := pg_catalog.format(
        'insert into public.%I (id, organization_id, %I, %s) ' ||
        'select pg_catalog.gen_random_uuid(), $1, $2, %s ' ||
        'from pg_catalog.jsonb_populate_recordset(null::public.%I, $3) as x',
        v_child_table, v_parent_column, v_child_column_list, v_child_value_list, v_child_table
      );
      execute v_sql using p_organization_id, v_document_id, p_items;
    end if;
  end if;

  return v_document_id;
end;
$function$;

REVOKE ALL ON FUNCTION public.post_manual_journal_entry(uuid, text, date, text, jsonb)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.post_purchase(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_purchase(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.post_opening_balances(uuid, date, jsonb, jsonb, jsonb, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_opening_balances(uuid, date, jsonb, jsonb, jsonb, text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.post_contact_payment(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_contact_payment(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.post_sales(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_sales(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.reverse_journal_entry(uuid, uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_journal_entry(uuid, uuid, date, text) TO authenticated;

REVOKE ALL ON FUNCTION public.post_expense(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_expense(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.post_purchase_return(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_purchase_return(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.post_sales_return(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_sales_return(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.post_confirmed_journal_entry(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_confirmed_journal_entry(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.save_draft_transaction_document(uuid, text, jsonb, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_draft_transaction_document(uuid, text, jsonb, jsonb, uuid) TO authenticated;


COMMIT;
