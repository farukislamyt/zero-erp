-- Zero ERP: one-time opening balances using existing ledger and inventory tables only.
-- No new tables are introduced.
-- Depends on migrations 001-005.

begin;

-- A single organization-level opening journal is allowed. Corrections after posting
-- must use the normal reversal/adjustment workflow, not a second opening post.
create unique index journal_entries_one_org_opening_balance_uq
  on public.journal_entries (organization_id)
  where entry_type = 'opening_balance'
    and reference_type = 'organization_opening_balance';

-- Add a dedicated permission and grant it to existing Administrator system roles.
insert into public.permissions (permission_key, name, description, module)
values (
  'opening_balances.post',
  'Post opening balances',
  'Post an organization''s one-time general ledger, party, and inventory opening balances.',
  'accounting'
)
on conflict (permission_key) do update
set name = excluded.name,
    description = excluded.description,
    module = excluded.module;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.is_system_role
  and r.name = 'Administrator'
  and p.permission_key = 'opening_balances.post'
on conflict (role_id, permission_id) do nothing;

create or replace function public.post_opening_balances(
  p_organization_id uuid,
  p_accounting_period_id uuid,
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
  v_period_status text;
  v_period_start date;
  v_period_end date;
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
    select 1
    from public.journal_entries je
    where je.organization_id = p_organization_id
      and je.entry_type = 'opening_balance'
      and je.reference_type = 'organization_opening_balance'
  ) then
    raise exception using errcode = '23514',
      message = 'Opening balances have already been posted for this organization. Use a reversal or adjustment for corrections.';
  end if;

  -- Lock the accounting period so a concurrent close cannot race this posting.
  select ap.status, ap.start_date, ap.end_date
    into v_period_status, v_period_start, v_period_end
  from public.accounting_periods ap
  where ap.organization_id = p_organization_id
    and ap.id = p_accounting_period_id
  for update;

  if not found then
    raise exception using errcode = '23503',
      message = 'Accounting period does not exist in this organization.';
  end if;

  if v_period_status <> 'open' then
    raise exception using errcode = '23514',
      message = 'Opening balances can only be posted to an open accounting period.';
  end if;

  if p_entry_date < v_period_start or p_entry_date > v_period_end then
    raise exception using errcode = '23514',
      message = 'Opening balance date must fall within the selected accounting period.';
  end if;

  -- Validate ordinary GL lines. Control accounts are populated from their
  -- corresponding party/inventory details to avoid double-counting.
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
       or a.is_control_account
  ) then
    raise exception using errcode = '23503',
      message = 'Ordinary GL lines must reference active, postable, non-control accounts in this organization.';
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
    organization_id, entry_number, accounting_period_id, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, created_by
  )
  values (
    p_organization_id, v_entry_number, p_accounting_period_id, p_entry_date,
    'opening_balance', 'posted', 'organization_opening_balance',
    p_organization_id, nullif(pg_catalog.btrim(coalesce(p_description, '')), ''),
    pg_catalog.now(), v_user_id
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

revoke all on function public.post_opening_balances(uuid, uuid, date, jsonb, jsonb, jsonb, text)
  from public, anon;
grant execute on function public.post_opening_balances(uuid, uuid, date, jsonb, jsonb, jsonb, text)
  to authenticated;

commit;
