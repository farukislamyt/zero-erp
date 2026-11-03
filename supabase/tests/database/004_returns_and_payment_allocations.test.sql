begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users(
  id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values (
  '40000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','returns-admin@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
);

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','40000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"40000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select pg_catalog.set_config('test.org_id',public.create_organization_with_admin('Returns And Allocations Test','BDT','Asia/Dhaka')::text,true);

select set_config('test.supplier_id',public.save_master_data(current_setting('test.org_id')::uuid,'contact','{"contact_number":"SUP-RET-001","name":"Return Supplier"}'::jsonb)::text,true);
select set_config('test.customer_id',public.save_master_data(current_setting('test.org_id')::uuid,'contact','{"contact_number":"CUS-RET-001","name":"Return Customer"}'::jsonb)::text,true);
select set_config('test.unit_id',public.save_master_data(current_setting('test.org_id')::uuid,'unit','{"name":"Return Test Piece"}'::jsonb)::text,true);
select set_config('test.product_id',public.save_master_data(
  current_setting('test.org_id')::uuid,'product',
  jsonb_build_object('product_code','RET-001','name','Return Test Product','unit_id',current_setting('test.unit_id')::uuid)
)::text,true);

select public.post_opening_balances(
  current_setting('test.org_id')::uuid,date '2026-03-01',
  jsonb_build_array(jsonb_build_object(
    'account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='3300'),
    'debit',0,'credit',1000,'description','Opening inventory equity'
  )),
  '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('product_id',current_setting('test.product_id')::uuid,'quantity',10,'unit_cost',100)),
  'Returns test opening'
);

select set_config('test.purchase_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'purchase',
  jsonb_build_object(
    'invoice_id','PUR-RET-001','supplier_id',current_setting('test.supplier_id')::uuid,
    'invoice_date','2026-03-02','subtotal',240,'discount_amount',0,'total_amount',240,
    'payable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='2110')
  ),
  jsonb_build_array(jsonb_build_object('line_number',1,'product_id',current_setting('test.product_id')::uuid,'quantity',2,'unit_cost',120,'line_total',240))
)::text,true);
select public.confirm_transaction_document(current_setting('test.org_id')::uuid,'purchase',current_setting('test.purchase_id')::uuid);
select public.post_purchase(current_setting('test.org_id')::uuid,current_setting('test.purchase_id')::uuid);
select set_config('test.purchase_item_id',(select id::text from public.purchase_items where organization_id=current_setting('test.org_id')::uuid and purchase_id=current_setting('test.purchase_id')::uuid limit 1),true);

select set_config('test.purchase_return_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'purchase_return',
  jsonb_build_object(
    'return_number','PR-RET-001','purchase_id',current_setting('test.purchase_id')::uuid,
    'supplier_id',current_setting('test.supplier_id')::uuid,'return_date','2026-03-03',
    'subtotal',120,'discount_amount',0,'total_amount',120,
    'payable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='2110'),
    'purchase_return_variance_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='4100')
  ),
  jsonb_build_array(jsonb_build_object(
    'line_number',1,'purchase_item_id',current_setting('test.purchase_item_id')::uuid,
    'product_id',current_setting('test.product_id')::uuid,'quantity',1,'unit_cost',120,'line_total',120
  ))
)::text,true);
select lives_ok(format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',current_setting('test.org_id'),'purchase_return',current_setting('test.purchase_return_id')),
  'valid purchase return confirms');
select set_config('test.purchase_return_journal_id',public.post_purchase_return(current_setting('test.org_id')::uuid,current_setting('test.purchase_return_id')::uuid)::text,true);
select is((select status from public.purchase_returns where id=current_setting('test.purchase_return_id')::uuid),'posted',
  'purchase return posts');
select is((select status from public.purchase where id=current_setting('test.purchase_id')::uuid),'partially_returned',
  'purchase source is marked partially returned');
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),11::numeric,
  'purchase return removes returned quantity from stock');

select set_config('test.sale_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'sales',
  jsonb_build_object(
    'invoice_id','SAL-RET-001','customer_id',current_setting('test.customer_id')::uuid,
    'invoice_date','2026-03-04','subtotal',400,'discount_amount',0,'total_amount',400,
    'receivable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1120')
  ),
  jsonb_build_array(jsonb_build_object('line_number',1,'product_id',current_setting('test.product_id')::uuid,'quantity',2,'unit_price',200,'line_total',400))
)::text,true);
select public.confirm_transaction_document(current_setting('test.org_id')::uuid,'sales',current_setting('test.sale_id')::uuid);
select public.post_sales(current_setting('test.org_id')::uuid,current_setting('test.sale_id')::uuid);
select set_config('test.sales_item_id',(select id::text from public.sales_items where organization_id=current_setting('test.org_id')::uuid and sales_id=current_setting('test.sale_id')::uuid limit 1),true);

select set_config('test.sales_return_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'sales_return',
  jsonb_build_object(
    'return_number','SR-RET-001','sales_id',current_setting('test.sale_id')::uuid,
    'customer_id',current_setting('test.customer_id')::uuid,'return_date','2026-03-05',
    'subtotal',200,'discount_amount',0,'total_amount',200,
    'receivable_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1120')
  ),
  jsonb_build_array(jsonb_build_object(
    'line_number',1,'sales_item_id',current_setting('test.sales_item_id')::uuid,
    'product_id',current_setting('test.product_id')::uuid,'quantity',1,'unit_price',200,'line_total',200
  ))
)::text,true);
select lives_ok(format('select public.confirm_transaction_document(%L::uuid,%L,%L::uuid)',current_setting('test.org_id'),'sales_return',current_setting('test.sales_return_id')),
  'valid sales return confirms');
select set_config('test.sales_return_journal_id',public.post_sales_return(current_setting('test.org_id')::uuid,current_setting('test.sales_return_id')::uuid)::text,true);
select is((select status from public.sales_returns where id=current_setting('test.sales_return_id')::uuid),'posted',
  'sales return posts');
select is((select status from public.sales where id=current_setting('test.sale_id')::uuid),'partially_returned',
  'sales source is marked partially returned');
select is((select quantity from public.inventory_balances where organization_id=current_setting('test.org_id')::uuid and product_id=current_setting('test.product_id')::uuid),10::numeric,
  'sales return restores returned quantity to stock');

select set_config('test.receipt_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'payment',
  jsonb_build_object(
    'payment_number','PAY-RET-RECEIPT','payment_type','receipt',
    'contact_id',current_setting('test.customer_id')::uuid,'payment_date','2026-03-06',
    'amount',100,'account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1110'),
    'settlement_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1120'),
    'description','Customer receipt allocation'
  )
)::text,true);
select lives_ok(format('select public.set_payment_allocations(%L::uuid,%L::uuid,%L::jsonb)',
  current_setting('test.org_id'),current_setting('test.receipt_id'),
  jsonb_build_array(jsonb_build_object('document_type','sales','document_id',current_setting('test.sale_id')::uuid,'allocated_amount',100))::text),
  'receipt allocation to matching posted sales invoice succeeds');
select public.confirm_transaction_document(current_setting('test.org_id')::uuid,'payment',current_setting('test.receipt_id')::uuid);
select set_config('test.receipt_journal_id',public.post_contact_payment(current_setting('test.org_id')::uuid,current_setting('test.receipt_id')::uuid)::text,true);
select is((select status from public.payments where id=current_setting('test.receipt_id')::uuid),'posted',
  'allocated customer receipt posts');
select is((select count(*)::integer from public.payment_allocations where organization_id=current_setting('test.org_id')::uuid and payment_id=current_setting('test.receipt_id')::uuid),1,
  'receipt allocation persists exactly once');

select set_config('test.supplier_payment_id',public.save_draft_transaction_document(
  current_setting('test.org_id')::uuid,'payment',
  jsonb_build_object(
    'payment_number','PAY-RET-SUPPLIER','payment_type','payment',
    'contact_id',current_setting('test.supplier_id')::uuid,'payment_date','2026-03-07',
    'amount',50,'account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='1110'),
    'settlement_account_id',(select id from public.accounts where organization_id=current_setting('test.org_id')::uuid and account_code='2110'),
    'description','Supplier payment allocation'
  )
)::text,true);
select lives_ok(format('select public.set_payment_allocations(%L::uuid,%L::uuid,%L::jsonb)',
  current_setting('test.org_id'),current_setting('test.supplier_payment_id'),
  jsonb_build_array(jsonb_build_object('document_type','purchase','document_id',current_setting('test.purchase_id')::uuid,'allocated_amount',50))::text),
  'supplier payment allocation to matching posted purchase succeeds');
select public.confirm_transaction_document(current_setting('test.org_id')::uuid,'payment',current_setting('test.supplier_payment_id')::uuid);
select set_config('test.supplier_payment_journal_id',public.post_contact_payment(current_setting('test.org_id')::uuid,current_setting('test.supplier_payment_id')::uuid)::text,true);
select is((select status from public.payments where id=current_setting('test.supplier_payment_id')::uuid),'posted',
  'allocated supplier payment posts');
select is((select count(*)::integer from public.payment_allocations where organization_id=current_setting('test.org_id')::uuid and payment_id=current_setting('test.supplier_payment_id')::uuid),1,
  'supplier payment allocation persists exactly once');

select * from finish();
rollback;
