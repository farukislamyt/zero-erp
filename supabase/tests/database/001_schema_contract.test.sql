begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

select is((select count(*)::integer from pg_catalog.pg_tables where schemaname='public'),26,'all 26 public tables are present');
select is((select count(*)::integer from pg_catalog.pg_tables t join pg_catalog.pg_class c on c.relname=t.tablename join pg_catalog.pg_namespace n on n.oid=c.relnamespace and n.nspname='public' where t.schemaname='public' and c.relrowsecurity),26,'RLS is enabled on every public table');
select is((select count(*)::integer from pg_catalog.pg_policies where schemaname='public'),26,'all expected public RLS policies are installed');
select is((select count(*)::integer from public.permissions),43,'all 43 global permission keys are seeded');
select is((select count(*)::integer from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal),37,'all 37 effective public triggers are installed');
select is((select count(*)::integer from pg_catalog.pg_index i join pg_catalog.pg_class idx on idx.oid=i.indexrelid join pg_catalog.pg_namespace n on n.oid=idx.relnamespace left join pg_catalog.pg_constraint con on con.conindid=i.indexrelid where n.nspname='public' and con.oid is null),29,'all 29 explicit public indexes are installed');
select ok(not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'],false)),'every SECURITY DEFINER public function pins an empty search_path');
select ok(pg_catalog.to_regprocedure('public.transfer_organization_administrator(uuid,uuid)') is null,'Administrator transfer RPC is absent');
select is((select count(*)::integer from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('v','m')),0,'no SQL views or materialized views are present');
select is((select count(*)::integer from pg_catalog.pg_tables where schemaname='public' and tablename ilike '%period%'),0,'no accounting-period table has been introduced');
select ok(not exists(
 select 1
 from pg_catalog.pg_class c
 join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind in ('r','p') and (
  pg_catalog.has_table_privilege('authenticated',c.oid,'INSERT')
  or pg_catalog.has_table_privilege('authenticated',c.oid,'UPDATE')
  or pg_catalog.has_table_privilege('authenticated',c.oid,'DELETE')
  or pg_catalog.has_table_privilege('anon',c.oid,'INSERT')
  or pg_catalog.has_table_privilege('anon',c.oid,'UPDATE')
  or pg_catalog.has_table_privilege('anon',c.oid,'DELETE')
 )),'browser roles have no direct public-table write privileges');
select ok(not pg_catalog.has_function_privilege('anon','public.create_organization_with_admin(text,text,text)','EXECUTE'),'anon cannot execute organization creation');
select ok(pg_catalog.has_function_privilege('authenticated','public.create_organization_with_admin(text,text,text)','EXECUTE'),'authenticated can execute organization creation');

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('10000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','db-ci-creator@example.invalid','',pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,pg_catalog.now(),pg_catalog.now());

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select lives_ok($$select public.create_organization_with_admin('ZERO ERP CI Organization','BDT','Asia/Dhaka')$$,'authenticated creator can bootstrap a company');
reset role;

select is((select count(*)::integer from public.organizations where name='ZERO ERP CI Organization'),1,'company creation persisted exactly one organization');
select is((select count(*)::integer from public.organization_users ou join public.organizations o on o.id=ou.organization_id where o.name='ZERO ERP CI Organization' and ou.user_id='10000000-0000-4000-8000-000000000001' and ou.is_active and ou.created_at=o.created_at),1,'creator membership is active and timestamp-anchored');
select is((select count(*)::integer from public.organization_users ou join public.roles r on r.id=ou.role_id and r.organization_id=ou.organization_id join public.organizations o on o.id=ou.organization_id where o.name='ZERO ERP CI Organization' and r.is_system_role and r.name='Administrator' and ou.is_active),1,'creator is the one active system Administrator');
select is((select count(*)::integer from public.role_permissions rp join public.roles r on r.id=rp.role_id join public.organization_users ou on ou.role_id=r.id and ou.organization_id=r.organization_id join public.organizations o on o.id=ou.organization_id where o.name='ZERO ERP CI Organization' and r.is_system_role and r.name='Administrator'),43,'Creator Administrator receives all 43 permissions');
select is((select count(*)::integer from public.accounts a join public.organizations o on o.id=a.organization_id where o.name='ZERO ERP CI Organization'),22,'company bootstrap seeds the 22-account default chart');
select is((select count(*)::integer from public.expense_categories ec join public.organizations o on o.id=ec.organization_id where o.name='ZERO ERP CI Organization'),1,'company bootstrap seeds General Expenses category');
select is((select count(*)::integer from public.number_sequences ns join public.organizations o on o.id=ns.organization_id where o.name='ZERO ERP CI Organization'),8,'company bootstrap seeds all eight document sequences');

select throws_ok($$select public.create_organization_with_admin('Second Company','BDT','Asia/Dhaka')$$,'23505','This account has already created a company. Each account may create only one company.','creator cannot create a second company');
select throws_ok($$update public.organization_users set is_active=false where user_id='10000000-0000-4000-8000-000000000001'$$,'42501','The original creator Administrator membership is permanently immutable.','creator membership cannot be deactivated or updated');
select throws_ok($$delete from public.organization_users where user_id='10000000-0000-4000-8000-000000000001'$$,'42501','The original creator Administrator membership can never be deleted.','creator membership cannot be deleted');

select lives_ok($$select public.create_custom_role((select id from public.organizations where name='ZERO ERP CI Organization'),'CI Reporting Role',array['reports.read','sales.read'])$$,'Administrator can create a least-privilege custom role');
select is((select count(*)::integer from public.role_permissions rp join public.roles r on r.id=rp.role_id join public.organizations o on o.id=r.organization_id where o.name='ZERO ERP CI Organization' and r.name='CI Reporting Role'),2,'custom role receives exactly the requested permission subset');
select throws_ok($$select public.create_custom_role((select id from public.organizations where name='ZERO ERP CI Organization'),'Forbidden Admin Role',array['users.manage'])$$,'42501','Member and role administration privileges are reserved exclusively for the system Administrator.','custom role cannot receive users.manage');

select lives_ok($$select public.update_organization_profile((select id from public.organizations where name='ZERO ERP CI Organization'),'ZERO ERP CI Organization Updated',null,null,null,null,null,'BDT','Asia/Dhaka',null,null)$$,'Administrator can update a valid company profile');
select is((select name from public.organizations where name='ZERO ERP CI Organization Updated'),'ZERO ERP CI Organization Updated','profile update persisted');
select is(public.next_document_number((select id from public.organizations where name='ZERO ERP CI Organization Updated'),'inventory_adjustment'),'IA-00001','inventory adjustment numbering uses seeded prefix and inventory.adjust permission');
select lives_ok($$select * from public.report_trial_balance((select id from public.organizations where name='ZERO ERP CI Organization Updated'),date '2026-01-01',date '2026-12-31')$$,'authorized Administrator can call trial balance report');
select lives_ok($$select * from public.report_inventory_valuation((select id from public.organizations where name='ZERO ERP CI Organization Updated'),date '2026-12-31')$$,'authorized Administrator can call inventory valuation report');
select ok(public.is_active_org_member((select id from public.organizations where name='ZERO ERP CI Organization Updated')),'Creator remains an active organization member');
select ok(public.has_org_permission((select id from public.organizations where name='ZERO ERP CI Organization Updated'),'inventory.adjust'),'Creator Administrator has inventory.adjust permission');

select * from finish();
rollback;
