import { recordingTicket } from "./recording-ticket";
import { archive, audio, Recording } from "./recording-crypto";
import { config } from "./config";
import { now } from "./store";
import { fail } from "./util";
export async function recordingCallback(env: Env, f: Record<string, string>) {
  if (
    !/^RE[a-f0-9]{32}$/.test(f.RecordingSid || "") ||
    !/^CA[a-f0-9]{32}$/.test(f.CallSid || "")
  )
    fail("Invalid recording", 400);
  if (f.RecordingStatus !== "completed") return;
  const job = await env.DB.prepare(
    "SELECT kind,payload FROM jobs WHERE kind IN ('incoming','dial') AND json_extract(payload,'$.callSid')=? ORDER BY created DESC LIMIT 1",
  )
    .bind(f.CallSid)
    .first<{ kind: string; payload: string }>();
  const details = job ? JSON.parse(job.payload) : {};
  const r: Recording = {
    sid: f.RecordingSid,
    direction:
      job?.kind === "incoming"
        ? "inbound"
        : job?.kind === "dial"
          ? "outbound"
          : undefined,
    peer: job?.kind === "incoming" ? details.from : details.to,
    target: details.to,
    call: f.CallSid,
    conference: "",
    duration: Math.max(0, Number(f.RecordingDuration) || 0),
    status: "pending",
    key: "",
    size: 0,
    iv: "",
    sha256: "",
    created: now(),
    error: "",
    twilioDeleted: false,
  };
  await env.DB.prepare(
    "INSERT OR IGNORE INTO recordings(sid,value,status,updated) VALUES(?,?,'pending',?)",
  )
    .bind(r.sid, JSON.stringify(r), now())
    .run();
}
async function removeTwilioOnce(env: Env, sid: string) {
  const c = await config(env);
  const r = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Recordings/${sid}.json`,
    {
      method: "DELETE",
      headers: {
        Authorization:
          "Basic " + btoa(env.TWILIO_ACCOUNT_SID + ":" + c.twilioToken),
      },
      signal: AbortSignal.timeout(5000),
    },
  );
  await r.body?.cancel();
  if (r.status !== 404 && !r.ok) throw Error("Twilio recording delete failed: "+r.status);
}
async function removeTwilio(env: Env, sid: string) {
  try { await removeTwilioOnce(env,sid); }
  catch { await removeTwilioOnce(env,sid); }
}
export async function recordingTasks(env: Env, onlySid?: string) {
  // Durable lease prevents concurrent callbacks/cron from archiving the same source.
  const rows = await env.DB.prepare(
    "SELECT sid FROM recordings WHERE (status IN ('pending','purge','deleting') OR (status='archiving' AND updated<?)) AND (? IS NULL OR sid=?) ORDER BY updated LIMIT 3",
  )
    .bind(now() - 600000, onlySid || null, onlySid || null)
    .all<{ sid: string }>();
  for (const item of rows.results) {
    const lease = crypto.randomUUID();
    const row = await env.DB.prepare(
      "UPDATE recordings SET lease=?,updated=?,attempts=attempts+1,status=CASE WHEN status IN ('pending','archiving') THEN 'archiving' ELSE status END WHERE sid=? AND (lease IS NULL OR updated<? OR (status IN ('purge','deleting') AND updated<?)) AND status IN ('pending','archiving','purge','deleting') RETURNING value,status",
    )
      .bind(lease, now(), item.sid, now() - 600000, now() - 30000)
      .first<{ value: string; status: string }>();
    if (!row) continue;
    let rec = JSON.parse(row.value) as Recording;
    try {
      if (row.status === "deleting") {
        // Keep the tombstone and lease until both storage backends confirm deletion.
        await removeTwilio(env, rec.sid);
        if (rec.key) {
          if (!rec.key.startsWith("simhub/recordings/"))
            throw Error("Invalid R2 prefix");
          await env.RECORDINGS.delete(rec.key);
        }
        await env.DB.prepare(
          "UPDATE recordings SET status='deleted',lease=NULL,updated=? WHERE sid=? AND lease=?",
        )
          .bind(now(), rec.sid, lease)
          .run();
        continue;
      }
      if (row.status === "archiving") {
        rec = await archive(env, rec);
        const saved = await env.DB.prepare(
          "UPDATE recordings SET value=?,status='purge',updated=? WHERE sid=? AND status='archiving' AND lease=? RETURNING sid",
        )
          .bind(JSON.stringify(rec), now(), rec.sid, lease)
          .first();
        if (!saved) {
          await env.RECORDINGS.delete(rec.key);
          continue;
        }
      }
      await removeTwilio(env, rec.sid);
      rec.twilioDeleted = true;
      await env.DB.prepare(
        "UPDATE recordings SET value=?,status='archived',lease=NULL,updated=? WHERE sid=? AND status='purge' AND lease=?",
      )
        .bind(JSON.stringify(rec), now(), rec.sid, lease)
        .run();
    } catch {
      console.warn(JSON.stringify({event:"recording.retry.pending",stage:row.status}));
      // After successful verification, retain the purge stage even if Twilio deletion fails.
      await env.DB.prepare(
        "UPDATE recordings SET lease=NULL,status=CASE WHEN status='archiving' THEN 'pending' ELSE status END,updated=? WHERE sid=? AND lease=?",
      )
        .bind(now(), rec.sid, lease)
        .run();
    }
  }
}
export async function listRecordings(env: Env, before?: string) {
  const cursor = before ? Number(before) : now() + 1;
  if (!Number.isFinite(cursor)) fail("Invalid cursor");
  const rows = await env.DB.prepare(
    "SELECT value,status,attempts FROM recordings WHERE status<>'deleted' AND json_extract(value,'$.created')<? ORDER BY json_extract(value,'$.created') DESC LIMIT 30",
  )
    .bind(cursor)
    .all<{ value: string; status: string; attempts: number }>();
  return rows.results.map((r) => {
    const v = JSON.parse(r.value) as Recording;
    return {
      sid: v.sid,
      direction: v.direction,
      peer: v.peer,
      target: v.target,
      call: v.call,
      duration: v.duration,
      created: v.created,
      size: v.size,
      status: r.status,
      attempts: r.attempts,
      twilioDeleted: v.twilioDeleted,
    };
  });
}
export async function recordingAPI(
  req: Request,
  env: Env,
  ctx: ExecutionContext,
  path: string,
) {
  const m = path.match(
    /^\/edge\/recordings\/(RE[a-f0-9]{32})(?:\/(audio|retry|ticket))?$/,
  );
  if (!m) fail("Not found", 404);
  const row = await env.DB.prepare(
    "SELECT value,status FROM recordings WHERE sid=? AND status<>'deleted'",
  )
    .bind(m[1])
    .first<{ value: string; status: string }>();
  if (!row) fail("Not found", 404);
  const rec = JSON.parse(row.value) as Recording;
  if (req.method === "POST" && m[2] === "ticket") {
    if (!["archived","purge"].includes(row.status)) fail("Recording not archived yet",409);
    return Response.json(await recordingTicket(env,m[1]));
  }
  if (req.method === "GET" && m[2] === "audio") {
    if (!["archived", "purge"].includes(row.status))
      fail("Recording not archived yet", 409);
    return audio(req, env, rec);
  }
  if (req.method === "POST" && m[2] === "retry") {
    await env.DB.prepare("UPDATE recordings SET attempts=0 WHERE sid=?")
      .bind(m[1])
      .run();
    ctx.waitUntil(recordingTasks(env,m[1]));
    return Response.json({ ok: true });
  }
  if (req.method === "DELETE" && !m[2]) {
    await env.DB.prepare(
      "UPDATE recordings SET status='deleting',attempts=0 WHERE sid=?",
    )
      .bind(m[1])
      .run();
    ctx.waitUntil(recordingTasks(env,m[1]));
    return Response.json({ ok: true });
  }
  fail("Method not allowed", 405);
}
