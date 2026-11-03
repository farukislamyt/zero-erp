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
BEGIN
  SELECT count(*)
    INTO v_table_count
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r';

  IF v_table_count <> 27 THEN
    RAISE EXCEPTION 'Expected 27 public tables; found %', v_table_count;
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

  IF v_policy_count <> 27 THEN
    RAISE EXCEPTION 'Expected 27 public RLS policies; found %', v_policy_count;
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
     OR to_regprocedure('public.post_contact_payment(uuid,uuid,uuid)') IS NULL THEN
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

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'accounting_periods'
      AND t.tgname = 'accounting_periods_prevent_overlap'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'Accounting period overlap trigger is missing';
  END IF;

  -- Confirm the Supabase auth.uid() compatibility shim is callable.
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '00000000-0000-0000-0000-000000000001',
    true
  );

  IF (SELECT auth.uid()) <> '00000000-0000-0000-0000-000000000001'::uuid THEN
    RAISE EXCEPTION 'auth.uid() compatibility shim did not return the JWT subject';
  END IF;

  RAISE NOTICE
    'PASS: % tables, % RLS policies, critical RPC grants, SECURITY DEFINER search_path, and integrity triggers verified',
    v_table_count, v_policy_count;
END;
$tests$;
