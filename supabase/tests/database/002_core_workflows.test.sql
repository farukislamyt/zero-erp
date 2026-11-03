begin;
create extension if not exists pgtap with schema extensions;
select plan(28);

-- Deterministic, disposable Auth fixture. No external Supabase project or secret is used.
insert into auth.users(
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
(
  '20000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','workflow-admin@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
),
(
  '20000000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','workflow-limited@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
);

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"20000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select pg_catalog.set_config(
  'test.org_id',
  public.create_organization_with_admin('Workflow Integration Test','BDT','Asia/Dhaka')::text,
  true
);
reset role;

select is((select count(*)::integer from public.accounts where organization_id=current_setting('test.org_id')::uuid),22,
  'company bootstrap seeds the expected chart of accounts');

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"20000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);

select set_config('test.cash_id', public.save_master_data(
  current_setting('test.org_id')::uuid,'account',
  jsonb_build_object(
    'account_code','1111','account_name','Test Cash','account_type','asset',
    'parent_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1100'),
    'normal_balance','debit','is_control_account',false,'is_postable',true,'is_active',true
  )
)::text,true);
select set_config('test.bank_id', public.save_master_data(
  current_setting('test.org_id')::uuid,'account',
  jsonb_build_object(
    'account_code','1112','account_name','Test Bank','account_type','asset',
    'parent_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1100'),
    'normal_balance','debit','is_control_account',false,'is_postable',true,'is_active',true
  )
)::text,true);
select set_config('test.contact_id', public.save_master_data(
  current_setting('test.org_id')::uuid,'contact',
  '{"contact_number":"C-WF-001","name":"Workflow Test Customer","phone":"+8801000000001","email":"customer@example.invalid"}'::jsonb
)::text,true);
select set_config('test.unit_id', public.save_master_data(
  current_setting('test.org_id')::uuid,'unit',
  '{"name":"Workflow Test Unit"}'::jsonb
)::text,true);
select set_config('test.product_id', public.save_master_data(
  current_setting('test.org_id')::uuid,'product',
  jsonb_build_object(
    'product_code','P-WF-001','name','Workflow Test Product',
    'unit_id',current_setting('test.unit_id')::uuid,
    'inventory_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1130'),
    'sales_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='4100'),
    'cogs_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='5100'),
    'is_active',true
  )
)::text,true);

select ok(exists(select 1 from public.accounts where id=current_setting('test.cash_id')::uuid and organization_id=current_setting('test.org_id')::uuid and is_postable),
  'master-data RPC creates a postable same-tenant Cash account');
select ok(exists(select 1 from public.accounts where id=current_setting('test.bank_id')::uuid and organization_id=current_setting('test.org_id')::uuid and is_postable),
  'master-data RPC creates a postable same-tenant Bank account');
select ok(exists(select 1 from public.contacts where id=current_setting('test.contact_id')::uuid and organization_id=current_setting('test.org_id')::uuid),
  'master-data RPC creates a tenant-scoped Contact');
select ok(exists(select 1 from public.units_of_measure where id=current_setting('test.unit_id')::uuid and organization_id=current_setting('test.org_id')::uuid),
  'master-data RPC creates a Unit');
select ok(exists(select 1 from public.products where id=current_setting('test.product_id')::uuid and organization_id=current_setting('test.org_id')::uuid),
  'master-data RPC creates a Product with valid account mappings');

select set_config('test.opening_journal_id',public.post_opening_balances(
  current_setting('test.org_id')::uuid,
  date '2026-01-01',
  jsonb_build_array(
    jsonb_build_object('account_id',current_setting('test.cash_id')::uuid,'debit',50000,'credit',0,'description','Opening cash'),
    jsonb_build_object('account_id',current_setting('test.bank_id')::uuid,'debit',100000,'credit',0,'description','Opening bank'),
    jsonb_build_object('account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='3300'),'debit',0,'credit',151000,'description','Opening equity')
  ),
  '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('product_id',current_setting('test.product_id')::uuid,'quantity',10,'unit_cost',100)),
  'Workflow opening balances'
)::text,true);

select is((select status from public.journal_entries where id=current_setting('test.opening_journal_id')::uuid),'posted',
  'opening balance posting creates a posted opening journal');
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),10::numeric,
  'opening inventory initializes the product quantity');
select is((select round(sum(atx.debit-atx.credit),2) from public.account_transactions atx join public.journal_entries je on je.id=atx.journal_entry_id and je.organization_id=atx.organization_id where atx.organization_id=current_setting('test.org_id')::uuid and atx.account_id=current_setting('test.cash_id')::uuid and je.status in ('posted','reversed')),50000::numeric,
  'opening Cash ledger balance is correct');
select is((select round(sum(atx.debit-atx.credit),2) from public.account_transactions atx join public.journal_entries je on je.id=atx.journal_entry_id and je.organization_id=atx.organization_id where atx.organization_id=current_setting('test.org_id')::uuid and atx.account_id=current_setting('test.bank_id')::uuid and je.status in ('posted','reversed')),100000::numeric,
  'opening Bank ledger balance is correct');

select set_config('test.transfer_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'payment',
  jsonb_build_object(
    'payment_number','PAY-WF-TRANSFER-001','payment_type','transfer','payment_date','2026-01-02',
    'amount',20000,'account_id',current_setting('test.bank_id')::uuid,
    'settlement_account_id',current_setting('test.cash_id')::uuid,
    'description','Bank withdrawal to cash'
  )
)::text,true);
select lives_ok(
  format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',
    current_setting('test.org_id'), 'payment', current_setting('test.transfer_id')),
  'Cash-Bank transfer Draft passes confirmation validation'
);
select is((select status from public.payments where id=current_setting('test.transfer_id')::uuid),'confirmed',
  'confirmed transfer status is persisted');
select set_config('test.transfer_journal_id',public.post_contact_payment(
  current_setting('test.org_id')::uuid,current_setting('test.transfer_id')::uuid
)::text,true);
select is((select status from public.payments where id=current_setting('test.transfer_id')::uuid),'posted',
  'Cash-Bank transfer is posted exactly through payment posting RPC');
select is((select count(*)::integer from public.account_transactions where organization_id=current_setting('test.org_id')::uuid and journal_entry_id=current_setting('test.transfer_journal_id')::uuid),2,
  'Cash-Bank transfer creates exactly two ledger lines');
select is((select debit from public.account_transactions where organization_id=current_setting('test.org_id')::uuid and journal_entry_id=current_setting('test.transfer_journal_id')::uuid and account_id=current_setting('test.cash_id')::uuid),20000::numeric,
  'Cash-Bank transfer debits destination Cash');
select is((select credit from public.account_transactions where organization_id=current_setting('test.org_id')::uuid and journal_entry_id=current_setting('test.transfer_journal_id')::uuid and account_id=current_setting('test.bank_id')::uuid),20000::numeric,
  'Cash-Bank transfer credits source Bank');
select is((select round(sum(atx.debit-atx.credit),2) from public.account_transactions atx join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id where atx.organization_id=current_setting('test.org_id')::uuid and atx.account_id=current_setting('test.cash_id')::uuid and je.status in ('posted','reversed')),70000::numeric,
  'Cash balance increases from 50,000 to 70,000 after withdrawal');
select is((select round(sum(atx.debit-atx.credit),2) from public.account_transactions atx join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id where atx.organization_id=current_setting('test.org_id')::uuid and atx.account_id=current_setting('test.bank_id')::uuid and je.status in ('posted','reversed')),80000::numeric,
  'Bank balance decreases from 100,000 to 80,000 after withdrawal');
select is((select round(sum(atx.debit-atx.credit),2) from public.account_transactions atx join public.journal_entries je on je.organization_id=atx.organization_id and je.id=atx.journal_entry_id where atx.organization_id=current_setting('test.org_id')::uuid and atx.account_id in (current_setting('test.cash_id')::uuid,current_setting('test.bank_id')::uuid) and je.status in ('posted','reversed')),150000::numeric,
  'Cash plus Bank total remains unchanged after internal transfer');
select throws_ok(
  format('select public.post_contact_payment(%L::uuid,%L::uuid)',current_setting('test.org_id'),current_setting('test.transfer_id')),
  '23514',
  'duplicate posting of a transfer is rejected'
);
select throws_ok(
  format('select public.post_opening_balances(%L::uuid,date %L,%L::jsonb,%L::jsonb,%L::jsonb)',
    current_setting('test.org_id'),'2026-01-03','[]','[]','[]'),
  '23514',
  'opening balances cannot be posted a second time'
);

select set_config('test.invalid_transfer_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'payment',
  jsonb_build_object(
    'payment_number','PAY-WF-TRANSFER-INVALID','payment_type','transfer','payment_date','2026-01-03',
    'amount',1000,'account_id',current_setting('test.bank_id')::uuid,
    'settlement_account_id',current_setting('test.bank_id')::uuid,
    'description','Invalid same-account transfer'
  )
)::text,true);
select throws_ok(
  format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',
    current_setting('test.org_id'),'payment',current_setting('test.invalid_transfer_id')),
  '23514',
  'transfer from an account to itself is rejected'
);

select set_config('test.limited_role_id',public.create_custom_role(
  current_setting('test.org_id')::uuid,'Workflow Read Only',array['reports.read','contacts.read']
)::text,true);
select lives_ok(
  format('select public.add_organization_user_by_email(%L::uuid,%L,%L::uuid)',
    current_setting('test.org_id'),'workflow-limited@example.invalid',current_setting('test.limited_role_id')),
  'Administrator can add an existing verified Auth user with a least-privilege role'
);
select is((select count(*)::integer from public.organization_users where organization_id=current_setting('test.org_id')::uuid and user_id='20000000-0000-4000-8000-000000000002' and is_active),1,
  'new user membership is active in the intended tenant');

select pg_catalog.set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000002',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"20000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
select ok(public.is_active_org_member(current_setting('test.org_id')::uuid),
  'limited member can establish active membership in this tenant');
select ok(public.has_org_permission(current_setting('test.org_id')::uuid,'reports.read'),
  'limited member receives the explicitly granted report permission');
select ok(not public.has_org_permission(current_setting('test.org_id')::uuid,'accounts.manage'),
  'limited member does not inherit account-management permission');
select throws_ok(
  format('select public.save_master_data(%L::uuid,%L,%L::jsonb)',
    current_setting('test.org_id'),'account','{"account_code":"1199","account_name":"Forbidden","account_type":"asset","normal_balance":"debit"}'),
  '42501',
  'limited member cannot create chart-of-account records'
);

select * from finish();
rollback;
