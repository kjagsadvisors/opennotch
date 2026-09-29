// OpenNotch Pro: Jev decisions for license holders. Checks the Polar license, then forwards the
// TypeSafe-shaped request to Jev through Vercel AI Gateway with the server's gateway key.
//
// Env: AI_GATEWAY_API_KEY, POLAR_ORGANIZATION_ID
import { json, licenseIsActive, overRateLimit } from "../../lib/pro.js";

const GATEWAY = "https://ai-gateway.vercel.sh/typesafe/v1/systemone";
const MAX_REQUEST_CHARS = 200_000; // ~64k tokens, Jev's own limit
const MAX_QUESTIONS = 12;

export async function POST(request: Request): Promise<Response> {
  const license = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!license) return json(401, "Missing OpenNotch Pro license key.");

  const raw = await request.text();
  if (raw.length > MAX_REQUEST_CHARS) return json(413, "Request too large.");

  if (!(await licenseIsActive(license, request.headers.get("x-opennotch-activation")))) {
    return json(402, "OpenNotch Pro isn't active for this license key.");
  }
  if (overRateLimit(`decide:${license}`)) return json(429, "Too many requests. Try again in a minute.");

  let body: { state?: unknown; questions?: Record<string, unknown> };
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, "Invalid JSON.");
  }
  if (typeof body.state !== "string" || !body.questions || typeof body.questions !== "object") return json(400, "Expected state and questions.");
  if (Object.keys(body.questions).length > MAX_QUESTIONS) return json(400, "Too many questions.");

  // The model is pinned here; decisions only, so nothing generative can be run through this route.
  const upstream = await fetch(GATEWAY, {
    method: "POST",
    headers: { authorization: `Bearer ${process.env.AI_GATEWAY_API_KEY ?? ""}`, "content-type": "application/json" },
    body: JSON.stringify({ model: "typesafe-ai/jev", state: body.state, questions: body.questions }),
  });
  return new Response(upstream.body, { status: upstream.status, headers: { "content-type": "application/json" } });
}
