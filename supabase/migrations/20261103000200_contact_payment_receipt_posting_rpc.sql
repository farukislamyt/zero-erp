-- Zero ERP: contact-wise receipt/payment posting against existing party control ledgers.
-- No new tables. Opening balances and subsequent activity share account_transactions.

begin;

create unique index journal_entries_payment_reference_uq
  on public.journal_entries (organization_id, reference_type, reference_id)
  where entry_type = 'payment'
    and reference_type = 'payment'
    and reference_id is not null;

create index account_transactions_party_balance_idx
  on public.account_transactions (organization_id, account_id, contact_id)
  where contact_id is not null;

create or replace function public.post_contact_payment(
  p_organization_id uuid,
  p_payment_id uuid,
  p_accounting_period_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_payment public.payments%rowtype;
  v_period_status text;
  v_period_start date;
  v_period_end date;
  v_cash_account public.accounts%rowtype;
  v_control_account public.accounts%rowtype;
  v_outstanding numeric(20,4);
  v_journal_entry_id uuid;
  v_entry_number text;
begin
  v_user_id := (select auth.uid());

  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'Authentication is required to post a payment or receipt.';
  end if;

  if not public.is_active_org_member(p_organization_id)
     or not public.has_org_permission(p_organization_id, 'payments.post') then
    raise exception using errcode = '42501',
      message = 'You are not authorized to post payments or receipts for this organization.';
  end if;

  -- Lock the payment first. A second concurrent call will see the posted status.
  select *
    into v_payment
  from public.payments p
  where p.organization_id = p_organization_id
    and p.id = p_payment_id
  for update;

  if not found then
    raise exception using errcode = '23503',
      message = 'Payment or receipt was not found in this organization.';
  end if;

  if v_payment.status = 'posted' then
    raise exception using errcode = '23514',
      message = 'This payment or receipt has already been posted.';
  end if;

  if v_payment.status not in ('draft', 'approved') then
    raise exception using errcode = '23514',
      message = 'Only draft or approved payments and receipts can be posted.';
  end if;

  if v_payment.payment_type not in ('receipt', 'payment') then
    raise exception using errcode = '22023',
      message = 'This RPC supports customer receipts and supplier payments only. Transfers and refunds require separate posting rules.';
  end if;

  if v_payment.contact_id is null or v_payment.settlement_account_id is null then
    raise exception using errcode = '22023',
      message = 'A customer/supplier contact and its receivable/payable control account are required.';
  end if;

  -- The cash/bank account receives or pays the funds.
  select *
    into v_cash_account
  from public.accounts a
  where a.organization_id = p_organization_id
    and a.id = v_payment.account_id;

  if not found
     or not v_cash_account.is_active
     or not v_cash_account.is_postable
     or v_cash_account.account_type <> 'asset' then
    raise exception using errcode = '23503',
      message = 'The payment account must be an active, postable cash/bank asset account in this organization.';
  end if;

  -- settlement_account_id is the party control account:
  -- receipt -> Accounts Receivable; payment -> Accounts Payable.
  select *
    into v_control_account
  from public.accounts a
  where a.organization_id = p_organization_id
    and a.id = v_payment.settlement_account_id;

  if not found
     or not v_control_account.is_active
     or not v_control_account.is_postable
     or not v_control_account.is_control_account
     or (v_payment.payment_type = 'receipt' and v_control_account.account_type <> 'asset')
     or (v_payment.payment_type = 'payment' and v_control_account.account_type <> 'liability') then
    raise exception using errcode = '23503',
      message = 'Receipt requires an active receivable asset control account; supplier payment requires an active payable liability control account.';
  end if;

  if v_payment.account_id = v_payment.settlement_account_id then
    raise exception using errcode = '23514',
      message = 'Cash/bank account and party control account must be different.';
  end if;

  -- Serialize concurrent receipts/payments for this party before checking
  -- its current outstanding, preventing two payments from spending the same balance.
  perform 1
  from public.contacts c
  where c.organization_id = p_organization_id
    and c.id = v_payment.contact_id
    and c.is_active
  for update;

  if not found then
    raise exception using errcode = '23503',
      message = 'The customer/supplier contact is missing or inactive.';
  end if;

  -- Lock and validate the accounting period.
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
      message = 'Payments and receipts can only be posted to an open accounting period.';
  end if;

  if v_payment.payment_date < v_period_start or v_payment.payment_date > v_period_end then
    raise exception using errcode = '23514',
      message = 'Payment date must fall within the selected accounting period.';
  end if;

  -- Outstanding is calculated from the same contact + control account ledger
  -- used by opening balances, sales and purchases. No invoice allocation is needed.
  select coalesce(
    sum(case
      when v_payment.payment_type = 'receipt' then atx.debit - atx.credit
      else atx.credit - atx.debit
    end),
    0
  )
  into v_outstanding
  from public.account_transactions atx
  where atx.organization_id = p_organization_id
    and atx.account_id = v_payment.settlement_account_id
    and atx.contact_id = v_payment.contact_id;

  if v_outstanding < v_payment.amount then
    raise exception using errcode = '23514',
      message = pg_catalog.format(
        'Payment amount exceeds the current party outstanding. Outstanding: %s; payment: %s.',
        v_outstanding, v_payment.amount
      );
  end if;

  v_entry_number := 'PMT-' || pg_catalog.replace(v_payment.id::text, '-', '');

  insert into public.journal_entries (
    organization_id, entry_number, accounting_period_id, entry_date,
    entry_type, status, reference_type, reference_id, description,
    posted_at, created_by
  )
  values (
    p_organization_id,
    v_entry_number,
    p_accounting_period_id,
    v_payment.payment_date,
    'payment',
    'posted',
    'payment',
    v_payment.id,
    coalesce(
      nullif(pg_catalog.btrim(v_payment.description), ''),
      case when v_payment.payment_type = 'receipt'
        then 'Customer receipt ' || v_payment.payment_number
        else 'Supplier payment ' || v_payment.payment_number
      end
    ),
    pg_catalog.now(),
    v_user_id
  )
  returning id into v_journal_entry_id;

  if v_payment.payment_type = 'receipt' then
    -- Dr Cash/Bank; Cr Accounts Receivable (same customer contact).
    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number,
      description, debit, credit, contact_id
    )
    values
      (
        p_organization_id, v_journal_entry_id, v_payment.account_id, 1,
        'Receipt ' || v_payment.payment_number, v_payment.amount, 0, null
      ),
      (
        p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 2,
        'Receivable settled - ' || v_payment.payment_number, 0, v_payment.amount,
        v_payment.contact_id
      );
  else
    -- Dr Accounts Payable (same supplier contact); Cr Cash/Bank.
    insert into public.account_transactions (
      organization_id, journal_entry_id, account_id, line_number,
      description, debit, credit, contact_id
    )
    values
      (
        p_organization_id, v_journal_entry_id, v_payment.settlement_account_id, 1,
        'Payable settled - ' || v_payment.payment_number, v_payment.amount, 0,
        v_payment.contact_id
      ),
      (
        p_organization_id, v_journal_entry_id, v_payment.account_id, 2,
        'Payment ' || v_payment.payment_number, 0, v_payment.amount, null
      );
  end if;

  update public.payments
  set status = 'posted',
      posted_journal_entry_id = v_journal_entry_id,
      updated_at = pg_catalog.now()
  where organization_id = p_organization_id
    and id = p_payment_id;

  return v_journal_entry_id;
end;
$$;

revoke all on function public.post_contact_payment(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.post_contact_payment(uuid, uuid, uuid)
  to authenticated;

commit;
