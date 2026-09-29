// Shared by the Pro endpoints: license checks against Polar and a simple per-key rate limit.

const REQUESTS_PER_MINUTE = 120;
// Per-instance caches: good enough for an MVP on a single region. Move to a shared store
// (e.g. Upstash Redis) before relying on the rate limit for abuse protection.
export const licenseCache = new Map<string, { ok: boolean; until: number }>();
export const rateWindows = new Map<string, { start: number; count: number }>();

export function json(status: number, message: string): Response {
  return new Response(JSON.stringify({ type: "error", error: { type: "opennotch_error", message } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function licenseIsActive(key: string, activationId: string | null): Promise<boolean> {
  const cacheKey = `${key}:${activationId ?? ""}`;
  const cached = licenseCache.get(cacheKey);
  if (cached && cached.until > Date.now()) return cached.ok;

  const body: Record<string, string> = { key, organization_id: process.env.POLAR_ORGANIZATION_ID ?? "" };
  if (activationId) body.activation_id = activationId;
  const res = await fetch("https://api.polar.sh/v1/customer-portal/license-keys/validate", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const ok = res.ok && (await res.json()).status === "granted";
  // Trust a good answer for 10 minutes; recheck a bad one after a minute (e.g. just subscribed).
  licenseCache.set(cacheKey, { ok, until: Date.now() + (ok ? 10 : 1) * 60_000 });
  return ok;
}

export function overRateLimit(key: string): boolean {
  const now = Date.now();
  const w = rateWindows.get(key);
  if (!w || now - w.start > 60_000) {
    rateWindows.set(key, { start: now, count: 1 });
    return false;
  }
  w.count += 1;
  return w.count > REQUESTS_PER_MINUTE;
}

