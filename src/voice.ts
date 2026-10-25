import { recordingCallback, recordingTasks } from "./recordings";
import { config, hashPin, number } from "./config";
import { signedWebhook, response, xml, equal, fail } from "./util";
import { enqueue, limit, now, online } from "./store";
const say = (s: string) =>
  `<Say voice="woman" language="en-US">${xml(s)}</Say>`;
const hang = (s: string) => response(say(s) + "<Hangup/>");
const gather = (step: string, s: string) =>
  response(
    `<Gather input="dtmf" timeout="10" finishOnKey="#" action="/twilio/${step}" method="POST">${say(s)}</Gather><Hangup/>`,
  );
export async function voice(req: Request, env: Env, ctx: ExecutionContext) {
  const c = await config(env);
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
  if (path === "/twilio/done") return response("<Hangup/>");
  if (path === "/twilio/cellular") {
    if (!c.inboundEnabled || !fields.From?.startsWith("sip:"))
      return hang("Gateway unavailable.");
    const ticket = fields["SipHeader_X-Bridge"] || "";
    const job = await env.DB.prepare(
      "UPDATE jobs SET status='connected',updated=? WHERE id=? AND kind='incoming' AND status='queued' AND created>? RETURNING id",
    )
      .bind(now(), ticket, now() - 60000)
      .first();
    if (!job) return hang("Call authorization expired.");
    return response(
      `<Dial record="record-from-ringing-dual" recordingStatusCallback="https://worker.example.com/twilio/recording" recordingStatusCallbackMethod="POST" recordingStatusCallbackEvent="completed" callerId="${xml(env.TWILIO_NUMBER)}" timeout="30" timeLimit="7200" action="/twilio/done"><Number>${xml(c.forwardTo)}</Number></Dial><Hangup/>`,
    );
  }
  if (!c.outboundEnabled || !c.pinHash)
    return hang("Telephone gateway is not enabled.");
  if (!fields.To?.includes(env.TWILIO_NUMBER))
    return hang("Invalid destination.");
  if (path === "/twilio/voice") {
    await limit(env, "voice:" + fields.From, 10, 900);
    await env.DB.prepare(
      "INSERT OR IGNORE INTO sessions(id,expires,updated) VALUES(?,?,?)",
    )
      .bind(sid, now() + 180000, now())
      .run();
    return gather("pin", "Enter your access code followed by the pound key.");
  }
  if (path === "/twilio/pin") {
    // Count attempts atomically before verification; even concurrent webhooks share the bound.
    const s = await env.DB.prepare(
      "UPDATE sessions SET attempts=attempts+1,updated=? WHERE id=? AND stage='pin' AND attempts<3 AND expires>? RETURNING attempts",
    )
      .bind(now(), sid, now())
      .first<{ attempts: number }>();
    if (!s) return hang("Access denied.");
    if (!equal(await hashPin(env, fields.Digits || ""), c.pinHash))
      return s.attempts < 3
        ? gather("pin", "Incorrect code. Try again followed by pound.")
        : hang("Access denied.");
    await env.DB.prepare(
      "UPDATE sessions SET stage='number',updated=? WHERE id=? AND stage='pin'",
    )
      .bind(now(), sid)
      .run();
    return gather(
      "dial",
      "Enter the destination number including country code, followed by pound.",
    );
  }
  if (path === "/twilio/dial") {
    let target: string;
    try {
      target = number("+" + (fields.Digits || "").replace(/^00/, ""));
    } catch {
      return hang("Invalid destination number.");
    }
    const edge = await online(env);
    if (!edge.online || !edge.voiceReady || !edge.sipRegistered)
      return hang("Cellular gateway is offline.");
    const accepted = await env.DB.prepare(
      "UPDATE sessions SET stage='dialed',updated=? WHERE id=? AND stage='number' AND expires>? RETURNING id",
    )
      .bind(now(), sid, now())
      .first();
    if (!accepted) return hang("Authorization expired.");
    const ticket = crypto.randomUUID();
    await enqueue(env, ticket, "dial", { to: target, callSid: sid });
    const sip = `sip:${c.sipUser}@${c.sipDomain}?X-Job=${encodeURIComponent(ticket)}`;
    return response(
      `<Dial record="record-from-ringing-dual" recordingStatusCallback="https://worker.example.com/twilio/recording" recordingStatusCallbackMethod="POST" recordingStatusCallbackEvent="completed" answerOnBridge="true" timeout="45" timeLimit="7200" action="/twilio/done"><Sip>${xml(sip)}</Sip></Dial><Hangup/>`,
    );
  }
  return new Response("Not found", { status: 404 });
}
