# Organization member invitations

The trusted invitation endpoint is implemented at:

`supabase/functions/invite-organization-member/index.ts`

## Deployment

Deploy it with the Supabase CLI:

```sh
supabase functions deploy invite-organization-member
```

Configure these Edge Function secrets:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` (or `SUPABASE_PUBLISHABLE_KEY`)
- `SUPABASE_SERVICE_ROLE_KEY`
- `INVITE_REDIRECT_URL` (optional; must be in the Supabase Auth redirect allow-list)
- `INVITE_CORS_ORIGIN` (recommended in production; set to the exact application origin)

Never expose `SUPABASE_SERVICE_ROLE_KEY` to a browser, mobile client, or public repository.

## Request

Send an authenticated POST request with the caller's Supabase access token:

```json
{
  "organization_id": "organization UUID",
  "role_id": "active role UUID",
  "email": "new.member@example.com"
}
```

The caller must be an active organization member with `users.manage`. The requested role may contain only permissions the caller currently holds.

## Execution model

1. The function validates the caller with Supabase Auth `getUser()`.
2. The caller-scoped `validate_role_assignment` RPC checks membership, permission and role scope.
3. A verified existing Auth user is added through `add_organization_user_by_email`.
4. Otherwise Supabase Auth Admin sends an invitation email.
5. The service-role-only `complete_organization_invitation` RPC rechecks the inviter and role permissions under an organization lock before inserting membership.

The invitation finalization RPC is revoked from `public`, `anon`, and `authenticated`; the bootstrap grants it to `service_role` only when that role exists in the target Supabase project.

## Operational notes

- Configure the redirect URL in Supabase Auth before production use.
- Set `INVITE_CORS_ORIGIN` to the exact frontend origin in production; the wildcard default is intended only for development.
- If an Auth invitation is sent but membership finalization fails, the endpoint returns `invitation_sent: true`. Reconcile the pending invitation before retrying.
- An existing unverified Auth account may need to complete email verification before it can be added through the existing-user path.
- This function is source-controlled but is not deployed to a Supabase project by the PostgreSQL CI workflow. Validate it in a staging Supabase project before production deployment.
