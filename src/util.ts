export const enc = new TextEncoder();
export const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
export const unb64 = (s: string) =>
  Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export const random = () =>
  crypto.randomUUID().replaceAll("-", "") +
  crypto.randomUUID().replaceAll("-", "");
export function equal(a: string, b: string) {
  const x = enc.encode(a),
    y = enc.encode(b);
  return x.length === y.length && crypto.subtle.timingSafeEqual(x, y);
}
export const xml = (s: unknown) =>
  String(s ?? "").replace(
    /[<>&"']/g,
    (c) =>
      ({
        "<": "&lt;",
        ">": "&gt;",
        "&": "&amp;",
        '"': "&quot;",
        "'": "&apos;",
      })[c]!,
  );
export const response = (s: string) =>
  new Response(
    `<?xml version="1.0" encoding="UTF-8"?><Response>${s}</Response>`,
    {
      headers: {
        "Content-Type": "text/xml; charset=utf-8",
        "Cache-Control": "no-store",
      },
    },
  );
export const redirect = (url: string) =>
  `<Redirect method="POST">${xml(url)}</Redirect>`;
export function say(text: string, locale = "en-US"): string {
  // Keep the same voice and cadence throughout each English/French sentence.
  if (locale === "en-US") text = text.replace(/\bYume\b/gi, "Yoo-meh");
  if (locale === "fr-FR") text = text.replace(/\bYume\b/gi, "Youmé");
  return `<Say language="${xml(locale)}" voice="${locale === "zh-CN" ? "Polly.Zhiyu" : locale === "ja-JP" ? "Polly.Mizuki" : "woman"}">${xml(text)}</Say>`;
}
export const done = new Set([
  "completed",
  "canceled",
  "failed",
  "busy",
  "no-answer",
]);
export function fail(message: string, status = 400): never {
  throw new HttpError(message, status);
}
export class HttpError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}
export class TwilioError extends HttpError {
  constructor(
    public upstreamStatus: number,
    code?: number,
  ) {
    super(`Twilio ${upstreamStatus}/${code ?? "unknown"}`, 502);
  }
}
export async function signedWebhook(
  req: Request,
  env: Env & {TWILIO_AUTH_TOKEN:string},
  fields: Record<string, string>,
) {
  if (fields.AccountSid !== env.TWILIO_ACCOUNT_SID) return false;
  const url = new URL(req.url);
  if (url.origin !== env.PUBLIC_ORIGIN) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(env.TWILIO_AUTH_TOKEN),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const input =
    url.href +
    Object.keys(fields)
      .sort()
      .map((k) => k + fields[k])
      .join("");
  const sig = b64(
    new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(input))),
  );
  return equal(sig, req.headers.get("X-Twilio-Signature") || "");
}

export async function readBytes(req: Request, limit: number) {
  const length = Number(req.headers.get("Content-Length"));
  if (length > limit) fail("Payload too large", 413);
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader(),
    parts: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const r = await reader.read();
      if (r.done) break;
      total += r.value.length;
      if (total > limit) {
        await reader.cancel();
        fail("Payload too large", 413);
      }
      parts.push(r.value);
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    result.set(p, at);
    at += p.length;
  }
  return result;
}
