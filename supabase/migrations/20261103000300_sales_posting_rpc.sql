-- Zero ERP: atomic sales posting with contact-wise receivables, revenue, COGS and stock effects.
-- Revenue discounts are allocated proportionally; the final line receives rounding residue.
-- COGS is calculated server-side from the locked weighted-average inventory balance.

begin;

create unique index if not exists journal_entries_sales_reference_uq
  on public.journal_entries (organization_id, reference_type, reference_id)
  where entry_type = 'sale' and reference_type = 'sale' and reference_id is not null;

create index if not exists account_transactions_org_account_contact_idx
  on public.account_transactions (organization_id, account_id, contact_id)
  where contact_id is not null;

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
  v_period_id uuid;
  v_period_status text;
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
  if v_sales.status not in ('draft', 'approved') or v_sales.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only an unposted draft or approved sales invoice can be posted.';
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

  select ap.id, ap.status into v_period_id, v_period_status
  from public.accounting_periods ap
  where ap.organization_id = p_organization_id
    and v_sales.invoice_date between ap.start_date and ap.end_date
  order by ap.start_date desc
  limit 1
  for update;

  if not found then
    raise exception using errcode = '23503', message = 'No accounting period covers the sales invoice date.';
  end if;
  if v_period_status <> 'open' then
    raise exception using errcode = '23514', message = 'Sales can only be posted to an open accounting period.';
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
    organization_id, entry_number, accounting_period_id, entry_date,
    entry_type, status, reference_type, reference_id, description, posted_at, created_by
  )
  values (
    p_organization_id,
    'SAL-' || pg_catalog.replace(p_sales_id::text, '-', ''),
    v_period_id, v_sales.invoice_date, 'sale', 'posted',
    'sale', p_sales_id, 'Sales invoice ' || v_sales.invoice_id,
    pg_catalog.now(), v_user_id
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

    v_line_cost := round(v_line.quantity * v_average_cost, 4);
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
        p_organization_id, v_journal_id, v_line.sales_account_id, 1,
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
        (p_organization_id, v_journal_id, v_line.cogs_account_id, 100000 + v_line.line_number,
         'Cost of goods sold - ' || v_sales.invoice_id, v_line_cost, 0, null),
        (p_organization_id, v_journal_id, v_line.inventory_account_id, 200000 + v_line.line_number,
         'Inventory issued - ' || v_sales.invoice_id, 0, v_line_cost, null);
    end if;
  end loop;

  -- Receivable debit is the single contact-tagged customer balance line.
  insert into public.account_transactions (
    organization_id, journal_entry_id, account_id, line_number,
    description, debit, credit, contact_id
  )
  values (
    p_organization_id, v_journal_id, v_sales.receivable_account_id,
    999999, 'Accounts receivable - ' || v_sales.invoice_id,
    v_sales.total_amount, 0, v_sales.customer_id
  );

  update public.sales
  set status = 'posted', posted_journal_entry_id = v_journal_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_sales_id;

  return v_journal_id;
end;
$$;

revoke all on function public.post_sales(uuid, uuid) from public, anon;
grant execute on function public.post_sales(uuid, uuid) to authenticated;

commit;
