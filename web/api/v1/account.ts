// Links a signed-in OpenNotch account to its Pro license. The app sends its account access token;
// we look the account's (verified) email up in Polar and return the license key it bought, so Pro
// turns on without anyone pasting a key.
//
// Env: POLAR_ACCESS_TOKEN (organization token: customers:read, license_keys:read), POLAR_ORGANIZATION_ID
import { accountFromToken, licenseKeyFor } from "../../lib/account.js";
import { json, overRateLimit } from "../../lib/pro.js";

export async function GET(request: Request): Promise<Response> {
  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!token) return json(401, "Sign in first.");

  const user = await accountFromToken(token);
  if (!user) return json(401, "Your session expired. Sign in again.");
  if (overRateLimit(`account:${user.id}`)) return json(429, "Too many requests. Try again in a minute.");

  try {
    return Response.json({ email: user.email, licenseKey: await licenseKeyFor(user.email) });
  } catch (error) {
    console.error(error);
    return json(502, "Couldn't reach the license server.");
  }
}
