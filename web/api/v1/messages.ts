// OpenNotch Pro proxy: checks the caller's Polar license, then forwards a narrowly shaped
// request to Claude Haiku with the server's Anthropic key. The app never holds that key.
//
// Env (set in Vercel project settings): ANTHROPIC_API_KEY (workspace-scoped), POLAR_ORGANIZATION_ID
import Anthropic from "@anthropic-ai/sdk";
import { json, licenseIsActive, overRateLimit } from "../../lib/pro.js";

const MODEL = "claude-haiku-4-5";
const MAX_OUTPUT_TOKENS = 1024;
const MAX_REQUEST_CHARS = 60_000;

const client = new Anthropic();

export async function POST(request: Request): Promise<Response> {
  const license = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!license) return json(401, "Missing OpenNotch Pro license key.");

  const raw = await request.text();
  if (raw.length > MAX_REQUEST_CHARS) return json(413, "Request too large.");

  if (!(await licenseIsActive(license, request.headers.get("x-opennotch-activation")))) {
    return json(402, "OpenNotch Pro isn't active for this license key.");
  }
  if (overRateLimit(license)) return json(429, "Too many requests. Try again in a minute.");

  let body: { system?: unknown; messages?: unknown; max_tokens?: unknown };
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, "Invalid JSON.");
  }

  // Accept only what the app sends: a system prompt and a short user turn. Model and limits
  // are fixed here so a license key can't be used as a general-purpose Claude endpoint.
  const messages = Array.isArray(body.messages) ? (body.messages as Anthropic.MessageParam[]).slice(-2) : [];
  if (messages.length === 0) return json(400, "No messages.");

  try {
    const response = await client.messages.create({
      model: MODEL,
      max_tokens: Math.min(Number(body.max_tokens) || 512, MAX_OUTPUT_TOKENS),
      ...(typeof body.system === "string" ? { system: body.system } : {}),
      messages,
    });
    return new Response(JSON.stringify(response), { headers: { "content-type": "application/json" } });
  } catch (error) {
    if (error instanceof Anthropic.RateLimitError) return json(429, "Busy. Try again shortly.");
    if (error instanceof Anthropic.BadRequestError) return json(400, error.message);
    if (error instanceof Anthropic.APIError) return json(502, `Upstream error ${error.status}`);
    return json(502, "Upstream unavailable.");
  }
}
