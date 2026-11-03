begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

insert into auth.users(
  id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
(
  '60000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','membership-admin@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
),
(
  '60000000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','membership-user@example.invalid','',
  pg_catalog.now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  pg_catalog.now(),pg_catalog.now()
);

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"60000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select pg_catalog.set_config('test.org_id',
  public.create_organization_with_admin('Membership Lifecycle CI','BDT','Asia/Dhaka')::text,true);

select pg_catalog.set_config('test.role_read',
  public.create_custom_role(current_setting('test.org_id')::uuid,'Lifecycle Read Role',array['accounts.read','reports.read'])::text,true);
select pg_catalog.set_config('test.role_accounts',
  public.create_custom_role(current_setting('test.org_id')::uuid,'Accounts Read Role',array['accounts.read'])::text,true);
select pg_catalog.set_config('test.member_id',
  public.add_organization_user_by_email(
    current_setting('test.org_id')::uuid,'membership-user@example.invalid',
    current_setting('test.role_read')::uuid
  )::text,true);
reset role;

select is((select count(*)::integer from public.organization_users
  where id=current_setting('test.member_id')::uuid and is_active),1,
  'Administrator adds an existing verified Auth user with active membership');

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"60000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
select ok(public.is_active_org_member(current_setting('test.org_id')::uuid),
  'new member has active organization membership');
select ok(public.has_org_permission(current_setting('test.org_id')::uuid,'accounts.read'),
  'assigned custom role grants only its configured account-read permission');
select throws_ok(
  format('select public.add_organization_user_by_email(%L::uuid,%L,%L::uuid)',
    current_setting('test.org_id'),'nobody@example.invalid',current_setting('test.role_read')),
  '42501','You are not authorized to manage members in this organization.',
  'least-privilege member cannot add another member');
reset role;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"60000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select lives_ok($$select public.set_organization_user_active(
  current_setting('test.org_id')::uuid,current_setting('test.member_id')::uuid,false)$$,
  'Administrator can deactivate an ordinary member');
reset role;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"60000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
select ok(not public.is_active_org_member(current_setting('test.org_id')::uuid),
  'deactivated member loses active membership');
select ok(not public.has_org_permission(current_setting('test.org_id')::uuid,'accounts.read'),
  'deactivated member loses effective permissions');
select is((select count(*)::integer from public.accounts
  where organization_id=current_setting('test.org_id')::uuid),0,
  'RLS hides tenant accounts from deactivated member');
reset role;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"60000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select lives_ok($$select public.set_organization_user_active(
  current_setting('test.org_id')::uuid,current_setting('test.member_id')::uuid,true)$$,
  'Administrator can reactivate a member with an active role');
select lives_ok($$select public.update_organization_user_role(
  current_setting('test.org_id')::uuid,current_setting('test.member_id')::uuid,
  current_setting('test.role_accounts')::uuid)$$,
  'Administrator can replace an ordinary member role');
reset role;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000002',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"60000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
select ok(not public.has_org_permission(current_setting('test.org_id')::uuid,'reports.read'),
  'replacing role removes permissions not present in the new role');
select ok(public.has_org_permission(current_setting('test.org_id')::uuid,'accounts.read'),
  'replacing role preserves permissions explicitly granted by new role');
reset role;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',true);
select pg_catalog.set_config('request.jwt.claims','{"sub":"60000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
select lives_ok($$select public.set_organization_user_active(
  current_setting('test.org_id')::uuid,current_setting('test.member_id')::uuid,false)$$,
  'Administrator deactivates member before retiring assigned role');
select lives_ok($$select public.update_custom_role(
  current_setting('test.org_id')::uuid,current_setting('test.role_accounts')::uuid,
  'Accounts Read Role','inactive')$$,
  'Administrator can deactivate an unassigned custom role');
select throws_ok(
  format('select public.set_organization_user_active(%L::uuid,%L::uuid,true)',
    current_setting('test.org_id'),current_setting('test.member_id')),
  '23514','A member cannot be reactivated while their assigned role is inactive.',
  'inactive custom role prevents member reactivation');
select throws_ok(
  format('select public.update_organization_user_role(%L::uuid,%L::uuid,%L::uuid)',
    current_setting('test.org_id'),current_setting('test.member_id'),current_setting('test.role_accounts')),
  '23503','The selected role must be active and belong to this organization.',
  'inactive custom role cannot be assigned');
reset role;
select ok(public.is_org_administrator(current_setting('test.org_id')::uuid),
  'original Creator retains permanent Administrator authority');
select throws_ok(
  format('update public.organization_users set is_active=false where organization_id=%L::uuid and created_at=(select created_at from public.organizations where id=%L::uuid)',
    current_setting('test.org_id'),current_setting('test.org_id')),
  '42501','The original creator Administrator membership is permanently immutable.',
  'direct SQL cannot deactivate permanent Creator membership');
select throws_ok(
  format('update public.organization_users set role_id=%L::uuid where organization_id=%L::uuid and created_at=(select created_at from public.organizations where id=%L::uuid)',
    current_setting('test.role_read'),current_setting('test.org_id'),current_setting('test.org_id')),
  '42501','Membership organization, user, and creation timestamp are immutable.',
  'direct SQL cannot reassign Creator membership');
select throws_ok(
  format('update public.roles set status=%L where organization_id=%L::uuid and name=%L',
    'inactive',current_setting('test.org_id'),'Administrator'),
  '42501','The system Administrator role is permanent and immutable.',
  'direct SQL cannot deactivate system Administrator role');
select throws_ok(
  format('delete from public.role_permissions where role_id=(select id from public.roles where organization_id=%L::uuid and name=%L) and permission_id=(select rp.permission_id from public.role_permissions rp where rp.role_id=(select id from public.roles where organization_id=%L::uuid and name=%L) limit 1)',
    current_setting('test.org_id'),'Administrator',current_setting('test.org_id'),'Administrator'),
  '42501','Administrator permissions cannot be removed or reassigned.',
  'direct SQL cannot remove Creator Administrator permissions');

select * from finish();
rollback;
