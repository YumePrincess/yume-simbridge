import { prompt, speech, type Prompt } from "./languages";
import { recordingCallback, recordingTasks } from "./recordings";
import { config, hashPin, cellularNumber } from "./config";
import { signedWebhook, response, xml, equal, fail } from "./util";
import { enqueue, limit, now, online } from "./store";
export async function voice(req: Request, env: Env, ctx: ExecutionContext) {
  const c = await config(env);
  const lang = c.serviceLanguage;
  const say = (key: Prompt) =>
    `<Say voice="${speech[lang].voice}" language="${speech[lang].locale}">${xml(prompt(lang, key))}</Say>`;
  const hang = (key: Prompt) => response(say(key) + "<Hangup/>");
  const gather = (step: string, key: Prompt) =>
    response(
      `<Gather input="dtmf" timeout="10" finishOnKey="#" action="/twilio/${step}" method="POST">${say(key)}</Gather><Hangup/>`,
    );
  if (!c.twilioToken) return new Response("Not configured", { status: 503 });
  const fields = Object.fromEntries(new URLSearchParams(await req.text()));
  if (
    !(await signedWebhook(
      req,
      { ...env, TWILIO_AUTH_TOKEN: c.twilioToken },
      fields,
    ))
  )
    fail("Invalid Twilio signature", 403);
  const path = new URL(req.url).pathname;
  if (path === "/twilio/recording") {
    await recordingCallback(env, fields);
    ctx.waitUntil(recordingTasks(env));
    return new Response("OK");
  }
  const sid = fields.CallSid || "";
  if (!/^CA[a-f0-9]{32}$/.test(sid)) fail("Invalid call", 400);
  if (path === "/twilio/done" || path === "/twilio/forward-done") {
    // A completed leg includes normal hangup and answered voicemail. Never
    // announce failure after an established conversation.
    if (
      ["busy", "no-answer", "failed", "canceled"].includes(
        fields.DialCallStatus || "",
      )
    ) {
      const unavailable =
        path === "/twilio/forward-done"
          ? '<Say voice="Polly.Zhiyu" language="cmn-CN">您拨打的电话暂时无法接通，请稍后重试。</Say><Say voice="Polly.Joanna" language="en-US">The number you have dialed is temporarily unavailable. Please try again later.</Say>'
          : say("unavailable");
      return response(unavailable + "<Hangup/>");
    }
    return response("<Hangup/>");
  }
  if (path === "/twilio/cellular") {
    if (!c.inboundEnabled || !fields.From?.startsWith("sip:"))
      return hang("offline");
    const ticket = fields["SipHeader_X-Bridge"] || "";
    const job = await env.DB.prepare(
      "UPDATE jobs SET status='connected',updated=?,payload=json_set(payload,'$.callSid',?,'$.to',?) WHERE id=? AND kind='incoming' AND status='queued' AND created>? RETURNING id",
    )
      .bind(now(), sid, c.forwardTo, ticket, now() - 60000)
      .first();
    if (!job) return hang("expired");
    return response(
      `<Dial record="record-from-ringing-dual" recordingStatusCallback="https://worker.example.com/twilio/recording" recordingStatusCallbackMethod="POST" recordingStatusCallbackEvent="completed" callerId="${xml(env.TWILIO_NUMBER)}" timeout="30" timeLimit="7200" action="/twilio/forward-done"><Number>${xml(c.forwardTo)}</Number></Dial><Hangup/>`,
    );
  }
  if (!c.outboundEnabled || !c.pinHash) return hang("disabled");
  if (!fields.To?.includes(env.TWILIO_NUMBER)) return hang("invalid");
  if (path === "/twilio/voice") {
    await limit(env, "voice:" + fields.From, 10, 900);
    await env.DB.prepare(
      "INSERT OR IGNORE INTO sessions(id,expires,updated) VALUES(?,?,?)",
    )
      .bind(sid, now() + 180000, now())
      .run();
    return gather("pin", "pin");
  }
  if (path === "/twilio/pin") {
    // Count attempts atomically before verification; even concurrent webhooks share the bound.
    const s = await env.DB.prepare(
      "UPDATE sessions SET attempts=attempts+1,updated=? WHERE id=? AND stage='pin' AND attempts<3 AND expires>? RETURNING attempts",
    )
      .bind(now(), sid, now())
      .first<{ attempts: number }>();
    if (!s) return hang("denied");
    if (!equal(await hashPin(env, fields.Digits || ""), c.pinHash))
      return s.attempts < 3 ? gather("pin", "retry") : hang("denied");
    await env.DB.prepare(
      "UPDATE sessions SET stage='number',updated=? WHERE id=? AND stage='pin'",
    )
      .bind(now(), sid)
      .run();
    return gather("dial", "number");
  }
  if (path === "/twilio/dial") {
    let target: string;
    try {
      target = cellularNumber((fields.Digits || "").replace(/^\*/, "+"));
    } catch {
      return hang("invalid");
    }
    const edge = await online(env);
    if (!edge.online || !edge.voiceReady || !edge.sipRegistered)
      return hang("offline");
    const accepted = await env.DB.prepare(
      "UPDATE sessions SET stage='dialed',updated=? WHERE id=? AND stage='number' AND expires>? RETURNING id",
    )
      .bind(now(), sid, now())
      .first();
    if (!accepted) return hang("expired");
    const ticket = crypto.randomUUID();
    await enqueue(env, ticket, "dial", {
      to: target,
      callSid: sid,
      from: fields.From,
    });
    const sip = `sip:${c.sipUser}@${c.sipDomain}?X-Job=${encodeURIComponent(ticket)}`;
    return response(
      `<Dial record="record-from-ringing-dual" recordingStatusCallback="https://worker.example.com/twilio/recording" recordingStatusCallbackMethod="POST" recordingStatusCallbackEvent="completed" answerOnBridge="true" timeout="120" timeLimit="7200" action="/twilio/done"><Sip>${xml(sip)}</Sip></Dial><Hangup/>`,
    );
  }
  return new Response("Not found", { status: 404 });
}
