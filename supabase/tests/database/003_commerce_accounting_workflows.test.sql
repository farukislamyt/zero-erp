begin;
create extension if not exists pgtap with schema extensions;
select plan(35);

insert into auth.users(
  id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values (
  '30000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','commerce-admin@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
);

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"30000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select pg_catalog.set_config('test.org_id',public.create_organization_with_admin('Commerce Workflow Test','BDT','Asia/Dhaka')::text,true);

select set_config('test.supplier_id',public.save_master_data(
  current_setting('test.org_id')::uuid,'contact',
  '{"contact_number":"SUP-CI-001","name":"CI Supplier"}'::jsonb
)::text,true);
select set_config('test.customer_id',public.save_master_data(
  current_setting('test.org_id')::uuid,'contact',
  '{"contact_number":"CUS-CI-001","name":"CI Customer"}'::jsonb
)::text,true);
select set_config('test.unit_id',public.save_master_data(
  current_setting('test.org_id')::uuid,'unit','{"name":"CI Piece"}'::jsonb
)::text,true);
select set_config('test.product_id',public.save_master_data(
  current_setting('test.org_id')::uuid,'product',
  jsonb_build_object('product_code','CI-COM-001','name','CI Commerce Product','unit_id',current_setting('test.unit_id')::uuid)
)::text,true);

select ok(exists(select 1 from public.contacts where id=current_setting('test.supplier_id')::uuid),'Supplier contact is created');
select ok(exists(select 1 from public.contacts where id=current_setting('test.customer_id')::uuid),'Customer contact is created');
select ok(exists(select 1 from public.products where id=current_setting('test.product_id')::uuid),'Product is created with default valid ledger mappings');

select set_config('test.opening_id',public.post_opening_balances(
  current_setting('test.org_id')::uuid,date '2026-02-01',
  jsonb_build_array(jsonb_build_object(
    'account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='3300'),
    'debit',0,'credit',1000,'description','Opening inventory equity'
  )),
  '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('product_id',current_setting('test.product_id')::uuid,'quantity',10,'unit_cost',100)),
  'Commerce opening inventory'
)::text,true);
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),10::numeric,
  'opening inventory quantity is initialized');

select set_config('test.purchase_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'purchase',
  jsonb_build_object(
    'invoice_id','PUR-CI-001','supplier_id',current_setting('test.supplier_id')::uuid,
    'invoice_date','2026-02-02','subtotal',240,'discount_amount',0,'total_amount',240,
    'payable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='2110')
  ),
  jsonb_build_array(jsonb_build_object('line_number',1,'product_id',current_setting('test.product_id')::uuid,'quantity',2,'unit_cost',120,'line_total',240))
)::text,true);
select lives_ok(format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',current_setting('test.org_id'),'purchase',current_setting('test.purchase_id')),
  'valid purchase draft confirms');
select set_config('test.purchase_journal_id',public.post_purchase(current_setting('test.org_id')::uuid,current_setting('test.purchase_id')::uuid)::text,true);
select is((select status from public.purchase where id=current_setting('test.purchase_id')::uuid),'posted',
  'purchase posts and source status is updated');
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),12::numeric,
  'purchase increases on-hand stock');
select is((select round(inventory_value,2) from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),1240::numeric,
  'purchase updates weighted inventory value');

select set_config('test.sale_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'sales',
  jsonb_build_object(
    'invoice_id','SAL-CI-001','customer_id',current_setting('test.customer_id')::uuid,
    'invoice_date','2026-02-03','subtotal',600,'discount_amount',0,'total_amount',600,
    'receivable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1120')
  ),
  jsonb_build_array(jsonb_build_object('line_number',1,'product_id',current_setting('test.product_id')::uuid,'quantity',3,'unit_price',200,'line_total',600))
)::text,true);
select lives_ok(format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',current_setting('test.org_id'),'sales',current_setting('test.sale_id')),
  'valid sales draft confirms');
select set_config('test.sale_journal_id',public.post_sales(current_setting('test.org_id')::uuid,current_setting('test.sale_id')::uuid)::text,true);
select is((select status from public.sales where id=current_setting('test.sale_id')::uuid),'posted',
  'sales invoice posts and source status is updated');
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),9::numeric,
  'sales decreases on-hand stock');
select is((select count(*)::integer from public.inventory_transactions where organization_id=current_setting('test.org_id')::uuid and reference_id=current_setting('test.sale_id')::uuid and direction='out'),1,
  'sales posting creates the expected inventory-out movement');
select is((select round(sum(debit),2) from public.account_transactions where organization_id=current_setting('test.org_id')::uuid and journal_entry_id=current_setting('test.sale_journal_id')::uuid),
  (select round(sum(credit),2) from public.account_transactions where organization_id=current_setting('test.org_id')::uuid and journal_entry_id=current_setting('test.sale_journal_id')::uuid),
  'sales journal is balanced');

select set_config('test.expense_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'expense',
  jsonb_build_object(
    'expense_number','EXP-CI-001',
    'expense_category_id',(select id from public.expense_categories where organization_id=current_setting('test.org_id')::uuid and category_code='GEN'),
    'contact_id',current_setting('test.supplier_id')::uuid,
    'payable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='2110'),
    'expense_date','2026-02-04','amount',50,'description','CI test expense'
  )
)::text,true);
select lives_ok(format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',current_setting('test.org_id'),'expense',current_setting('test.expense_id')),
  'valid expense draft confirms');
select set_config('test.expense_journal_id',public.post_expense(current_setting('test.org_id')::uuid,current_setting('test.expense_id')::uuid)::text,true);
select is((select status from public.expenses where id=current_setting('test.expense_id')::uuid),'posted',
  'expense posts and source status is updated');
select is((select count(*)::integer from public.account_transactions where organization_id=current_setting('test.org_id')::uuid and journal_entry_id=current_setting('test.expense_journal_id')::uuid),2,
  'expense posting creates a two-line ledger journal');

select set_config('test.adjustment_journal_id',public.post_inventory_adjustment(
  current_setting('test.org_id')::uuid,date '2026-02-05','CI stock increase',
  jsonb_build_array(jsonb_build_object('product_id',current_setting('test.product_id')::uuid,'direction','increase','quantity',1,'unit_cost',100))
)::text,true);
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),10::numeric,
  'inventory adjustment increase changes stock quantity');
select is((select status from public.journal_entries where id=current_setting('test.adjustment_journal_id')::uuid),'posted',
  'inventory adjustment creates a posted journal');

select set_config('test.manual_journal_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'journal_entry',
  jsonb_build_object('entry_number','JRN-CI-001','entry_date','2026-02-06','entry_type','manual','description','CI manual journal'),
  jsonb_build_array(
    jsonb_build_object('account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1110'),'line_number',1,'description','Cash debit','debit',100,'credit',0),
    jsonb_build_object('account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='3300'),'line_number',2,'description','Equity credit','debit',0,'credit',100)
  )
)::text,true);
select lives_ok(format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',current_setting('test.org_id'),'journal_entry',current_setting('test.manual_journal_id')),
  'balanced manual journal confirms');
select set_config('test.manual_journal_posted_id',public.post_confirmed_journal_entry(
  current_setting('test.org_id')::uuid,current_setting('test.manual_journal_id')::uuid
)::text,true);
select is((select status from public.journal_entries where id=current_setting('test.manual_journal_id')::uuid),'posted',
  'confirmed manual journal posts');
select set_config('test.reversal_id',public.reverse_journal_entry(
  current_setting('test.org_id')::uuid,current_setting('test.manual_journal_id')::uuid,date '2026-02-07','CI reversal test'
)::text,true);
select is((select status from public.journal_entries where id=current_setting('test.manual_journal_id')::uuid),'reversed',
  'manual journal reversal marks the original journal reversed');
select is((select count(*)::integer from public.account_transactions where organization_id=current_setting('test.org_id')::uuid and journal_entry_id=current_setting('test.reversal_id')::uuid),2,
  'manual journal reversal creates equal-and-opposite ledger lines');

select set_config('test.oversell_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'sales',
  jsonb_build_object(
    'invoice_id','SAL-CI-OVERSELL','customer_id',current_setting('test.customer_id')::uuid,
    'invoice_date','2026-02-08','subtotal',20000,'discount_amount',0,'total_amount',20000,
    'receivable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1120')
  ),
  jsonb_build_array(jsonb_build_object('line_number',1,'product_id',current_setting('test.product_id')::uuid,'quantity',100,'unit_price',200,'line_total',20000))
)::text,true);
select lives_ok(format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',current_setting('test.org_id'),'sales',current_setting('test.oversell_id')),
  'sales draft can be confirmed before stock posting validation');
select throws_ok(format('select public.post_sales(%L::uuid,%L::uuid)',current_setting('test.org_id'),current_setting('test.oversell_id')),
  '23514','sales posting rejects insufficient inventory');
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),10::numeric,
  'failed oversell leaves inventory unchanged');

select is((select coalesce(sum(movement_debit),0) from public.report_trial_balance(current_setting('test.org_id')::uuid,date '2026-02-01',date '2026-02-28')),
  (select coalesce(sum(movement_credit),0) from public.report_trial_balance(current_setting('test.org_id')::uuid,date '2026-02-01',date '2026-02-28')),
  'trial balance debits and credits reconcile for the test period');
select ok((select count(*)>0 from public.report_general_ledger(
  current_setting('test.org_id')::uuid,
  (select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1130'),
  date '2026-02-01',date '2026-02-28'
)),'general ledger returns inventory-account activity');
select ok((select count(*)>0 from public.report_profit_and_loss(current_setting('test.org_id')::uuid,date '2026-02-01',date '2026-02-28')),
  'profit and loss report returns account rows');
select ok((select count(*)>0 from public.report_balance_sheet(current_setting('test.org_id')::uuid,date '2026-02-28')),
  'balance sheet report returns account rows');
select ok((select count(*)>0 from public.report_inventory_valuation(current_setting('test.org_id')::uuid,date '2026-02-28')),
  'inventory valuation report returns product valuation');

select * from finish();
rollback;
