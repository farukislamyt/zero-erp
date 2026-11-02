-- Zero ERP: controlled purchase posting with inventory valuation and ledger effects.
-- Discounts are allocated proportionally to line values; rounding residue goes to the
-- final line so inventory valuation and accounts payable reconcile exactly.

begin;

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
  v_period_id uuid;
  v_period_status text;
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
  if v_purchase.status not in ('draft', 'approved') or v_purchase.posted_journal_entry_id is not null then
    raise exception using errcode = '23514', message = 'Only an unposted draft or approved purchase can be posted.';
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

  select ap.id, ap.status into v_period_id, v_period_status
  from public.accounting_periods ap
  where ap.organization_id = p_organization_id
    and v_purchase.invoice_date between ap.start_date and ap.end_date
  order by ap.start_date desc
  limit 1
  for update;

  if not found then
    raise exception using errcode = '23503', message = 'No accounting period covers the purchase invoice date.';
  end if;
  if v_period_status <> 'open' then
    raise exception using errcode = '23514', message = 'Purchase can only be posted to an open accounting period.';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.organization_id = p_organization_id
      and a.id = v_purchase.payable_account_id
      and a.is_active and a.is_postable and a.account_type = 'liability'
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
    organization_id, entry_number, accounting_period_id, entry_date,
    entry_type, status, reference_type, reference_id, description, posted_at, created_by
  )
  values (
    p_organization_id,
    'PUR-' || pg_catalog.replace(p_purchase_id::text, '-', ''),
    v_period_id, v_purchase.invoice_date, 'purchase', 'posted',
    'purchase', p_purchase_id, 'Purchase invoice ' || v_purchase.invoice_id,
    pg_catalog.now(), v_user_id
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
  set status = 'posted', posted_journal_entry_id = v_journal_id, updated_at = pg_catalog.now()
  where organization_id = p_organization_id and id = p_purchase_id;

  return v_journal_id;
end;
$$;

revoke all on function public.post_purchase(uuid, uuid) from public, anon;
grant execute on function public.post_purchase(uuid, uuid) to authenticated;

commit;
