import { fail } from "./util";
export const now = () => Date.now();
export async function limit(
  env: Env,
  id: string,
  max: number,
  seconds: number,
) {
  const bucket = Math.floor(now() / (seconds * 1000));
  const row = await env.DB.prepare(
    "INSERT INTO limits(id,count,expires) VALUES(?,1,?) ON CONFLICT(id) DO UPDATE SET count=count+1 RETURNING count",
  )
    .bind(`${id}:${bucket}`, now() + seconds * 2000)
    .first<{ count: number }>();
  if (!row || row.count > max) fail("请求过于频繁", 429);
}
export async function event(
  env: Env,
  id: string,
  kind: string,
  payload: unknown,
) {
  await env.DB.prepare(
    "INSERT OR IGNORE INTO events(id,kind,payload,created) VALUES(?,?,?,?)",
  )
    .bind(id, kind, JSON.stringify(payload), now())
    .run();
}
export async function enqueue(
  env: Env,
  id: string,
  kind: string,
  payload: unknown,
) {
  await env.DB.prepare(
    "INSERT OR IGNORE INTO jobs(id,kind,payload,created,updated) VALUES(?,?,?,?,?)",
  )
    .bind(id, kind, JSON.stringify(payload), now(), now())
    .run();
  return id;
}
export async function online(env: Env) {
  const e = await env.DB.prepare(
    "SELECT value,updated FROM edge WHERE id=1",
  ).first<{ value: string; updated: number }>();
  if (!e)
    return {
      online: false,
      serviceOnline: false,
      voiceReady: false,
      sipRegistered: false,
      busy: false,
    };
  const value = JSON.parse(e.value);
  const fresh = now() - e.updated < 15000;
  const connected = fresh && value.modemConnected === true;
  return {
    ...value,
    lastSeen: e.updated,
    serviceOnline: fresh,
    online: connected,
    voiceReady: connected && value.voiceReady === true,
    sipRegistered: fresh && value.sipRegistered === true,
    busy: connected && value.busy === true,
  };
}
export async function claimSMS(env: Env) {
  await env.DB.prepare(
    "UPDATE jobs SET status='unknown',result='Mac disconnected after claim; review before retry',updated=? WHERE kind='sms' AND status='running' AND updated<?",
  )
    .bind(now(), now() - 300000)
    .run();
  return env.DB.prepare(
    "UPDATE jobs SET status='running',updated=? WHERE id=(SELECT id FROM jobs WHERE kind='sms' AND status='queued' ORDER BY created LIMIT 1) AND status='queued' RETURNING id,payload",
  )
    .bind(now())
    .first();
}
