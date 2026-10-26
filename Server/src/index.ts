import { config, updateConfig, publicConfig } from "./config";
import { equal, fail, HttpError, readBytes } from "./util";
import release from "../../version.json";
import { claimSMS, enqueue, event, limit, now, online } from "./store";
import { voice } from "./voice";
import { cancelForward } from "./forward-cancel";
import { totpAPI } from "./totp";
import { receive } from "./email";
import { listRecordings, recordingAPI, recordingTasks } from "./recordings";
import { notify } from "./gotify";
const json = (v: unknown, status = 200) =>
  Response.json(v, {
    status,
    headers: {
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(new TextDecoder().decode(await readBytes(req, 16384)));
  } catch (e) {
    if (e instanceof HttpError) throw e;
    fail("Invalid JSON");
  }
}
async function edgeAPI(
  req: Request,
  env: Env,
  ctx: ExecutionContext,
  path: string,
) {
  if (
    !equal(req.headers.get("Authorization") || "", "Bearer " + env.EDGE_TOKEN)
  )
    fail("Unauthorized", 401);
  if (path.startsWith("/edge/totp/"))
    return json(
      await totpAPI(
        req,
        env,
        path,
        req.method === "POST" ? await body(req) : {},
      ),
    );
  if (path === "/edge/release" && req.method === "GET")
    return json({
      ...release,
      url: `https://github.com/YumePrincess/yume-simhub/releases/tag/v${release.version}-build.${release.build}`,
    });
  if (path.startsWith("/edge/recordings/"))
    return recordingAPI(req, env, ctx, path);
  if (path === "/edge/recordings" && req.method === "GET")
    return json(
      await listRecordings(
        env,
        new URL(req.url).searchParams.get("before") || undefined,
      ),
    );
  if (path === "/edge/state" && req.method === "GET") {
    const [c, e, jobs, events] = await Promise.all([
      config(env),
      online(env),
      env.DB.prepare(
        "SELECT id,kind,payload,status,created,updated,result FROM jobs ORDER BY created DESC LIMIT 30",
      ).all(),
      env.DB.prepare(
        "SELECT id,kind,payload,created,notified,attempts,last_error AS result FROM events WHERE kind='sms.received' ORDER BY created DESC LIMIT 30",
      ).all(),
    ]);
    return json({
      settings: publicConfig(c),
      edge: e,
      jobs: jobs.results,
      events: events.results,
    });
  }
  if (path === "/edge/settings" && req.method === "PUT")
    return json(
      publicConfig(await updateConfig(env, await config(env), await body(req))),
    );
  if (path === "/edge/notify-test" && req.method === "POST") {
    const id = "test-" + crypto.randomUUID();
    await event(env, id, "system.test", {});
    await notify(env);
    const row = await env.DB.prepare(
      "SELECT notified,last_error FROM events WHERE id=?",
    )
      .bind(id)
      .first<{ notified: number; last_error: string }>();
    return json({
      delivered: row?.notified === 1,
      error: row?.last_error || "",
    });
  }
  if (path === "/edge/notify-retry" && req.method === "POST") {
    await env.DB.prepare(
      "UPDATE events SET notified=0,attempts=0 WHERE kind='sms.received' AND notified<>1",
    ).run();
    ctx.waitUntil(notify(env));
    return json({ ok: true });
  }
  if (req.method !== "POST") fail("Method not allowed", 405);
  const v = await body(req);
  if (path === "/edge/sync") {
    const status = {
      modemConnected: v.modemConnected === true,
      sim: String(v.sim || "unknown"),
      operator: String(v.operator || ""),
      registration: String(v.registration || "unknown"),
      signal: v.signal,
      voiceReady: v.voiceReady === true,
      sipRegistered: v.sipRegistered === true,
      busy: v.busy === true,
      version: String(v.version || ""),
    };
    await env.DB.prepare(
      "INSERT INTO edge(id,value,updated) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value,updated=excluded.updated",
    )
      .bind(JSON.stringify(status), now())
      .run();
    const c = await config(env);
    return json({
      job: status.modemConnected ? await claimSMS(env) : null,
      sip: { domain: c.sipDomain, user: c.sipUser, password: c.sipPassword },
      inboundEnabled: c.inboundEnabled,
      outboundEnabled: c.outboundEnabled,
    });
  }
  if (path === "/edge/result") {
    if (
      typeof v.id !== "string" ||
      !["sent", "failed", "unknown"].includes(String(v.status))
    )
      fail("Invalid result");
    await env.DB.prepare(
      "UPDATE jobs SET status=?,result=?,updated=? WHERE id=? AND kind='sms' AND status IN ('running','unknown')",
    )
      .bind(v.status, String(v.result || "").slice(0, 200), now(), v.id)
      .run();
    return json({ ok: true });
  }
  if (path === "/edge/sms") {
    if (
      typeof v.id !== "string" ||
      typeof v.from !== "string" ||
      typeof v.body !== "string" ||
      v.body.length > 4096
    )
      fail("Invalid SMS");
    await event(env, "sms-" + v.id, "sms.received", {
      from: v.from.slice(0, 64),
      body: v.body,
    });
    ctx.waitUntil(notify(env));
    return json({ ok: true });
  }
  if (path === "/edge/incoming") {
    const c = await config(env);
    if (!c.inboundEnabled) fail("Inbound forwarding disabled", 409);
    await limit(env, "incoming", 30, 3600);
    const id = crypto.randomUUID();
    await enqueue(env, id, "incoming", {
      from: String(v.from || "unknown"),
      answerMode: c.incomingAnswerMode,
    });
    await event(env, "call-" + id, "call.incoming", {
      from: String(v.from || "unknown"),
      via: env.TWILIO_NUMBER,
      to: c.forwardTo,
    });
    ctx.waitUntil(notify(env));
    return json({ id, answerMode: c.incomingAnswerMode });
  }
  if (path === "/edge/incoming-ready") {
    if (typeof v.id !== "string") fail("Invalid ticket");
    const row = await env.DB.prepare(
      "SELECT s.state,s.finished,s.expires,s.child_sid FROM jobs j JOIN forward_screens s ON s.parent_sid=json_extract(j.payload,'$.callSid') WHERE j.id=? AND j.kind='incoming' AND j.status='running' AND json_extract(j.payload,'$.answerMode')='confirmed'",
    )
      .bind(v.id)
      .first<{
        state: string;
        finished: number;
        expires: number;
        child_sid: string | null;
      }>();
    return json({
      accepted:
        !!row &&
        row.state === "accepted" &&
        !row.finished &&
        row.expires > now() &&
        !!row.child_sid,
    });
  }
  if (path === "/edge/authorize") {
    if (typeof v.id !== "string") fail("Invalid ticket");
    const c = await config(env);
    if (!c.outboundEnabled) fail("Dialing disabled", 409);
    const job = await env.DB.prepare(
      "UPDATE jobs SET status='claimed',updated=? WHERE id=? AND kind='dial' AND status='queued' AND created>? RETURNING payload",
    )
      .bind(now(), v.id, now() - 60000)
      .first<{ payload: string }>();
    if (!job) fail("Call authorization expired", 403);
    const authorized = JSON.parse(job.payload);
    if ((authorized.authGeneration || "") !== c.authGeneration)
      fail("Call authorization expired", 403);
    return json(authorized);
  }
  if (path === "/edge/call-event") {
    if (
      typeof v.id !== "string" ||
      !["connected", "ended", "failed"].includes(String(v.status))
    )
      fail("Invalid call event");
    await env.DB.prepare(
      "UPDATE jobs SET status=?,result=?,updated=? WHERE id=? AND kind IN ('dial','incoming')",
    )
      .bind(v.status, String(v.result || "").slice(0, 200), now(), v.id)
      .run();
    if (v.status === "failed" || v.status === "ended")
      await cancelForward(env, v.id);
    return json({ ok: true });
  }
  return json({ error: "Not found" }, 404);
}
export default {
  async fetch(req, env, ctx) {
    try {
      const u = new URL(req.url);
      const path = u.pathname;
      if (u.origin !== env.PUBLIC_ORIGIN) fail("Invalid origin", 400);
      if (path.startsWith("/twilio/")) {
        if (req.method !== "POST") fail("Method not allowed", 405);
        return await voice(req, env, ctx);
      }
      if (path.startsWith("/edge/")) return await edgeAPI(req, env, ctx, path);
      const res = await env.ASSETS.fetch(
        new Request(
          env.PUBLIC_ORIGIN +
            (path.startsWith("/css/") || path.startsWith("/js/")
              ? path
              : "/index.html"),
        ),
      );
      const h = new Headers(res.headers);
      h.set("Cache-Control", "private, no-store");
      h.set("X-Content-Type-Options", "nosniff");
      h.set("Referrer-Policy", "no-referrer");
      h.set(
        "Content-Security-Policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
      );
      return new Response(res.body, {
        status:
          path.startsWith("/css/") || path.startsWith("/js/")
            ? res.status
            : 500,
        headers: h,
      });
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error(
        JSON.stringify({
          event: "request.failed",
          type: e instanceof Error ? e.name : "unknown",
        }),
      );
      return json({ error: "服务暂时不可用" }, 500);
    }
  },
  email: receive,
  async scheduled(_controller, env, _ctx) {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM sessions WHERE expires<?").bind(now()),
      env.DB.prepare("DELETE FROM forward_screens WHERE updated<?").bind(
        now() - 10800000,
      ),
      env.DB.prepare("DELETE FROM totp_enrollment WHERE expires<?").bind(now()),
      env.DB.prepare("DELETE FROM limits WHERE expires<?").bind(now()),
      env.DB.prepare(
        "UPDATE jobs SET status='expired',updated=? WHERE kind IN ('dial','incoming') AND status='queued' AND created<?",
      ).bind(now(), now() - 60000),
      env.DB.prepare(
        "UPDATE events SET notified=0 WHERE notified=2 AND delivery_updated<?",
      ).bind(now() - 300000),
    ]);
    await Promise.all([notify(env), recordingTasks(env)]);
  },
} satisfies ExportedHandler<Env>;
