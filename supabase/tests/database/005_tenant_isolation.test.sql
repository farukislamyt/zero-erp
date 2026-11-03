begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users(
  id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
(
  '50000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','tenant-a@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
),
(
  '50000000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','tenant-b@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
);

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','50000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"50000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select pg_catalog.set_config('test.org_a',public.create_organization_with_admin('Tenant Isolation A','BDT','Asia/Dhaka')::text,true);

select pg_catalog.set_config('request.jwt.claim.sub','50000000-0000-4000-8000-000000000002',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"50000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
select pg_catalog.set_config('test.org_b',public.create_organization_with_admin('Tenant Isolation B','BDT','Asia/Dhaka')::text,true);

select pg_catalog.set_config('request.jwt.claim.sub','50000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"50000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);

select ok(public.is_active_org_member(current_setting('test.org_a')::uuid),
  'Tenant A creator has active membership in Tenant A');
select ok(not public.is_active_org_member(current_setting('test.org_b')::uuid),
  'Tenant A creator is not an active member of Tenant B');
select ok(public.has_org_permission(current_setting('test.org_a')::uuid,'accounts.read'),
  'Tenant A creator has scoped account permission in Tenant A');
select ok(not public.has_org_permission(current_setting('test.org_b')::uuid,'accounts.read'),
  'Tenant A permission does not leak into Tenant B');

select is((select count(*)::integer from public.accounts where organization_id=current_setting('test.org_a')::uuid),22,
  'Tenant A can read its own chart of accounts through RLS');
select is((select count(*)::integer from public.accounts where organization_id=current_setting('test.org_b')::uuid),0,
  'Tenant A cannot read Tenant B chart of accounts through RLS');
select throws_ok(
  format('select public.save_master_data(%L::uuid,%L,%L::jsonb)',
    current_setting('test.org_b'),'contact','{"contact_number":"CROSS-TENANT","name":"Should Not Exist"}'),
  '42501',
  'Tenant A cannot create master data inside Tenant B');
select is((select count(*)::integer from public.contacts where organization_id=current_setting('test.org_b')::uuid),0,
  'failed cross-tenant write leaves Tenant B unchanged');

select * from finish();
rollback;
