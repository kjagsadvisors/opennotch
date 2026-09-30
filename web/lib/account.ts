// OpenNotch accounts (Supabase Auth) and the Pro license each account bought (Polar).

// Public by design: the project URL and publishable key ship in the app too.
const SUPABASE_URL = process.env.SUPABASE_URL ?? "https://nclsnaetdkgtimtvxvho.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = process.env.SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_zArUVkWF7INkpor1v6i6Aw_D9xDFbhv";
const POLAR_API = "https://api.polar.sh/v1";

export type AccountUser = { id: string; email: string };

const userCache = new Map<string, { user: AccountUser | null; until: number }>();

/** The signed-in user behind an access token, or null. Only verified emails count. */
export async function accountFromToken(token: string): Promise<AccountUser | null> {
  const cached = userCache.get(token);
  if (cached && cached.until > Date.now()) return cached.user;

  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, authorization: `Bearer ${token}` },
  });
  let user: AccountUser | null = null;
  if (res.ok) {
    const u = await res.json();
    // An unconfirmed email could be anyone's; never hand it a license.
    if (u?.id && u?.email && u?.email_confirmed_at) user = { id: u.id, email: String(u.email).toLowerCase() };
  }
  userCache.set(token, { user, until: Date.now() + 5 * 60_000 });
  return user;
}

async function polar(path: string): Promise<any> {
  const res = await fetch(`${POLAR_API}${path}`, {
    headers: { authorization: `Bearer ${(process.env.POLAR_ACCESS_TOKEN ?? "").trim()}` },
  });
  if (!res.ok) throw new Error(`Polar ${path.split("?")[0]} returned ${res.status}`);
  return res.json();
}

/** The granted license key a customer with this email holds, if any. */
export async function licenseKeyFor(email: string): Promise<string | null> {
  if (!process.env.POLAR_ACCESS_TOKEN) return null;
  const org = encodeURIComponent(process.env.POLAR_ORGANIZATION_ID ?? "");
  const customers = await polar(`/customers/?organization_id=${org}&email=${encodeURIComponent(email)}&limit=10`);
  for (const customer of customers.items ?? []) {
    const state = await polar(`/customers/${customer.id}/state`);
    for (const grant of state.granted_benefits ?? []) {
      const id = grant.benefit_type === "license_keys" ? grant.properties?.license_key_id : null;
      if (!id) continue;
      const key = await polar(`/license-keys/${id}`);
      if (key.status === "granted" && typeof key.key === "string") return key.key;
    }
  }
  return null;
}
