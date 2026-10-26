import { config } from "./config";
import { now } from "./store";

// SIP CANCEL/BYE is primary. Independently stop the ticket-bound Twilio parent
// on a Mac teardown event, including an answered private screening child.
export async function cancelForward(env: Env, id: string) {
  const job = await env.DB.prepare(
    "SELECT payload FROM jobs WHERE id=? AND kind='incoming'",
  )
    .bind(id)
    .first<{ payload: string }>();
  if (!job) return;
  const sid = JSON.parse(job.payload).callSid;
  if (typeof sid !== "string" || !/^CA[a-f0-9]{32}$/.test(sid)) return;
  await env.DB.prepare(
    "UPDATE forward_screens SET finished=1,updated=? WHERE parent_sid=?",
  )
    .bind(now(), sid)
    .run();
  const c = await config(env);
  if (!c.twilioToken) return;
  try {
    const result = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Calls/${sid}.json`,
      {
        method: "POST",
        headers: {
          Authorization:
            "Basic " + btoa(env.TWILIO_ACCOUNT_SID + ":" + c.twilioToken),
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ Status: "completed" }),
        signal: AbortSignal.timeout(5000),
      },
    );
    // An already completed/cancelled parent can return 400/404.
    if (!result.ok && result.status !== 400 && result.status !== 404)
      console.warn(
        JSON.stringify({
          event: "forward.cancel.failed",
          status: result.status,
        }),
      );
    await result.body?.cancel();
  } catch {
    console.warn(JSON.stringify({ event: "forward.cancel.unavailable" }));
  }
}
