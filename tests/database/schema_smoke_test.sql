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
  INSERT INTO public.number_sequences (
    organization_id, document_type, prefix, next_number, padding, is_active
  )
  VALUES (v_test_organization_id, 'purchase', 'PUR-', 1, 5, false);

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
    'public.delete_draft_transaction_document(uuid,text,uuid)'
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
  ) THEN
    RAISE EXCEPTION 'A valid manual journal draft could not be saved';
  END IF;

  RAISE NOTICE
    'PASS: % tables, % RLS policies, RPC grants, no direct table writes, organization setup, sequence controls, SECURITY DEFINER search_path, and integrity triggers verified',
    v_table_count, v_policy_count;
END;
$tests$;
