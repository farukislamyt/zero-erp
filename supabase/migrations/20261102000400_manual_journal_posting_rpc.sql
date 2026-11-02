-- Zero ERP: atomic balanced manual journal posting RPC
-- Depends on core foundation, transaction schema, and RBAC bootstrap migrations.
-- Browser clients cannot write ledger tables directly; this function is the controlled posting boundary.

begin;

create or replace function public.post_manual_journal_entry(
  p_organization_id uuid,
  p_entry_number text,
  p_accounting_period_id uuid,
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
  v_period_status text;
  v_period_start date;
  v_period_end date;
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

  -- Lock the period row to serialize posting against a concurrent period close.
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
      message = 'Journal entries can only be posted to an open accounting period.';
  end if;

  if p_entry_date < v_period_start or p_entry_date > v_period_end then
    raise exception using errcode = '23514',
      message = 'Entry date must fall within the selected accounting period.';
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
    accounting_period_id,
    entry_date,
    entry_type,
    status,
    description,
    posted_at,
    created_by
  )
  values (
    p_organization_id,
    pg_catalog.btrim(p_entry_number),
    p_accounting_period_id,
    p_entry_date,
    'manual',
    'posted',
    nullif(pg_catalog.btrim(coalesce(p_description, '')), ''),
    pg_catalog.now(),
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

revoke all on function public.post_manual_journal_entry(uuid, text, uuid, date, text, jsonb)
  from public, anon;
grant execute on function public.post_manual_journal_entry(uuid, text, uuid, date, text, jsonb)
  to authenticated;

commit;
