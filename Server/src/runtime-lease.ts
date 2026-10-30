import { fail } from "./util";
import { now, online } from "./store";
const TTL = 90000;
const GRACE = 15000;
type Lease = { owner: string; session: string; epoch: number; expires: number; desired: string };
const identifier = (v: unknown) => {
  if (typeof v !== "string" || !/^[a-zA-Z0-9-]{16,80}$/.test(v)) fail("Invalid device identity");
  return v as string;
};
export async function runtimeState(env: Env) {
  const lease = await env.DB.prepare("SELECT owner,epoch,expires,desired FROM runtime_lease WHERE id=1").first<Omit<Lease,"session">>();
  const devices = await env.DB.prepare("SELECT id,platform,label,last_seen FROM runtime_devices ORDER BY last_seen DESC LIMIT 32").all();
  return { lease, devices: devices.results };
}
export async function runtimeAPI(env: Env, path: string, v: Record<string, unknown>) {
  if (path === "/edge/runtime/select") {
    const target = identifier(v.device);
    if (!await env.DB.prepare("SELECT id FROM runtime_devices WHERE id=?").bind(target).first()) fail("Unknown device");
    if ((await online(env)).busy) fail("Finish the active call before switching", 409);
    await env.DB.prepare("UPDATE runtime_lease SET desired=? WHERE id=1").bind(target).run();
    return { ok: true };
  }
  if ((path.endsWith("/acquire") || path.endsWith("/renew")) && v.protocolVersion!==2) fail("Update runtime client protocol",409);
  const device = identifier(v.device);
  const session = identifier(v.session);
  const t = now();
  if (path === "/edge/runtime/acquire") {
    if (v.platform !== "macos" && v.platform !== "openwrt") fail("Invalid platform");
    await env.DB.prepare("INSERT INTO runtime_devices(id,platform,label,last_seen) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET label=excluded.label,last_seen=excluded.last_seen")
      .bind(device,v.platform,String(v.label || v.platform).slice(0,64),t).run();
    // Only an expired, fully drained owner may be replaced. Retried acquisition
    // with the same session is idempotent, but cannot resurrect an expired lease.
    const row = await env.DB.prepare("UPDATE runtime_lease SET owner=?,session=?,epoch=CASE WHEN owner=? AND session=? AND expires>? THEN epoch ELSE epoch+1 END,expires=? WHERE id=1 AND (desired='' OR desired=?) AND ((owner=? AND session=? AND expires>?) OR expires+?<=?) RETURNING epoch")
      .bind(device,session,device,session,t,t+TTL,device,device,session,t,GRACE,t).first<{epoch:number}>();
    if (!row) fail("Another device owns the runtime; waiting for release",409);
    return { epoch: row.epoch, ttlSeconds: 90, protocolVersion:2 };
  }
  if (!Number.isSafeInteger(v.epoch)) fail("Invalid lease epoch");
  if (path === "/edge/runtime/renew") {
    const row = await env.DB.prepare("UPDATE runtime_lease SET expires=? WHERE id=1 AND owner=? AND session=? AND epoch=? AND expires>? AND (desired='' OR desired=owner OR ?=1) RETURNING epoch")
      .bind(t+TTL,device,session,v.epoch,t,v.busy===true?1:0).first();
    if (!row) fail("Runtime lease revoked or expired",409);
    return { ttlSeconds:90 };
  }
  if (path === "/edge/runtime/release") {
    // Keep a drain grace period for in-flight cloud operations.
    await env.DB.prepare("UPDATE runtime_lease SET owner='',session='',expires=? WHERE id=1 AND owner=? AND session=? AND epoch=?")
      .bind(t,device,session,v.epoch).run();
    return { ok:true };
  }
  fail("Unknown runtime operation",404);
}
export async function requireRuntime(req: Request, env: Env) {
  const row = await env.DB.prepare("SELECT owner FROM runtime_lease WHERE id=1 AND owner=? AND session=? AND epoch=? AND expires>?")
    .bind(req.headers.get("X-SimHub-Device") || "",req.headers.get("X-SimHub-Session") || "",Number(req.headers.get("X-SimHub-Epoch") || 0),now()).first();
  if (!row) fail("Active runtime lease required; update the client",409);
}
