// Is each server dependency configured and reachable? Answers true/false only; never echoes keys.
export async function GET(): Promise<Response> {
  const ok = async (url: string, headers: Record<string, string>) => {
    try {
      return (await fetch(url, { headers, signal: AbortSignal.timeout(5000) })).ok;
    } catch {
      return false;
    }
  };
  const polarToken = (process.env.POLAR_ACCESS_TOKEN ?? "").trim();
  const org = encodeURIComponent(process.env.POLAR_ORGANIZATION_ID ?? "");
  const [polar, anthropic] = await Promise.all([
    polarToken ? ok(`https://api.polar.sh/v1/customers/?organization_id=${org}&limit=1`, { authorization: `Bearer ${polarToken}` }) : false,
    process.env.ANTHROPIC_API_KEY
      ? ok("https://api.anthropic.com/v1/models?limit=1", { "x-api-key": process.env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" })
      : false,
  ]);
  return Response.json({ polar, anthropic, aiGateway: Boolean(process.env.AI_GATEWAY_API_KEY) });
}
