import { jwtDecrypt } from "jose";
import { config, encrypt } from "./config";
import { enc, equal, fail, unb64 } from "./util";
import { limit, now } from "./store";

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
export function base32(bytes: Uint8Array) {
  let bits = 0,
    value = 0,
    output = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += alphabet[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits) output += alphabet[(value << (5 - bits)) & 31];
  return output;
}
function decode(secret: string) {
  if (!/^[A-Z2-7]{32}$/.test(secret)) throw new Error("Invalid TOTP key");
  let bits = 0,
    value = 0;
  const result: number[] = [];
  for (const c of secret) {
    value = (value << 5) | alphabet.indexOf(c);
    bits += 5;
    if (bits >= 8) {
      result.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return new Uint8Array(result);
}
// RFC 6238 / Google Authenticator: SHA-1, six digits, 30-second time steps.
export async function totpCode(secret: string, step: number) {
  const counter = new Uint8Array(8);
  new DataView(counter.buffer).setBigUint64(0, BigInt(step));
  const key = await crypto.subtle.importKey(
    "raw",
    decode(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, counter));
  const offset = digest[digest.length - 1] & 15;
  const value = new DataView(digest.buffer).getUint32(offset) & 0x7fffffff;
  return String(value % 1000000).padStart(6, "0");
}
export async function matchingStep(
  secret: string,
  code: string,
  timestamp = now(),
) {
  if (!/^\d{6}$/.test(code)) return null;
  const current = Math.floor(timestamp / 30000);
  let matched: number | null = null;
  for (const offset of [0, -1, 1]) {
    const step = current + offset;
    if (
      step >= 0 &&
      equal(await totpCode(secret, step), code) &&
      matched === null
    )
      matched = step;
  }
  return matched;
}
export async function consumeTOTP(env: Env, secret: string, code: string) {
  const step = await matchingStep(secret, code);
  if (step === null) return false;
  const id = Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(secret))),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
  // Atomic compare-and-set, shared by every call and Worker isolate. Reject
  // reuse and older steps even within the allowed clock-skew window.
  const used = await env.DB.prepare(
    "INSERT INTO totp_usage(id,step) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET step=excluded.step WHERE totp_usage.step<excluded.step RETURNING id",
  )
    .bind(id, step)
    .first();
  return !!used;
}
export async function totpAPI(
  req: Request,
  env: Env,
  path: string,
  fields: Record<string, unknown>,
) {
  if (req.method !== "POST") fail("Method not allowed", 405);
  if (path === "/edge/totp/setup") {
    await limit(env, "totp:setup", 10, 600);
    const secret = base32(crypto.getRandomValues(new Uint8Array(20)));
    const expires = now() + 600000;
    await env.DB.prepare(
      "INSERT INTO totp_enrollment(id,value,expires) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value,expires=excluded.expires",
    )
      .bind(await encrypt(env, { secret }), expires)
      .run();
    const label = encodeURIComponent("Yume SIMBridge:" + env.TWILIO_NUMBER);
    const uri = `otpauth://totp/${label}?secret=${secret}&issuer=Yume%20SIM%20Hub&algorithm=SHA1&digits=6&period=30`;
    return { secret, uri, expires };
  }
  if (path === "/edge/totp/confirm") {
    await limit(env, "totp:enroll-confirm", 10, 600);
    const row = await env.DB.prepare(
      "SELECT value,expires FROM totp_enrollment WHERE id=1 AND expires>?",
    )
      .bind(now())
      .first<{ value: string; expires: number }>();
    if (!row) fail("2FA setup expired; generate a new binding code");
    const payload = (await jwtDecrypt(row.value, unb64(env.MASTER_KEY)))
      .payload;
    const secret = String(payload.secret || "");
    if (!(await consumeTOTP(env, secret, String(fields.code || ""))))
      fail("Invalid or already used one-time code");
    // Do not activate a key replaced by a concurrent setup request.
    const claimed = await env.DB.prepare(
      "DELETE FROM totp_enrollment WHERE id=1 AND value=? AND expires>? RETURNING id",
    )
      .bind(row.value, now())
      .first();
    if (!claimed) fail("2FA setup changed; generate a new binding code");
    const settings = await config(env);
    const encrypted = await encrypt(env, {
      ...settings,
      authMode: "totp",
      totpSecret: secret,
      authGeneration: crypto.randomUUID(),
    });
    // Publish the replacement key and revoke pending authorizations atomically.
    // Established calls are allowed to finish.
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO settings(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value",
      ).bind(encrypted),
      env.DB.prepare("DELETE FROM sessions"),
      env.DB.prepare(
        "UPDATE jobs SET status='expired',result='Telephone credentials reset',updated=? WHERE kind='dial' AND status='queued'",
      ).bind(now()),
    ]);
    return { confirmed: true };
  }
  fail("Not found", 404);
}
