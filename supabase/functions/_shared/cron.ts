// Cron auth for pg_cron → Edge Function calls (x-cron-secret header).
//
// The expected secret is the CRON_SECRET env var and/or the Vault secret
// boltpay_cron_secret (the same one pg_cron sends), read through the
// service-role-only RPC system_cron_secret (migration 0075). Function
// secrets cannot always be set on this project, so Vault is the fallback;
// a header matching either is accepted. Compared in constant time; values
// are never logged. The Vault value is cached per isolate (a miss retries
// after a minute). Fails closed when neither is available.

type RpcClient = { rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }> };

let cache: { v: string; at: number } | null = null;
const MISS_TTL_MS = 60_000;

export function resetCronSecretCache() {
  cache = null;
}

/** Constant-time string equality (length leak only). */
export function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  const n = Math.max(ea.length, eb.length);
  for (let i = 0; i < n; i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

async function vaultCronSecret(db: RpcClient): Promise<string> {
  if (cache && (cache.v || Date.now() - cache.at < MISS_TTL_MS)) return cache.v;
  let v = "";
  try {
    const { data, error } = await db.rpc("system_cron_secret");
    if (!error && typeof data === "string") v = data.trim();
    else if (error) console.error("cron secret: vault rpc failed");
  } catch {
    console.error("cron secret: vault rpc threw");
  }
  cache = { v, at: Date.now() };
  return v;
}

export async function cronAuthorized(
  req: Request,
  db: RpcClient,
  get: (k: string) => string | undefined = (k) => Deno.env.get(k),
): Promise<boolean> {
  const got = req.headers.get("x-cron-secret") ?? "";
  if (!got) return false;
  const env = (get("CRON_SECRET") ?? "").trim();
  if (env && timingSafeEqual(got, env)) return true;
  const vault = await vaultCronSecret(db);
  return !!vault && timingSafeEqual(got, vault);
}
