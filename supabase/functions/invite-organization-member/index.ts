import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("INVITE_CORS_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

type InviteBody = {
  organization_id?: unknown;
  role_id?: unknown;
  email?: unknown;
};

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json(405, { error: "Method not allowed." });

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return json(401, { error: "A valid user access token is required." });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json(500, { error: "The invitation service is not configured." });
  }

  let body: InviteBody;
  try {
    body = await request.json() as InviteBody;
  } catch {
    return json(400, { error: "Request body must be valid JSON." });
  }

  const organizationId = typeof body.organization_id === "string"
    ? body.organization_id.trim()
    : "";
  const roleId = typeof body.role_id === "string" ? body.role_id.trim() : "";
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";

  if (!uuidPattern.test(organizationId) || !uuidPattern.test(roleId)) {
    return json(400, { error: "Valid organization_id and role_id UUIDs are required." });
  }
  if (email.length > 254 || !emailPattern.test(email)) {
    return json(400, { error: "A valid email address is required." });
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userResult, error: userError } = await callerClient.auth.getUser();
  const inviter = userResult.user;
  if (userError || !inviter) {
    return json(401, { error: "The access token is invalid or expired." });
  }

  // Preflight under the caller's JWT. The database revalidates the inviter and
  // target role atomically when the invited Auth user is attached to the tenant.
  const { error: permissionError } = await callerClient.rpc("validate_role_assignment", {
    p_organization_id: organizationId,
    p_role_id: roleId,
  });
  if (permissionError) {
    const status = permissionError.code === "42501" ? 403 : 400;
    return json(status, { error: permissionError.message });
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Existing verified Auth users are added through the caller-scoped RPC;
  // only an unknown/unverified email proceeds to the Auth Admin invitation path.
  const { data: existingMembershipId, error: addExistingError } = await callerClient.rpc(
    "add_organization_user_by_email",
    {
      p_organization_id: organizationId,
      p_email: email,
      p_role_id: roleId,
    },
  );

  if (!addExistingError) {
    return json(201, {
      membership_id: existingMembershipId,
      invited: false,
      message: "Existing verified Auth user added to the organization.",
    });
  }

  if (addExistingError.code !== "P0002") {
    const status = addExistingError.code === "23505" ? 409
      : addExistingError.code === "42501" ? 403
      : 400;
    return json(status, { error: addExistingError.message });
  }

  const redirectTo = Deno.env.get("INVITE_REDIRECT_URL");
  const { data: inviteResult, error: inviteError } = await adminClient.auth.admin
    .inviteUserByEmail(email, {
      data: {
        invited_organization_id: organizationId,
        invited_role_id: roleId,
        invited_by: inviter.id,
      },
      ...(redirectTo ? { redirectTo } : {}),
    });

  if (inviteError || !inviteResult.user?.id) {
    const message = inviteError?.message.toLowerCase() ?? "";
    if (message.includes("already") || message.includes("registered") || message.includes("exists")) {
      return json(409, {
        error: "An Auth account already exists for this email but is not yet available as a verified member. Complete its email verification, then retry the invitation.",
      });
    }
    return json(502, { error: "Supabase Auth could not send the invitation." });
  }

  // This RPC is executable only by service_role. It rechecks the inviter's
  // users.manage permission and the role-permission subset under an organization
  // lock before creating the membership.
  const { data: membershipId, error: completionError } = await adminClient.rpc(
    "complete_organization_invitation",
    {
      p_organization_id: organizationId,
      p_user_id: inviteResult.user.id,
      p_role_id: roleId,
      p_inviter_user_id: inviter.id,
    },
  );

  if (completionError || !membershipId) {
    // Keep the Auth invitation so a transient database failure can be reconciled
    // by an administrator; never expose service-role or database error details.
    return json(502, {
      error: "The invitation email was sent, but organization membership could not be finalized. Retry or reconcile the pending invitation.",
      invitation_sent: true,
    });
  }

  return json(201, {
    membership_id: membershipId,
    invited: true,
    message: "Invitation sent and organization membership created.",
  });
});
