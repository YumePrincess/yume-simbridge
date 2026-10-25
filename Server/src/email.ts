import PostalMime from "postal-mime";
import { config, cellularNumber } from "./config";
import { enqueue, limit } from "./store";
import { readBytes, enc } from "./util";
import { verifySenderDKIM } from "./mail-auth";
export async function receive(message: ForwardableEmailMessage, env: Env) {
  try {
    const c = await config(env);
    if (message.to.toLowerCase() !== env.EMAIL_ADDRESS || !c.emailEnabled)
      throw Error("Email SMS disabled");
    if (!c.allowedSenders.includes(message.from.toLowerCase()))
      throw Error("Sender not permitted");
    if (message.rawSize > 131072) throw Error("Email too large");
    const raw = await readBytes(
      new Request("https://mail.invalid", {
        method: "POST",
        body: message.raw,
        duplex: "half",
      } as RequestInit),
      131072,
    );
    const mail = await PostalMime.parse(raw);
    if (mail.from?.address?.toLowerCase() !== message.from.toLowerCase())
      throw Error("Envelope sender does not match From");
    if (
      !mail.to?.some(
        (recipient) =>
          "address" in recipient &&
          recipient.address?.toLowerCase() === env.EMAIL_ADDRESS,
      )
    )
      throw Error("Signed To must include the SMS email address");
    const signatures = mail.headers.filter(
      (header) => header.key === "dkim-signature",
    );
    if (!signatures.length || signatures.length > 4)
      throw Error("Sender DKIM authentication required");
    const signatureId = await verifySenderDKIM(raw, message.from);
    const to = cellularNumber(mail.subject?.trim());
    const body = mail.text?.trim();
    if (!body || body.length > 2000)
      throw Error("Use text/plain body, 1–2000 characters");
    await limit(env, "email:" + message.from, 30, 3600);
    // The verified signature binds the command and the complete body. Replays with
    // different unsigned MIME headers must not create a second SMS job.
    const identity = enc.encode(
      JSON.stringify([message.from.toLowerCase(), signatureId]),
    );
    const digest = await crypto.subtle.digest("SHA-256", identity);
    const id =
      "mail-" +
      Array.from(new Uint8Array(digest), (b) =>
        b.toString(16).padStart(2, "0"),
      ).join("");
    await enqueue(env, id, "sms", {
      to,
      body,
      source: "email",
      from: message.from,
    });
  } catch (e) {
    message.setReject(e instanceof Error ? e.message : "Email rejected");
  }
}
