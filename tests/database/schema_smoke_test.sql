-- ZERO ERP database bootstrap smoke tests.
-- Runs after initial_database_schema.sql against a disposable PostgreSQL database.
-- This verifies bootstrap execution and critical catalog/security invariants; it
-- is not a substitute for authenticated workflow, concurrency, or business tests.

DO $tests$
DECLARE
  v_table_count integer;
  v_rls_table_count integer;
  v_policy_count integer;
  v_ungated_policy_count integer;
  v_unsafe_definer_count integer;
  v_missing_rpc_grants integer;
  v_direct_write_grants integer;
  v_test_organization_id uuid;
  v_test_draft_id uuid;
  v_missing_posting_locks integer;
  v_missing_contact_locks integer;
  v_unit_id uuid;
  v_product_id uuid;
  v_contact_id uuid;
  v_role_id uuid;
  v_expense_category_id uuid;
  v_expense_draft_id uuid;
  v_adjustment_journal_id uuid;
  v_reversal_journal_id uuid;
  v_balance_quantity numeric(20,6);
  v_trial_debits numeric(20,4);
  v_trial_credits numeric(20,4);
  v_sales_id uuid;
  v_payment_id uuid;
  v_payment_journal_id uuid;
  v_second_adjustment_id uuid;
  v_second_sales_id uuid;
  v_partial_payment_id uuid;
  v_purchase_id uuid;
  v_supplier_payment_id uuid;
  v_supplier_payment_journal_id uuid;
  v_receivable_aging numeric(20,4);
  v_unapplied_total numeric(20,4);
  v_inventory_total numeric(20,4);
BEGIN
  SELECT count(*)
    INTO v_table_count
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r';

  IF v_table_count <> 26 THEN
    RAISE EXCEPTION 'Expected 26 public tables; found %', v_table_count;
  END IF;

  SELECT count(*)
    INTO v_rls_table_count
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relrowsecurity;

  IF v_rls_table_count <> v_table_count THEN
    RAISE EXCEPTION 'RLS is enabled on % of % public tables',
      v_rls_table_count, v_table_count;
  END IF;

  SELECT count(*)
    INTO v_policy_count
  FROM pg_catalog.pg_policies
  WHERE schemaname = 'public';

  IF v_policy_count <> 26 THEN
    RAISE EXCEPTION 'Expected 26 public RLS policies; found %', v_policy_count;
  END IF;

  -- The global permissions catalog is intentionally readable by authenticated
  -- users. Every other SELECT policy must also check the module read permission.
  SELECT count(*)
    INTO v_ungated_policy_count
  FROM pg_catalog.pg_policies
  WHERE schemaname = 'public'
    AND cmd = 'SELECT'
    AND tablename <> 'permissions'
    AND coalesce(qual, '') NOT LIKE '%has_org_permission%';

  IF v_ungated_policy_count <> 0 THEN
    RAISE EXCEPTION '% SELECT policies do not enforce has_org_permission()',
      v_ungated_policy_count;
  END IF;

  IF to_regprocedure('public.has_org_permission(uuid,text)') IS NULL
     OR to_regprocedure('public.is_active_org_member(uuid)') IS NULL
     OR to_regprocedure('public.next_document_number(uuid,text)') IS NULL
     OR to_regprocedure('public.post_sales(uuid,uuid)') IS NULL
     OR to_regprocedure('public.post_purchase(uuid,uuid)') IS NULL
     OR to_regprocedure('public.post_contact_payment(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'One or more required security/posting RPCs are missing';
  END IF;

  IF has_function_privilege('anon', 'public.post_sales(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute the sales posting RPC';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.post_sales(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must be able to execute the granted sales posting RPC';
  END IF;

  IF has_function_privilege('anon', 'public.next_document_number(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute the document numbering RPC';
  END IF;

  -- SECURITY DEFINER routines must pin search_path to an empty path.
  SELECT count(*)
    INTO v_unsafe_definer_count
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prosecdef
    AND NOT coalesce(array_to_string(p.proconfig, ','), '') LIKE '%search_path=""%';

  IF v_unsafe_definer_count <> 0 THEN
    RAISE EXCEPTION '% SECURITY DEFINER functions do not pin search_path',
      v_unsafe_definer_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'accounts'
      AND t.tgname = 'accounts_prevent_hierarchy_cycle'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'Account hierarchy cycle trigger is missing';
  END IF;

  -- The accounting-period subsystem must remain completely absent:
  -- no period relations, columns, permissions, function arguments, or function logic.
  IF EXISTS (
       SELECT 1
       FROM pg_catalog.pg_class c
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'i', 'S')
         AND c.relname ~* 'period'
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_attribute a
       JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND a.attnum > 0
         AND NOT a.attisdropped
         AND a.attname ~* 'period'
     )
     OR EXISTS (
       SELECT 1 FROM public.permissions
       WHERE permission_key ~* 'period'
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_proc p
       JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public'
         AND (
           coalesce(array_to_string(p.proargnames, ','), '') ~* 'period'
           OR p.prosrc ILIKE '%period%'
         )
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_constraint con
       JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND con.conname ~* 'period'
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_type ty
       JOIN pg_catalog.pg_namespace n ON n.oid = ty.typnamespace
       WHERE n.nspname = 'public'
         AND ty.typname ~* 'period'
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_trigger t
       JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND NOT t.tgisinternal
         AND t.tgname ~* 'period'
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_policy p
       JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND p.polname ~* 'period'
     ) THEN
    RAISE EXCEPTION 'Accounting-period relations, columns, permissions, functions, triggers, or policies must not exist';
  END IF;

  -- Confirm the Supabase auth.uid() compatibility shim and exercise organization setup.
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '00000000-0000-0000-0000-000000000001',
    true
  );

  IF (SELECT auth.uid()) <> '00000000-0000-0000-0000-000000000001'::uuid THEN
    RAISE EXCEPTION 'auth.uid() compatibility shim did not return the JWT subject';
  END IF;

  INSERT INTO auth.users (id)
  VALUES ('00000000-0000-0000-0000-000000000001')
  ON CONFLICT (id) DO NOTHING;

  BEGIN
    PERFORM public.create_organization_with_admin(
      'Invalid timezone test', 'BDT', 'Invalid/ZeroERP'
    );
    RAISE EXCEPTION 'Organization creation accepted an invalid timezone';
  EXCEPTION
    WHEN SQLSTATE '22023' THEN NULL;
  END;

  v_test_organization_id := public.create_organization_with_admin(
    'Database smoke test organization', 'BDT', 'Asia/Dhaka'
  );

  -- An inactive number sequence must not silently allocate document numbers.
  UPDATE public.number_sequences
  SET is_active = false
  WHERE organization_id = v_test_organization_id AND document_type = 'purchase';

  BEGIN
    PERFORM public.next_document_number(v_test_organization_id, 'purchase');
    RAISE EXCEPTION 'Document numbering allocated from a disabled sequence';
  EXCEPTION
    WHEN SQLSTATE '55000' THEN NULL;
  END;

  -- All application business writes must pass through explicit RPCs.
  SELECT count(*)
    INTO v_direct_write_grants
  FROM pg_catalog.pg_tables t
  WHERE t.schemaname = 'public'
    AND (
      has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'INSERT')
      OR has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'UPDATE')
      OR has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'DELETE')
      OR has_table_privilege('anon', format('%I.%I', t.schemaname, t.tablename), 'SELECT')
      OR has_table_privilege('anon', format('%I.%I', t.schemaname, t.tablename), 'INSERT')
      OR has_table_privilege('anon', format('%I.%I', t.schemaname, t.tablename), 'UPDATE')
      OR has_table_privilege('anon', format('%I.%I', t.schemaname, t.tablename), 'DELETE')
    );

  IF v_direct_write_grants <> 0 THEN
    RAISE EXCEPTION '% public tables expose direct writes to authenticated or table access to anon', v_direct_write_grants;
  END IF;

  -- Every intended application RPC must be callable by authenticated users and
  -- unavailable to anon. The legacy one-step journal RPC remains intentionally disabled.
  SELECT count(*)
    INTO v_missing_rpc_grants
  FROM unnest(ARRAY[
    'public.is_active_org_member(uuid)',
    'public.has_org_permission(uuid,text)',
    'public.next_document_number(uuid,text)',
    'public.create_organization_with_admin(text,text,text)',
    'public.add_organization_user_by_email(uuid,text,uuid)',
    'public.update_organization_user_role(uuid,uuid,uuid)',
    'public.set_organization_user_active(uuid,uuid,boolean)',
    'public.post_purchase(uuid,uuid)',
    'public.post_opening_balances(uuid,date,jsonb,jsonb,jsonb,text)',
    'public.post_contact_payment(uuid,uuid)',
    'public.post_sales(uuid,uuid)',
    'public.reverse_journal_entry(uuid,uuid,date,text)',
    'public.post_expense(uuid,uuid)',
    'public.post_purchase_return(uuid,uuid)',
    'public.post_sales_return(uuid,uuid)',
    'public.post_confirmed_journal_entry(uuid,uuid)',
    'public.save_draft_transaction_document(uuid,text,jsonb,jsonb,uuid)',
    'public.confirm_transaction_document(uuid,text,uuid)',
    'public.revert_transaction_document_to_draft(uuid,text,uuid)',
    'public.void_transaction_document(uuid,text,uuid,text)',
    'public.delete_draft_transaction_document(uuid,text,uuid)',
    'public.save_master_data(uuid,text,jsonb,uuid)',
    'public.create_custom_role(uuid,text,text[])',
    'public.replace_custom_role_permissions(uuid,uuid,text[])',
    'public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text)',
    'public.set_payment_allocations(uuid,uuid,jsonb)',
    'public.post_inventory_adjustment(uuid,date,text,jsonb,uuid,uuid)',
    'public.report_trial_balance(uuid,date,date)',
    'public.report_general_ledger(uuid,uuid,date,date)',
    'public.report_profit_and_loss(uuid,date,date)',
    'public.report_balance_sheet(uuid,date)',
    'public.report_inventory_valuation(uuid,date)',
    'public.report_contact_balances(uuid,date)',
    'public.report_receivables_aging(uuid,date)',
    'public.report_payables_aging(uuid,date)',
    'public.report_unapplied_payments(uuid,date)'
  ]::text[]) AS expected(signature)
  WHERE to_regprocedure(expected.signature) IS NULL
     OR NOT has_function_privilege('authenticated', to_regprocedure(expected.signature), 'EXECUTE')
     OR has_function_privilege('anon', to_regprocedure(expected.signature), 'EXECUTE');

  IF v_missing_rpc_grants <> 0 THEN
    RAISE EXCEPTION '% expected RPCs are missing or have incorrect execute grants', v_missing_rpc_grants;
  END IF;

  IF has_function_privilege(
    'authenticated',
    'public.post_manual_journal_entry(uuid,text,date,text,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Legacy one-step journal posting RPC must remain unavailable';
  END IF;

  -- Organization-level shared locks serialize normal posting against the
  -- exclusive one-time opening-balance initialization lock without serializing
  -- ordinary postings with one another.
  SELECT count(*)
    INTO v_missing_posting_locks
  FROM unnest(ARRAY[
    'public.post_purchase(uuid,uuid)',
    'public.post_contact_payment(uuid,uuid)',
    'public.post_sales(uuid,uuid)',
    'public.reverse_journal_entry(uuid,uuid,date,text)',
    'public.post_expense(uuid,uuid)',
    'public.post_purchase_return(uuid,uuid)',
    'public.post_sales_return(uuid,uuid)',
    'public.post_confirmed_journal_entry(uuid,uuid)'
  ]::text[]) AS expected(signature)
  WHERE position('for share' in lower((
    SELECT p.prosrc
    FROM pg_catalog.pg_proc p
    WHERE p.oid = to_regprocedure(expected.signature)
  ))) = 0;

  IF v_missing_posting_locks <> 0 THEN
    RAISE EXCEPTION '% posting RPCs do not serialize against opening-balance initialization',
      v_missing_posting_locks;
  END IF;

  IF position('for update' in lower((
    SELECT p.prosrc FROM pg_catalog.pg_proc p
    WHERE p.oid = to_regprocedure('public.post_opening_balances(uuid,date,jsonb,jsonb,jsonb,text)')
  ))) = 0 THEN
    RAISE EXCEPTION 'Opening-balance posting must hold the exclusive organization lock';
  END IF;

  -- Every operation that changes contact-level AR/AP balances must lock contacts
  -- in a consistent order, preventing concurrent receipts/payments/refunds from
  -- validating against stale party balances.
  SELECT count(*)
    INTO v_missing_contact_locks
  FROM unnest(ARRAY[
    'public.post_purchase(uuid,uuid)',
    'public.post_sales(uuid,uuid)',
    'public.post_contact_payment(uuid,uuid)',
    'public.post_expense(uuid,uuid)',
    'public.post_purchase_return(uuid,uuid)',
    'public.post_sales_return(uuid,uuid)',
    'public.reverse_journal_entry(uuid,uuid,date,text)',
    'public.post_confirmed_journal_entry(uuid,uuid)'
  ]::text[]) AS expected(signature)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    WHERE p.oid = to_regprocedure(expected.signature)
      AND p.prosrc ILIKE '%public.contacts%'
      AND position('for update' in lower(p.prosrc)) > 0
  );

  IF v_missing_contact_locks <> 0 THEN
    RAISE EXCEPTION '% party-ledger posting RPCs do not lock contact rows',
      v_missing_contact_locks;
  END IF;

  -- Exercise the draft-save path that previously called a nonexistent
  -- PostgreSQL function when an empty header was submitted.
  BEGIN
    PERFORM public.save_draft_transaction_document(
      v_test_organization_id, 'expense', '{}'::jsonb
    );
    RAISE EXCEPTION 'An empty new draft header must be rejected';
  EXCEPTION
    WHEN SQLSTATE '22023' THEN NULL;
  END;

  v_test_draft_id := public.save_draft_transaction_document(
    v_test_organization_id,
    'journal_entry',
    '{"entry_number":"SMOKE-JE-001","entry_date":"2026-11-03"}'::jsonb,
    '[]'::jsonb
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.journal_entries
    WHERE organization_id = v_test_organization_id
      AND id = v_test_draft_id
      AND status = 'draft'
      AND entry_type = 'manual'
      AND entry_number <> 'SMOKE-JE-001'
  ) THEN
    RAISE EXCEPTION 'A valid manual journal draft could not be saved';
  END IF;


  -- Organization bootstrap must install a usable default chart and document sequences.
  IF (SELECT count(*) FROM public.accounts WHERE organization_id=v_test_organization_id AND is_system_account) <> 22 THEN
    RAISE EXCEPTION 'Default chart of accounts was not seeded completely';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1120' AND is_control_account)
     OR NOT EXISTS (SELECT 1 FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='2110' AND is_control_account)
     OR NOT EXISTS (SELECT 1 FROM public.expense_categories WHERE organization_id=v_test_organization_id AND category_code='GEN') THEN
    RAISE EXCEPTION 'Default AR/AP control accounts or general expense category are missing';
  END IF;

  -- Secure master-data CRUD: create a unit, contact and product through RPC only.
  v_unit_id := public.save_master_data(
    v_test_organization_id,'unit','{"name":"Each"}'::jsonb
  );
  v_contact_id := public.save_master_data(
    v_test_organization_id,'contact',
    '{"contact_number":"C-SMOKE-001","name":"Smoke Test Contact"}'::jsonb
  );
  v_product_id := public.save_master_data(
    v_test_organization_id,'product',
    pg_catalog.jsonb_build_object(
      'product_code','P-SMOKE-001','name','Smoke Test Product','unit_id',v_unit_id
    )
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.products p
    JOIN public.accounts inv ON inv.organization_id=p.organization_id AND inv.id=p.inventory_account_id
    JOIN public.accounts rev ON rev.organization_id=p.organization_id AND rev.id=p.sales_account_id
    JOIN public.accounts cogs ON cogs.organization_id=p.organization_id AND cogs.id=p.cogs_account_id
    WHERE p.organization_id=v_test_organization_id AND p.id=v_product_id
      AND inv.account_code='1130' AND rev.account_code='4100' AND cogs.account_code='5100'
  ) THEN
    RAISE EXCEPTION 'Product default account mappings were not assigned';
  END IF;

  -- Custom roles may receive only permissions held by the caller and cannot mutate Administrator.
  v_role_id := public.create_custom_role(
    v_test_organization_id,'Smoke Sales Clerk',ARRAY['sales.read','products.read']
  );
  PERFORM public.replace_custom_role_permissions(
    v_test_organization_id,v_role_id,ARRAY['sales.read']
  );
  IF (SELECT count(*) FROM public.role_permissions WHERE role_id=v_role_id) <> 1 THEN
    RAISE EXCEPTION 'Custom role permission replacement failed';
  END IF;

  PERFORM public.update_organization_profile(
    v_test_organization_id,'Database smoke test organization','+8801000000000',
    'smoke@example.invalid','Test address','Dhaka','Bangladesh','BDT','Asia/Dhaka',null,null
  );

  -- Draft creation gets its document number from the database, not the caller.
  SELECT id INTO v_expense_category_id
  FROM public.expense_categories
  WHERE organization_id=v_test_organization_id AND category_code='GEN';
  v_expense_draft_id := public.save_draft_transaction_document(
    v_test_organization_id,'expense',
    pg_catalog.jsonb_build_object(
      'expense_category_id',v_expense_category_id,
      'payable_account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='2110'),
      'expense_date','2026-11-03','amount',125.00,'contact_id',v_contact_id,'description','Smoke test expense'
    )
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.expenses
    WHERE organization_id=v_test_organization_id AND id=v_expense_draft_id
      AND expense_number LIKE 'EXP-%' AND status='draft'
  ) THEN
    RAISE EXCEPTION 'Expense draft did not receive a server-generated document number';
  END IF;

  -- Inventory adjustments post stock and balanced ledger entries atomically.
  v_adjustment_journal_id := public.post_inventory_adjustment(
    v_test_organization_id,'2026-11-03','Smoke test opening stock',
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id',v_product_id,'direction','increase','quantity',10,'unit_cost',100
    ))
  );
  SELECT quantity INTO v_balance_quantity
  FROM public.inventory_balances
  WHERE organization_id=v_test_organization_id AND product_id=v_product_id;
  IF v_balance_quantity <> 10 THEN
    RAISE EXCEPTION 'Inventory adjustment did not increase stock as expected';
  END IF;

  v_reversal_journal_id := public.reverse_journal_entry(
    v_test_organization_id,v_adjustment_journal_id,'2026-11-03','Smoke test adjustment reversal'
  );
  SELECT quantity INTO v_balance_quantity
  FROM public.inventory_balances
  WHERE organization_id=v_test_organization_id AND product_id=v_product_id;
  IF v_balance_quantity <> 0 THEN
    RAISE EXCEPTION 'Inventory adjustment reversal did not restore the original stock balance';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.journal_entries
    WHERE organization_id=v_test_organization_id AND id=v_reversal_journal_id
      AND reversal_of_id=v_adjustment_journal_id AND status='posted'
  ) THEN
    RAISE EXCEPTION 'Inventory adjustment reversal journal was not recorded';
  END IF;


  -- Re-seed stock for a complete sales -> receipt -> invoice-allocation workflow.
  v_second_adjustment_id := public.post_inventory_adjustment(
    v_test_organization_id,'2026-11-03','Smoke test sales stock',
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id',v_product_id,'direction','increase','quantity',10,'unit_cost',100
    ))
  );

  v_sales_id := public.save_draft_transaction_document(
    v_test_organization_id,'sales',
    pg_catalog.jsonb_build_object(
      'customer_id',v_contact_id,
      'invoice_date','2026-11-03',
      'subtotal',100,'discount_amount',0,'total_amount',100,
      'receivable_account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1120')
    ),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'line_number',1,'product_id',v_product_id,'quantity',1,'unit_price',100,'line_total',100
    ))
  );
  PERFORM public.confirm_transaction_document(v_test_organization_id,'sales',v_sales_id);
  PERFORM public.post_sales(v_test_organization_id,v_sales_id);

  v_payment_id := public.save_draft_transaction_document(
    v_test_organization_id,'payment',
    pg_catalog.jsonb_build_object(
      'payment_type','receipt','contact_id',v_contact_id,'payment_date','2026-11-03',
      'amount',100,'account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1110'),
      'settlement_account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1120'),
      'description','Smoke test customer receipt'
    )
  );
  PERFORM public.set_payment_allocations(
    v_test_organization_id,v_payment_id,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'document_type','sales','document_id',v_sales_id,'allocated_amount',100
    ))
  );
  PERFORM public.confirm_transaction_document(v_test_organization_id,'payment',v_payment_id);
  v_payment_journal_id := public.post_contact_payment(v_test_organization_id,v_payment_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.payments
    WHERE organization_id=v_test_organization_id AND id=v_payment_id
      AND status='posted' AND posted_journal_entry_id=v_payment_journal_id
  ) THEN
    RAISE EXCEPTION 'Allocated customer receipt did not post';
  END IF;


  -- Partial allocation must expose both the open invoice balance and the unapplied credit.
  v_second_sales_id := public.save_draft_transaction_document(
    v_test_organization_id,'sales',
    pg_catalog.jsonb_build_object(
      'customer_id',v_contact_id,'invoice_date','2026-11-03',
      'subtotal',100,'discount_amount',0,'total_amount',100,
      'receivable_account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1120')
    ),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'line_number',1,'product_id',v_product_id,'quantity',1,'unit_price',100,'line_total',100
    ))
  );
  PERFORM public.confirm_transaction_document(v_test_organization_id,'sales',v_second_sales_id);
  PERFORM public.post_sales(v_test_organization_id,v_second_sales_id);

  v_partial_payment_id := public.save_draft_transaction_document(
    v_test_organization_id,'payment',
    pg_catalog.jsonb_build_object(
      'payment_type','receipt','contact_id',v_contact_id,'payment_date','2026-11-03',
      'amount',100,'account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1110'),
      'settlement_account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1120'),
      'description','Smoke test partially allocated receipt'
    )
  );
  PERFORM public.set_payment_allocations(
    v_test_organization_id,v_partial_payment_id,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'document_type','sales','document_id',v_second_sales_id,'allocated_amount',60
    ))
  );
  PERFORM public.confirm_transaction_document(v_test_organization_id,'payment',v_partial_payment_id);
  PERFORM public.post_contact_payment(v_test_organization_id,v_partial_payment_id);

  -- Exercise expense and purchase posting, then allocate one supplier payment across both documents.
  PERFORM public.confirm_transaction_document(v_test_organization_id,'expense',v_expense_draft_id);
  PERFORM public.post_expense(v_test_organization_id,v_expense_draft_id);

  v_purchase_id := public.save_draft_transaction_document(
    v_test_organization_id,'purchase',
    pg_catalog.jsonb_build_object(
      'supplier_id',v_contact_id,'invoice_date','2026-11-03',
      'subtotal',250,'discount_amount',0,'total_amount',250,
      'payable_account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='2110')
    ),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'line_number',1,'product_id',v_product_id,'quantity',5,'unit_cost',50,'line_total',250
    ))
  );
  PERFORM public.confirm_transaction_document(v_test_organization_id,'purchase',v_purchase_id);
  PERFORM public.post_purchase(v_test_organization_id,v_purchase_id);

  v_supplier_payment_id := public.save_draft_transaction_document(
    v_test_organization_id,'payment',
    pg_catalog.jsonb_build_object(
      'payment_type','payment','contact_id',v_contact_id,'payment_date','2026-11-03',
      'amount',375,'account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='1110'),
      'settlement_account_id',(SELECT id FROM public.accounts WHERE organization_id=v_test_organization_id AND account_code='2110'),
      'description','Smoke test supplier settlement'
    )
  );
  PERFORM public.set_payment_allocations(
    v_test_organization_id,v_supplier_payment_id,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('document_type','purchase','document_id',v_purchase_id,'allocated_amount',250),
      pg_catalog.jsonb_build_object('document_type','expense','document_id',v_expense_draft_id,'allocated_amount',125)
    )
  );
  PERFORM public.confirm_transaction_document(v_test_organization_id,'payment',v_supplier_payment_id);
  v_supplier_payment_journal_id := public.post_contact_payment(v_test_organization_id,v_supplier_payment_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.payments
    WHERE organization_id=v_test_organization_id AND id=v_supplier_payment_id
      AND status='posted' AND posted_journal_entry_id=v_supplier_payment_journal_id
  ) THEN
    RAISE EXCEPTION 'Supplier payment allocated across purchase and expense did not post';
  END IF;

  -- Reporting RPCs must be exposed to authenticated users and return balanced totals.
  SELECT sum(movement_debit),sum(movement_credit)
  INTO v_trial_debits,v_trial_credits
  FROM public.report_trial_balance(v_test_organization_id,'2026-01-01','2026-12-31');
  IF v_trial_debits IS DISTINCT FROM v_trial_credits THEN
    RAISE EXCEPTION 'Trial balance does not reconcile: debits %, credits %',v_trial_debits,v_trial_credits;
  END IF;
  PERFORM * FROM public.report_profit_and_loss(v_test_organization_id,'2026-01-01','2026-12-31');
  PERFORM * FROM public.report_balance_sheet(v_test_organization_id,'2026-12-31');
  PERFORM * FROM public.report_inventory_valuation(v_test_organization_id,'2026-12-31');
  PERFORM * FROM public.report_contact_balances(v_test_organization_id,'2026-12-31');
  PERFORM * FROM public.report_receivables_aging(v_test_organization_id,'2026-12-31');
  PERFORM * FROM public.report_payables_aging(v_test_organization_id,'2026-12-31');
  PERFORM * FROM public.report_unapplied_payments(v_test_organization_id,'2026-12-31');


  SELECT coalesce(sum(current_amount+days_31_60+days_61_90+over_90),0)
  INTO v_receivable_aging
  FROM public.report_receivables_aging(v_test_organization_id,'2026-12-31');
  SELECT coalesce(sum(unapplied_amount),0)
  INTO v_unapplied_total
  FROM public.report_unapplied_payments(v_test_organization_id,'2026-12-31');
  IF v_receivable_aging<>40 OR v_unapplied_total<>40 THEN
    RAISE EXCEPTION 'Partial receipt aging/unapplied balances do not reconcile: open invoices %, unapplied credits %',
      v_receivable_aging,v_unapplied_total;
  END IF;
  IF EXISTS (SELECT 1 FROM public.report_payables_aging(v_test_organization_id,'2026-12-31')) THEN
    RAISE EXCEPTION 'Fully allocated supplier payment left an open payable balance';
  END IF;
  SELECT coalesce(sum(inventory_value),0) INTO v_inventory_total
  FROM public.report_inventory_valuation(v_test_organization_id,'2026-12-31');
  IF v_inventory_total<>1050 THEN
    RAISE EXCEPTION 'Inventory valuation mismatch after sales and purchase postings: %',v_inventory_total;
  END IF;
  IF to_regprocedure('public.set_payment_allocations(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.post_inventory_adjustment(uuid,date,text,jsonb,uuid,uuid)') IS NULL
     OR to_regprocedure('public.save_master_data(uuid,text,jsonb,uuid)') IS NULL
     OR to_regprocedure('public.create_custom_role(uuid,text,text[])') IS NULL
     OR to_regprocedure('public.update_organization_profile(uuid,text,text,text,text,text,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'One or more new ERP operational RPCs are missing';
  END IF;

  RAISE NOTICE
    'PASS: % tables, % RLS policies, RPC grants, no direct table writes, organization setup, sequence controls, SECURITY DEFINER search_path, and integrity triggers verified',
    v_table_count, v_policy_count;
END;
$tests$;
