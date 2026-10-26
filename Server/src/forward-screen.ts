import { prompt, speech, type ServiceLanguage } from "./languages";
import { now } from "./store";
import { response, xml } from "./util";

export const forwardUnavailable =
  '<Say voice="Polly.Zhiyu" language="cmn-CN">您拨打的用户暂时无法接通，请稍后重试。</Say><Say voice="Polly.Joanna" language="en-US">The person you are calling is temporarily unavailable. Please try again later.</Say>';
type Screen = {
  parent_sid: string;
  child_sid: string | null;
  target: string;
  state: string;
  wait_seconds: number;
  service_language: ServiceLanguage;
  expires: number;
  finished: number;
};
export async function screenForward(
  req: Request,
  env: Env,
  fields: Record<string, string>,
  path: string,
) {
  const parent = new URL(req.url).searchParams.get("parent") || "";
  const row = await env.DB.prepare(
    "SELECT * FROM forward_screens WHERE parent_sid=?",
  )
    .bind(parent)
    .first<Screen>();
  const hang = () => response("<Hangup/>");
  if (
    !row ||
    row.finished ||
    fields.ParentCallSid !== parent ||
    fields.To !== row.target ||
    !/^CA[a-f0-9]{32}$/.test(fields.CallSid || "")
  )
    return hang();
  // Twilio may retry the successful Gather webhook; only that same child may
  // resume the confirmed bridge. A different call can never claim this screen.
  if (row.child_sid && row.child_sid !== fields.CallSid) return hang();
  if (row.state === "accepted")
    return path === "/twilio/forward-confirm" && fields.Digits === "1"
      ? response("")
      : hang();
  if (row.state !== "pending" || row.expires <= now()) return hang();
  if (path === "/twilio/forward-screen") {
    const bound = await env.DB.prepare(
      "UPDATE forward_screens SET child_sid=?,updated=? WHERE parent_sid=? AND state='pending' AND finished=0 AND expires>? AND (child_sid IS NULL OR child_sid=?) RETURNING parent_sid",
    )
      .bind(fields.CallSid, now(), parent, now(), fields.CallSid)
      .first();
    if (!bound) return hang();
    const action = `${env.PUBLIC_ORIGIN}/twilio/forward-confirm?parent=${encodeURIComponent(parent)}`;
    const language = row.service_language;
    const confirmationPrompt = `<Say voice="${speech[language].voice}" language="${speech[language].locale}">${xml(prompt(language, "forwardAccept"))}</Say>`;
    return response(
      `<Gather input="dtmf" numDigits="1" finishOnKey="" timeout="${row.wait_seconds}" action="${xml(action)}" method="POST" actionOnEmptyResult="true">${confirmationPrompt}</Gather><Hangup/>`,
    );
  }
  const accepted = fields.Digits === "1";
  const changed = await env.DB.prepare(
    "UPDATE forward_screens SET state=?,updated=? WHERE parent_sid=? AND child_sid=? AND state='pending' AND finished=0 AND expires>? RETURNING parent_sid",
  )
    .bind(
      accepted ? "accepted" : "rejected",
      now(),
      parent,
      fields.CallSid,
      now(),
    )
    .first();
  return changed && accepted ? response("") : hang();
}
export async function unconfirmedForward(
  env: Env,
  sid: string,
  bridged: string | undefined,
) {
  const row = await env.DB.prepare(
    "SELECT state FROM forward_screens WHERE parent_sid=?",
  )
    .bind(sid)
    .first<{ state: string }>();
  if (!row) return bridged === "false";
  await env.DB.prepare(
    "UPDATE forward_screens SET finished=1,updated=? WHERE parent_sid=?",
  )
    .bind(now(), sid)
    .run();
  return row.state !== "accepted" || bridged !== "true";
}
