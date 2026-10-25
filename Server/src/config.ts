import { serviceLanguages, type ServiceLanguage } from "./languages";
import { EncryptJWT, jwtDecrypt } from "jose";
import { unb64, fail, enc, b64 } from "./util";
export type Config = {
  serviceLanguage: ServiceLanguage;
  forwardTo: string;
  gotifyUrl: string;
  gotifyToken: string;
  allowedSenders: string[];
  pinHash: string;
  twilioToken: string;
  sipDomain: string;
  sipUser: string;
  sipPassword: string;
  inboundEnabled: boolean;
  outboundEnabled: boolean;
  emailEnabled: boolean;
};
export const defaults: Config = {
  serviceLanguage: "en",
  forwardTo: "+12025550123",
  gotifyUrl: "https://gotify.example.com",
  gotifyToken: "",
  allowedSenders: ["sender@example.com"],
  pinHash: "",
  twilioToken: "",
  sipDomain: "",
  sipUser: "simhub",
  sipPassword: "",
  inboundEnabled: false,
  outboundEnabled: false,
  emailEnabled: true,
};
export const number = (v: unknown) => {
  if (typeof v !== "string" || !/^\+[1-9]\d{6,14}$/.test(v))
    fail("请输入 E.164 国际号码（例如 +12025550123）");
  return v;
};
export function cellularNumber(v: unknown) {
  if (typeof v !== "string" || !/^(?:\+[1-9]\d{6,14}|[0-9]{1,20})$/.test(v))
    fail(
      "Use +countrycode for international numbers, or digits only for local numbers",
    );
  return v;
}
export async function encrypt(env: Env, data: Record<string, unknown>) {
  return new EncryptJWT(data)
    .setProtectedHeader({ alg: "dir", enc: "A256GCM" })
    .encrypt(unb64(env.MASTER_KEY));
}
export async function config(env: Env): Promise<Config> {
  const row = await env.DB.prepare(
    "SELECT value FROM settings WHERE id=1",
  ).first<{ value: string }>();
  return row
    ? {
        ...defaults,
        ...(await jwtDecrypt(row.value, unb64(env.MASTER_KEY))).payload,
      }
    : { ...defaults };
}
export async function saveConfig(env: Env, c: Config) {
  await env.DB.prepare(
    "INSERT INTO settings(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value",
  )
    .bind(await encrypt(env, c))
    .run();
}
export async function hashPin(env: Env, pin: string) {
  const k = await crypto.subtle.importKey(
    "raw",
    unb64(env.MASTER_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return b64(
    new Uint8Array(
      await crypto.subtle.sign("HMAC", k, enc.encode("simhub-pin:" + pin)),
    ),
  );
}
export function publicConfig(c: Config) {
  const { gotifyToken, pinHash, twilioToken, sipPassword, ...rest } = c;
  return {
    ...rest,
    gotifyConfigured: !!gotifyToken,
    pinConfigured: !!pinHash,
    twilioConfigured: !!twilioToken,
    sipConfigured: !!sipPassword,
  };
}
export async function updateConfig(
  env: Env,
  old: Config,
  v: Record<string, unknown>,
) {
  const c = { ...old };
  if ("serviceLanguage" in v) {
    if (!serviceLanguages.includes(v.serviceLanguage as ServiceLanguage))
      fail("Invalid service language");
    c.serviceLanguage = v.serviceLanguage as ServiceLanguage;
  }
  if ("forwardTo" in v) c.forwardTo = number(v.forwardTo);
  if (typeof v.gotifyUrl === "string") {
    const u = new URL(v.gotifyUrl);
    if (
      u.protocol !== "https:" ||
      u.username ||
      u.password ||
      u.search ||
      u.hash
    )
      fail("Gotify 地址必须为 HTTPS，不含 token；应用 token 在单独字段设置");
    c.gotifyUrl = u.href.replace(/\/$/, "");
  }
  for (const k of ["gotifyToken", "twilioToken", "sipPassword"] as const)
    if (typeof v[k] === "string" && v[k]) c[k] = v[k];
  if (typeof v.sipDomain === "string") {
    if (v.sipDomain && !/^[a-z0-9-]+\.sip\.twilio\.com$/.test(v.sipDomain))
      fail("请输入 Twilio SIP 域名");
    c.sipDomain = v.sipDomain;
  }
  if (typeof v.sipUser === "string") {
    if (!/^[a-zA-Z0-9_-]{3,64}$/.test(v.sipUser)) fail("SIP 用户名格式错误");
    c.sipUser = v.sipUser;
  }
  if (typeof v.pin === "string" && v.pin) {
    if (!/^\d{6,12}$/.test(v.pin)) fail("电话密码必须为 6–12 位数字");
    c.pinHash = await hashPin(env, v.pin);
  }
  if (Array.isArray(v.allowedSenders)) {
    if (
      v.allowedSenders.some(
        (x) => typeof x !== "string" || !/^\S+@[^@\s]+\.[^@\s]+$/.test(x),
      )
    )
      fail("发件人地址格式错误");
    c.allowedSenders = v.allowedSenders.map((x) =>
      String(x).trim().toLowerCase(),
    );
  }
  for (const k of [
    "inboundEnabled",
    "outboundEnabled",
    "emailEnabled",
  ] as const)
    if (typeof v[k] === "boolean") c[k] = v[k];
  if (
    (c.inboundEnabled || c.outboundEnabled) &&
    (!c.twilioToken || !c.sipDomain || !c.sipPassword)
  )
    fail("请先配置 Twilio 和 SIP");
  if (c.outboundEnabled && !c.pinHash) fail("请先设置电话密码");
  await saveConfig(env, c);
  return c;
}
