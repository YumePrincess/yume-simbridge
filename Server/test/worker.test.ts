import { describe, it, expect, beforeEach, vi } from "vitest";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import {
  timingSafeEqual,
  randomBytes,
  createHmac,
  generateKeyPairSync,
} from "node:crypto";
import worker from "../src/index";
import { defaults, saveConfig, hashPin, publicConfig } from "../src/config";
import { cryptChunk } from "../src/recording-crypto";
import { recordingTasks, recordingCallback } from "../src/recordings";
import { receive } from "../src/email";
import { dkimSign } from "mailauth/lib/dkim/sign";
class DB {
  db = new DatabaseSync(":memory:");
  constructor() {
    this.db.exec(readFileSync("migrations/0001.sql", "utf8"));
    this.db.exec(readFileSync("migrations/0002_recordings.sql", "utf8"));
    this.db.exec(readFileSync("migrations/0003_notifications.sql", "utf8"));
    this.db.exec(readFileSync("migrations/0004_totp.sql", "utf8"));
    this.db.exec(readFileSync("migrations/0005_forward_screen.sql", "utf8"));
  }
  prepare(sql: string) {
    const stmt = this.db.prepare(sql);
    let values: unknown[] = [];
    const wrapper = {
      bind: (...v: unknown[]) => {
        values = v;
        return wrapper;
      },
      first: async () => stmt.get(...(values as never[])) || null,
      all: async () => ({ results: stmt.all(...(values as never[])) }),
      run: async () => ({
        success: true,
        meta: stmt.run(...(values as never[])),
      }),
    };
    return wrapper;
  }
  async batch(stmts: { run(): Promise<unknown> }[]) {
    const out = [];
    for (const s of stmts) out.push(await s.run());
    return out;
  }
}
let env: Env, db: DB, pending: Promise<unknown>[], ctx: ExecutionContext;
beforeEach(async () => {
  vi.restoreAllMocks();
  Object.assign(crypto.subtle, {
    timingSafeEqual: (a: Uint8Array, b: Uint8Array) => timingSafeEqual(a, b),
  });
  db = new DB();
  env = {
    DB: db,
    MASTER_KEY: randomBytes(32).toString("base64"),
    RECORDING_KEY: randomBytes(32).toString("base64"),
    EDGE_TOKEN: randomBytes(32).toString("hex"),
    PUBLIC_ORIGIN: "https://worker.example.com",
    TWILIO_ACCOUNT_SID: "AC" + "a".repeat(32),
    TWILIO_NUMBER: "+12025550124",
    EMAIL_ADDRESS: "sms@example.com",
    ASSETS: { fetch: async () => new Response("Internal server error") },
  } as unknown as Env;
  pending = [];
  ctx = {
    waitUntil: (p: Promise<unknown>) => pending.push(p),
  } as unknown as ExecutionContext;
  await saveConfig(env, {
    ...defaults,
    twilioToken: "test-token",
    sipPassword: "test-password",
    sipDomain: "test.sip.twilio.com",
    inboundEnabled: true,
    outboundEnabled: true,
    pinHash: await hashPin(env, "654321"),
  });
});
const sid = "CA" + "b".repeat(32);
async function webhook(path: string, fields: Record<string, string> = {}) {
  const f = {
    AccountSid: env.TWILIO_ACCOUNT_SID,
    CallSid: sid,
    To: env.TWILIO_NUMBER,
    From: "+12025550101",
    ...fields,
  };
  const url = env.PUBLIC_ORIGIN + path;
  const input =
    url +
    Object.keys(f)
      .sort()
      .map((k) => k + f[k as keyof typeof f])
      .join("");
  const sig = createHmac("sha1", "test-token").update(input).digest("base64");
  return worker.fetch!(
    new Request(url, {
      method: "POST",
      headers: { "X-Twilio-Signature": sig },
      body: new URLSearchParams(f),
    }),
    env,
    ctx,
  );
}
async function edge(
  path: string,
  data?: unknown,
  method = data ? "POST" : "GET",
) {
  return worker.fetch!(
    new Request(env.PUBLIC_ORIGIN + path, {
      method,
      headers: {
        Authorization: "Bearer " + env.EDGE_TOKEN,
        "Content-Type": "application/json",
      },
      body: data ? JSON.stringify(data) : undefined,
    }),
    env,
    ctx,
  );
}
describe("control and call authorization", () => {
  it("serves only the decoy page publicly and protects every management endpoint", async () => {
    expect(
      (await worker.fetch!(new Request(env.PUBLIC_ORIGIN), env, ctx)).status,
    ).toBe(500);
    expect(
      (
        await worker.fetch!(
          new Request(env.PUBLIC_ORIGIN + "/edge/state"),
          env,
          ctx,
        )
      ).status,
    ).toBe(401);
    expect((await edge("/edge/state")).status).toBe(200);
  });
  it("rejects forged Twilio callbacks", async () => {
    expect(
      (
        await worker.fetch!(
          new Request(env.PUBLIC_ORIGIN + "/twilio/voice", {
            method: "POST",
            body: "AccountSid=x",
          }),
          env,
          ctx,
        )
      ).status,
    ).toBe(403);
  });
  it("cannot skip the PIN, bounds attempts and binds authorization to CallSid", async () => {
    await edge("/edge/sync", {
      modemConnected: true,
      voiceReady: true,
      sipRegistered: true,
    });
    expect(
      await (await webhook("/twilio/dial", { Digits: "+12025550123" })).text(),
    ).not.toContain("<Sip>");
    await webhook("/twilio/voice");
    for (let i = 0; i < 3; i++)
      await webhook("/twilio/pin", { Digits: "000000" });
    expect(
      await (await webhook("/twilio/pin", { Digits: "654321" })).text(),
    ).toContain("Access denied");
  });
  it("creates a one-use dial ticket after a valid PIN and records the entire bridge", async () => {
    await edge("/edge/sync", {
      modemConnected: true,
      voiceReady: true,
      sipRegistered: true,
    });
    await webhook("/twilio/voice");
    await webhook("/twilio/pin", { Digits: "654321" });
    const xml = await (
      await webhook("/twilio/dial", { Digits: "+12025550123" })
    ).text();
    expect(xml).toContain("record-from-ringing-dual");
    expect(xml).toContain("<Sip>sip:simhub@test.sip.twilio.com?X-Job=");
    const id = xml.match(/X-Job=([^<]+)/)![1];
    expect((await edge("/edge/authorize", { id })).status).toBe(200);
    expect((await edge("/edge/authorize", { id })).status).toBe(403);
    expect(
      await (await webhook("/twilio/dial", { Digits: "+12025550123" })).text(),
    ).not.toContain("<Sip>");
  });
  it("atomically claims SMS jobs and leaves interrupted submissions for review", async () => {
    await db
      .prepare(
        "INSERT INTO jobs(id,kind,payload,status,created,updated) VALUES('sms1','sms','{}','queued',?,?)",
      )
      .bind(Date.now(), Date.now())
      .run();
    const a = (await (
      await edge("/edge/sync", { modemConnected: true })
    ).json()) as { job: unknown };
    const b = (await (
      await edge("/edge/sync", { modemConnected: true })
    ).json()) as { job: unknown };
    expect(a.job).toBeTruthy();
    expect(b.job).toBeNull();
  });
  it("does not return secrets to the client configuration view", async () => {
    const data = (await (await edge("/edge/state")).json()) as {
      settings: unknown;
    };
    const s = JSON.stringify(data.settings);
    expect(s).not.toContain("test-token");
    expect(s).not.toContain("test-password");
    expect(s).not.toContain("pinHash");
  });
  it("persists original caller notification before transferring using the Twilio caller ID", async () => {
    const r = (await (
      await edge("/edge/incoming", { from: "+8613812345678" })
    ).json()) as { id: string };
    const e = (await db
      .prepare("SELECT payload FROM events WHERE kind='call.incoming'")
      .first()) as { payload: string };
    expect(JSON.parse(e.payload).from).toBe("+8613812345678");
    const xml = await (
      await webhook("/twilio/cellular", {
        From: "sip:incoming@test.sip.twilio.com",
        "SipHeader_X-Bridge": r.id,
      })
    ).text();
    expect(xml).toContain('callerId="+12025550124"');
    expect(xml).toContain("+12025550123</Number>");
    expect(xml).toContain('answerOnBridge="true"');
    expect(xml).toContain("/twilio/forward-screen?parent=");
    expect(xml).toContain('action="/twilio/forward-done"');
  });
});
describe("recording integrity and deletion", () => {
  it("authenticates each recording chunk including its SID and index", async () => {
    const iv = randomBytes(12).toString("base64");
    const original = new TextEncoder().encode("test recording");
    const encrypted = await cryptChunk(env, "RE1", iv, 0, original);
    expect(await cryptChunk(env, "RE1", iv, 0, encrypted, true)).toEqual(
      original,
    );
    await expect(
      cryptChunk(env, "RE1", iv, 1, encrypted, true),
    ).rejects.toThrow();
    await expect(
      cryptChunk(env, "RE2", iv, 0, encrypted, true),
    ).rejects.toThrow();
  });
  it("never resurrects deleted recordings on duplicate Twilio callbacks", async () => {
    const f = {
      RecordingSid: "RE" + "c".repeat(32),
      CallSid: sid,
      RecordingStatus: "completed",
    };
    await recordingCallback(env, f);
    await db.prepare("UPDATE recordings SET status='deleted'").run();
    await recordingCallback(env, f);
    expect(
      (
        (await db.prepare("SELECT status FROM recordings").first()) as {
          status: string;
        }
      ).status,
    ).toBe("deleted");
  });
  it("deletes Twilio before R2 and retries failures durably", async () => {
    const f = {
      RecordingSid: "RE" + "c".repeat(32),
      CallSid: sid,
      RecordingStatus: "completed",
    };
    await recordingCallback(env, f);
    await db.prepare("UPDATE recordings SET status='deleting'").run();
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("fail", { status: 503 }),
    );
    await recordingTasks(env);
    const row = (await db
      .prepare("SELECT status,lease FROM recordings")
      .first()) as { status: string; lease: unknown };
    expect(row.status).toBe("deleting");
    expect(row.lease).toBeNull();
  });
});
describe("email-to-SMS DKIM", () => {
  const key = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const publicKey = key.publicKey
    .export({ type: "spki", format: "der" })
    .toString("base64");
  async function signed(
    options: { domain?: string; headers?: string; maxBodyLength?: number } = {},
  ) {
    const body =
      "From: sender@example.com\r\nTo: sms@example.com\r\nSubject: 10086\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n你好 SMS\r\n";
    const signature = await dkimSign(Buffer.from(body), {
      signatureData: [
        {
          signingDomain: options.domain || "yume.zone",
          selector: "sig1",
          privateKey: key.privateKey.export({ type: "pkcs8", format: "pem" }),
          headerList: options.headers || "from:to:subject:content-type",
          maxBodyLength: options.maxBodyLength,
        },
      ],
    });
    return signature.signatures + body;
  }
  async function mail(raw: string, from = "sender@example.com") {
    const bytes = Buffer.from(raw);
    const reject = vi.fn();
    await receive(
      {
        from,
        to: env.EMAIL_ADDRESS,
        rawSize: bytes.length,
        headers: new Headers(),
        raw: new ReadableStream({
          start(c) {
            c.enqueue(bytes);
            c.close();
          },
        }),
        setReject: reject,
      } as ForwardableEmailMessage,
      env,
    );
    return reject;
  }
  function dns() {
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            Status: 0,
            Answer: [
              {
                type: 16,
                data: JSON.stringify("v=DKIM1; k=rsa; p=" + publicKey),
              },
            ],
          }),
        ),
    );
  }

  it("accepts and deduplicates an aligned signed iCloud-style email without Authentication-Results", async () => {
    dns();
    const raw = await signed();
    expect(await mail(raw)).not.toHaveBeenCalled();
    expect(await mail(raw)).not.toHaveBeenCalled();
    const rows = await db.prepare("SELECT payload FROM jobs").all();
    expect(rows.results).toHaveLength(1);
    expect(
      JSON.parse((rows.results[0] as { payload: string }).payload).to,
    ).toBe("10086");
  });
  it("does not trust a forged authentication result without a signature", async () => {
    const raw =
      "From: sender@example.com\r\nTo: sms@example.com\r\nSubject: 10086\r\nAuthentication-Results: mx.cloudflare.net; dmarc=pass header.from=yume.zone\r\nContent-Type: text/plain\r\n\r\ntest";
    expect(await mail(raw)).toHaveBeenCalled();
  });
  it("rejects altered body, altered target, unaligned signer and unapproved sender", async () => {
    dns();
    const raw = await signed();
    for (const changed of [
      raw.replace("你好 SMS", "changed"),
      raw.replace("Subject: 10086", "Subject: 10010"),
      await signed({ domain: "attacker.net" }),
    ])
      expect(await mail(changed)).toHaveBeenCalled();
    expect(await mail(raw, "sender@example.com")).toHaveBeenCalled();
  });
  it("rejects unsigned command headers and partial-body signatures", async () => {
    dns();
    expect(
      await mail(await signed({ headers: "from:to:content-type" })),
    ).toHaveBeenCalled();
    expect(await mail(await signed({ maxBodyLength: 1 }))).toHaveBeenCalled();
  });
  it("rejects an unbound recipient and fails closed on DNS failure", async () => {
    dns();
    expect(
      await mail(
        (await signed()).replace(
          "To: sms@example.com",
          "To: sender@example.com",
        ),
      ),
    ).toHaveBeenCalled();
    vi.mocked(fetch).mockRejectedValue(new Error("DNS unavailable"));
    expect(await mail(await signed())).toHaveBeenCalled();
  });
});

describe("streaming recording archive", () => {
  it("verifies a multi-chunk archive and serves an authenticated byte range", async () => {
    const { archive, audio, CHUNK } = await import("../src/recording-crypto");
    const original = randomBytes(CHUNK * 2 + 123);
    const objects = new Map<string, Uint8Array>();
    env.RECORDINGS = {
      createMultipartUpload: async (key: string) => {
        const parts: Uint8Array[] = [];
        return {
          uploadPart: async (n: number, b: Uint8Array) => {
            parts[n - 1] = b;
            return { partNumber: n, etag: "test" };
          },
          complete: async () => {
            const all = Buffer.concat(parts);
            objects.set(key, all);
          },
          abort: async () => {},
        };
      },
      get: async (
        key: string,
        opts?: { range: { offset: number; length: number } },
      ) => {
        const all = objects.get(key);
        if (!all) return null;
        const b = opts
          ? all.slice(opts.range.offset, opts.range.offset + opts.range.length)
          : all;
        return {
          body: new ReadableStream({
            start(c) {
              c.enqueue(b);
              c.close();
            },
          }),
        };
      },
    } as unknown as R2Bucket;
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () =>
        new Response(original, {
          headers: { "Content-Length": String(original.length) },
        }),
    );
    const r = await archive(env, {
      sid: "RE" + "d".repeat(32),
      call: sid,
      conference: "",
      duration: 10,
      status: "pending",
      key: "",
      size: 0,
      iv: "",
      sha256: "",
      created: Date.now(),
      error: "",
      twilioDeleted: false,
    });
    expect(r.key).toMatch(/^simhub\/recordings\//);
    expect(r.size).toBe(original.length);
    const res = await audio(
      new Request(env.PUBLIC_ORIGIN + "/edge/recordings/" + r.sid + "/audio", {
        headers: { Range: `bytes=${CHUNK - 5}-${CHUNK + 19}` },
      }),
      env,
      r,
    );
    expect(res.status).toBe(206);
    expect(Buffer.from(await res.arrayBuffer())).toEqual(
      original.subarray(CHUNK - 5, CHUNK + 20),
    );
  });
});

describe("local numbering, service language and direct notifications", () => {
  it.each([
    ["95555", "95555"],
    ["02222826128", "02222826128"],
    ["*+12025550123", "+12025550123"],
  ])("preserves the requested dialing form %s", async (input, expected) => {
    await edge("/edge/sync", {
      modemConnected: true,
      voiceReady: true,
      sipRegistered: true,
    });
    await webhook("/twilio/voice");
    await webhook("/twilio/pin", { Digits: "654321" });
    const xml = await (await webhook("/twilio/dial", { Digits: input })).text();
    const id = xml.match(/X-Job=([^<]+)/)![1];
    const result = (await (await edge("/edge/authorize", { id })).json()) as {
      to: string;
    };
    expect(result.to).toBe(expected);
  });
  it("accepts local SMS destinations and international plus, and rejects command injection", async () => {
    const { cellularNumber } = await import("../src/config");
    for (const n of ["10086", "95555", "02222826128", "+12025550123"])
      expect(cellularNumber(n)).toBe(n);
    for (const n of ["+0222", "123;ATH", "123\rATD", "+1", "++12025550123"])
      expect(() => cellularNumber(n)).toThrow();
  });
  it.each(["en", "fr", "ja", "zh-Hans", "zh-Hant"] as const)(
    "uses service language %s in phone prompts",
    async (language) => {
      const { config, updateConfig } = await import("../src/config");
      const { prompt, speech } = await import("../src/languages");
      await updateConfig(env, await config(env), { serviceLanguage: language });
      const xml = await (await webhook("/twilio/voice")).text();
      expect(xml).toContain(prompt(language, "pin"));
      expect(xml).toContain('language="' + speech[language].locale + '"');
    },
  );
  it("uses the internal Gotify binding and localizes notices without translating SMS content", async () => {
    const { config, updateConfig } = await import("../src/config");
    await updateConfig(env, await config(env), {
      gotifyToken: "gotify-test-token",
      serviceLanguage: "fr",
    });
    const send = vi.fn().mockImplementation(async () => new Response("{}"));
    env.GOTIFY = { fetch: send } as unknown as Fetcher;
    await edge("/edge/incoming", { from: "+8613812345678" });
    await Promise.all(pending);
    expect(send).toHaveBeenCalledTimes(1);
    const first = JSON.parse(send.mock.calls[0][1].body);
    expect(first.title).toContain("Appel SIM entrant");
    expect(first.message).toContain("Numéro de l’appelant");
    await edge("/edge/sms", {
      id: "language-test",
      from: "10086",
      body: "你好，原文保持不变。",
    });
    await Promise.all(pending);
    const sms = JSON.parse(send.mock.calls[1][1].body);
    expect(sms.title).toContain("Message SIM");
    expect(sms.message).toBe("你好，原文保持不变。");
    const row = (await db
      .prepare(
        "SELECT notified FROM events WHERE id='call-' || (SELECT id FROM jobs WHERE kind='incoming' LIMIT 1)",
      )
      .first()) as { notified: number };
    expect(row.notified).toBe(1);
  });
  it("stores a notification failure and can retry without losing the event", async () => {
    const { config, updateConfig } = await import("../src/config");
    const { notify } = await import("../src/gotify");
    await updateConfig(env, await config(env), { gotifyToken: "token" });
    const send = vi
      .fn()
      .mockResolvedValue(new Response("fail", { status: 503 }));
    env.GOTIFY = { fetch: send } as unknown as Fetcher;
    await edge("/edge/incoming", { from: "95555" });
    await Promise.all(pending);
    let row = (await db
      .prepare("SELECT notified,last_error FROM events")
      .first()) as { notified: number; last_error: string };
    expect(row.notified).toBe(0);
    expect(row.last_error).toBe("Gotify HTTP 503");
    send.mockResolvedValue(new Response("{}"));
    await notify(env);
    row = (await db
      .prepare("SELECT notified,last_error FROM events")
      .first()) as typeof row;
    expect(row.notified).toBe(1);
    expect(row.last_error).toBe("");
  });
  it("records the caller number and direction rather than exposing filenames as the title", async () => {
    const incoming = (await (
      await edge("/edge/incoming", { from: "02222826128" })
    ).json()) as { id: string };
    await webhook("/twilio/cellular", {
      From: "sip:incoming@test.sip.twilio.com",
      "SipHeader_X-Bridge": incoming.id,
    });
    await recordingCallback(env, {
      RecordingSid: "RE" + "e".repeat(32),
      CallSid: sid,
      RecordingStatus: "completed",
    });
    const list = (await (await edge("/edge/recordings")).json()) as {
      peer: string;
      direction: string;
      target: string;
    }[];
    expect(list[0]).toMatchObject({
      peer: "02222826128",
      direction: "inbound",
      target: "+12025550123",
    });
  });
});

describe("hardware health", () => {
  it("does not mistake a live Mac heartbeat for a connected module", async () => {
    await edge("/edge/sync", {
      modemConnected: false,
      voiceReady: true,
      sipRegistered: true,
      busy: true,
    });
    const snapshot = (await (await edge("/edge/state")).json()) as {
      edge: Record<string, unknown>;
    };
    expect(snapshot.edge.online).toBe(false);
    expect(snapshot.edge.voiceReady).toBe(false);
    expect(snapshot.edge.busy).toBe(false);
  });
  it("invalidates all readiness when a heartbeat expires", async () => {
    await edge("/edge/sync", {
      modemConnected: true,
      voiceReady: true,
      sipRegistered: true,
      busy: true,
    });
    db.db.exec("UPDATE edge SET updated=updated-16000");
    const snapshot = (await (await edge("/edge/state")).json()) as {
      edge: Record<string, unknown>;
    };
    expect(snapshot.edge.online).toBe(false);
    expect(snapshot.edge.voiceReady).toBe(false);
    expect(snapshot.edge.sipRegistered).toBe(false);
    expect(snapshot.edge.busy).toBe(false);
  });
  it("never claims an SMS while the module is disconnected", async () => {
    await edge("/edge/send", { to: "10086", body: "test" });
    const result = (await (
      await edge("/edge/sync", { modemConnected: false })
    ).json()) as { job: unknown };
    expect(result.job).toBeNull();
  });
});

describe("dial result announcements", () => {
  it.each(["busy", "no-answer", "failed", "canceled"])(
    "announces a failed forward in Chinese and English: %s",
    async (status) => {
      const body = await (
        await webhook("/twilio/forward-done", { DialCallStatus: status })
      ).text();
      expect(body).toContain('language="cmn-CN"');
      expect(body).toContain("您拨打的用户暂时无法接通，请稍后重试。");
      expect(body).toContain('language="en-US"');
      expect(body).toContain("Please try again later.");
      expect(body.indexOf("cmn-CN")).toBeLessThan(body.indexOf("en-US"));
      expect(body).toContain("<Hangup/>");
    },
  );
  it.each(["completed", "answered", "", "unexpected"])(
    "does not misreport an answered call or unknown result: %s",
    async (status) => {
      for (const path of ["/twilio/done", "/twilio/forward-done"]) {
        const body = await (
          await webhook(path, { DialCallStatus: status })
        ).text();
        expect(body).not.toContain("<Say");
        expect(body).toContain("<Hangup/>");
      }
    },
  );
  it("uses the independent service language for cellular dial failures", async () => {
    await saveConfig(env, {
      ...defaults,
      twilioToken: "test-token",
      serviceLanguage: "ja",
    });
    const body = await (
      await webhook("/twilio/done", { DialCallStatus: "failed" })
    ).text();
    expect(body).toContain('language="ja-JP"');
    expect(body).toContain("おかけになった電話");
  });
});

describe("authenticator enrollment, verification and reset", () => {
  const secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
  it("matches the RFC 6238 SHA-1 test vectors (six digit truncation)", async () => {
    const { totpCode, base32, matchingStep } = await import("../src/totp");
    expect(base32(new TextEncoder().encode("12345678901234567890"))).toBe(
      secret,
    );
    for (const [seconds, expected] of [
      [59, "287082"],
      [1111111109, "081804"],
      [1111111111, "050471"],
      [1234567890, "005924"],
      [2000000000, "279037"],
      [20000000000, "353130"],
    ] as const) {
      expect(await totpCode(secret, Math.floor(seconds / 30))).toBe(expected);
    }
    expect(await matchingStep(secret, "287082", 59000)).toBe(1);
    expect(await matchingStep(secret, "287082", 89000)).toBe(1);
    expect(await matchingStep(secret, "287082", 120000)).toBeNull();
    expect(await matchingStep(secret, "12345a", 59000)).toBeNull();
  });
  it("atomically accepts a code once across concurrent calls and rejects older steps", async () => {
    const { consumeTOTP, totpCode } = await import("../src/totp");
    vi.spyOn(Date, "now").mockReturnValue(1234567890000);
    const step = Math.floor(Date.now() / 30000);
    const code = await totpCode(secret, step);
    const results = await Promise.all([
      consumeTOTP(env, secret, code),
      consumeTOTP(env, secret, code),
    ]);
    expect(results.filter(Boolean)).toHaveLength(1);
    expect(
      await consumeTOTP(env, secret, await totpCode(secret, step - 1)),
    ).toBe(false);
    expect(
      await consumeTOTP(env, secret, await totpCode(secret, step + 1)),
    ).toBe(true);
  });
  it("requires authenticated setup, hides keys from normal settings, and leaves password mode unchanged until confirmation", async () => {
    expect(
      (
        await worker.fetch!(
          new Request(env.PUBLIC_ORIGIN + "/edge/totp/setup", {
            method: "POST",
          }),
          env,
          ctx,
        )
      ).status,
    ).toBe(401);
    const response = await edge("/edge/totp/setup", {});
    expect(response.headers.get("Cache-Control")).toContain("no-store");
    const enrollment = (await response.json()) as {
      secret: string;
      uri: string;
    };
    expect(enrollment.secret).toMatch(/^[A-Z2-7]{32}$/);
    expect(enrollment.uri).toContain("otpauth://totp/");
    const state = await (await edge("/edge/state")).text();
    expect(state).not.toContain(enrollment.secret);
    expect(state).not.toContain("totpSecret");
    expect(state).not.toContain("authGeneration");
    expect(JSON.parse(state).settings.authMode).toBe("password");
    const row = (await db
      .prepare("SELECT value FROM totp_enrollment WHERE id=1")
      .first()) as { value: string };
    expect(row.value).not.toContain(enrollment.secret);
    expect(
      (await edge("/edge/settings", { authMode: "totp" }, "PUT")).status,
    ).toBe(400);
    expect((await edge("/edge/totp/confirm", { code: "invalid" })).status).toBe(
      400,
    );
  });
  it("activates only after proving possession, uses OTP instead of PIN, and permits switching back to password mode", async () => {
    const { totpCode } = await import("../src/totp");
    const { config } = await import("../src/config");
    const clock = vi.spyOn(Date, "now").mockReturnValue(1234567890000);
    const enrollment = (await (await edge("/edge/totp/setup", {})).json()) as {
      secret: string;
    };
    const code = await totpCode(
      enrollment.secret,
      Math.floor(Date.now() / 30000),
    );
    expect((await edge("/edge/totp/confirm", { code })).status).toBe(200);
    expect((await config(env)).authMode).toBe("totp");
    const prompt = await (await webhook("/twilio/voice")).text();
    expect(prompt).toContain("authenticator");
    expect(
      await (await webhook("/twilio/pin", { Digits: code })).text(),
    ).toContain("already used");
    expect(
      await (await webhook("/twilio/pin", { Digits: "654321" })).text(),
    ).not.toContain('action="/twilio/dial"');
    clock.mockReturnValue(1234567920000);
    const next = await totpCode(
      enrollment.secret,
      Math.floor(Date.now() / 30000),
    );
    expect(
      await (await webhook("/twilio/pin", { Digits: next })).text(),
    ).toContain('action="/twilio/dial"');
    expect(
      (await edge("/edge/settings", { authMode: "password" }, "PUT")).status,
    ).toBe(200);
    const other = "CA" + "d".repeat(32);
    await webhook("/twilio/voice", { CallSid: other });
    expect(
      await (
        await webhook("/twilio/pin", { CallSid: other, Digits: "654321" })
      ).text(),
    ).toContain('action="/twilio/dial"');
  });
  it("reset revokes the old secret, pending phone sessions and unclaimed dial tickets", async () => {
    const { totpCode, consumeTOTP } = await import("../src/totp");
    const { config } = await import("../src/config");
    vi.spyOn(Date, "now").mockReturnValue(1234567890000);
    await saveConfig(env, {
      ...(await config(env)),
      authMode: "totp",
      totpSecret: secret,
      authGeneration: "old",
    });
    await webhook("/twilio/voice");
    await db
      .prepare(
        "INSERT INTO jobs(id,kind,payload,status,created,updated) VALUES('old-ticket','dial',?,'queued',?,?)",
      )
      .bind(
        JSON.stringify({ to: "12345", authGeneration: "old" }),
        Date.now(),
        Date.now(),
      )
      .run();
    const enrollment = (await (await edge("/edge/totp/setup", {})).json()) as {
      secret: string;
    };
    expect((await config(env)).totpSecret).toBe(secret);
    const code = await totpCode(
      enrollment.secret,
      Math.floor(Date.now() / 30000),
    );
    expect((await edge("/edge/totp/confirm", { code })).status).toBe(200);
    const replaced = await config(env);
    expect(replaced.totpSecret).toBe(enrollment.secret);
    expect(replaced.authGeneration).not.toBe("old");
    expect(await db.prepare("SELECT id FROM sessions").first()).toBeNull();
    expect((await edge("/edge/authorize", { id: "old-ticket" })).status).toBe(
      403,
    );
    await webhook("/twilio/voice");
    expect(
      await (
        await webhook("/twilio/pin", {
          Digits: await totpCode(secret, Math.floor(Date.now() / 30000)),
        })
      ).text(),
    ).not.toContain('action="/twilio/dial"');
    expect(await consumeTOTP(env, replaced.totpSecret, code)).toBe(false);
    // A racing request that inserts an old-generation ticket after reset also fails.
    await db
      .prepare(
        "INSERT INTO jobs(id,kind,payload,status,created,updated) VALUES('raced-ticket','dial',?,'queued',?,?)",
      )
      .bind(
        JSON.stringify({ to: "12345", authGeneration: "old" }),
        Date.now(),
        Date.now(),
      )
      .run();
    expect((await edge("/edge/authorize", { id: "raced-ticket" })).status).toBe(
      403,
    );
  });
  it("rejects expired and replaced enrollment codes", async () => {
    const { totpCode } = await import("../src/totp");
    const clock = vi.spyOn(Date, "now").mockReturnValue(1234567890000);
    const first = (await (await edge("/edge/totp/setup", {})).json()) as {
      secret: string;
    };
    await edge("/edge/totp/setup", {});
    expect(
      (
        await edge("/edge/totp/confirm", {
          code: await totpCode(first.secret, Math.floor(Date.now() / 30000)),
        })
      ).status,
    ).toBe(400);
    clock.mockReturnValue(Date.now() + 601000);
    expect((await edge("/edge/totp/confirm", { code: "123456" })).status).toBe(
      400,
    );
  });
});

describe("private press-one forwarding screen", () => {
  const child = "CA" + "c".repeat(32);
  async function startScreen(seconds = 10) {
    await saveConfig(env, {
      ...(await (await import("../src/config")).config(env)),
      forwardConfirmSeconds: seconds,
    });
    const incoming = (await (
      await edge("/edge/incoming", { from: "02200000000" })
    ).json()) as { id: string };
    const body = await (
      await webhook("/twilio/cellular", {
        From: "sip:incoming@test.sip.twilio.com",
        "SipHeader_X-Bridge": incoming.id,
      })
    ).text();
    expect(body).toContain('answerOnBridge="true"');
    expect(body).toContain("/twilio/forward-screen?parent=");
    return { CallSid: child, ParentCallSid: sid, To: "+12025550123" };
  }
  const screenPath = "/twilio/forward-screen?parent=" + sid;
  const confirmPath = "/twilio/forward-confirm?parent=" + sid;
  it("privately prompts the called leg and passes the configured wait to Gather", async () => {
    const f = await startScreen(37);
    const body = await (await webhook(screenPath, f)).text();
    expect(body).toContain('input="dtmf"');
    expect(body).toContain('numDigits="1"');
    expect(body).toContain('timeout="37"');
    expect(body).toContain('actionOnEmptyResult="true"');
    expect(body).not.toContain('language="cmn-CN"');
    expect(body).toContain('language="en-US"');
    expect(body).toContain("press one");
    expect(body).toContain("<Hangup/>");
  });
  it("releases the private screen only for a confirmed child and tolerates retry", async () => {
    const f = await startScreen();
    await webhook(screenPath, f);
    for (let retry = 0; retry < 2; retry++) {
      const body = await (
        await webhook(confirmPath, { ...f, Digits: "1" })
      ).text();
      expect(body).not.toContain("<Hangup");
      expect(body).not.toContain("<Gather");
    }
    const done = await (
      await webhook("/twilio/forward-done", {
        DialCallStatus: "completed",
        DialBridged: "true",
        DialCallSid: child,
      })
    ).text();
    expect(done).not.toContain("<Say");
    expect(
      await (await webhook(confirmPath, { ...f, Digits: "1" })).text(),
    ).toContain("<Hangup/>");
  });
  it.each(["", "0", "2", "11", "#"])(
    "hangs up voicemail/no input/wrong input without bridging: %s",
    async (digits) => {
      const f = await startScreen();
      await webhook(screenPath, f);
      expect(
        await (await webhook(confirmPath, { ...f, Digits: digits })).text(),
      ).toContain("<Hangup/>");
      const done = await (
        await webhook("/twilio/forward-done", {
          DialCallStatus: "completed",
          DialBridged: "false",
        })
      ).text();
      expect(done).toContain("您拨打的用户暂时无法接通");
      expect(done).toContain("temporarily unavailable");
      expect(
        await (await webhook(confirmPath, { ...f, Digits: "1" })).text(),
      ).toContain("<Hangup/>");
    },
  );
  it("does not let a different parent, destination or child confirm a call", async () => {
    const f = await startScreen();
    await webhook(screenPath, f);
    for (const changed of [
      { ParentCallSid: child },
      { CallSid: "CA" + "d".repeat(32) },
      { To: "+12025550000" },
    ]) {
      expect(
        await (
          await webhook(confirmPath, { ...f, ...changed, Digits: "1" })
        ).text(),
      ).toContain("<Hangup/>");
    }
    expect(
      await (await webhook(confirmPath, { ...f, Digits: "1" })).text(),
    ).not.toContain("<Hangup");
  });
  it("does not confuse network answer or a lost confirmation with a bridged call", async () => {
    await startScreen();
    const done = await (
      await webhook("/twilio/forward-done", {
        DialCallStatus: "completed",
        DialBridged: "true",
      })
    ).text();
    expect(done).toContain("您拨打的用户暂时无法接通");
  });
  it("requires an explicit switch for direct forwarding and validates the time range", async () => {
    for (const seconds of [0, 61, 1.2, "10", null])
      expect(
        (
          await edge(
            "/edge/settings",
            { forwardConfirmSeconds: seconds },
            "PUT",
          )
        ).status,
      ).toBe(400);
    for (const seconds of [1, 60])
      expect(
        (
          await edge(
            "/edge/settings",
            { forwardConfirmSeconds: seconds },
            "PUT",
          )
        ).status,
      ).toBe(200);
    expect(
      (await edge("/edge/settings", { forwardConfirmEnabled: false }, "PUT"))
        .status,
    ).toBe(200);
    const incoming = (await (
      await edge("/edge/incoming", { from: "02200000000" })
    ).json()) as { id: string };
    const body = await (
      await webhook("/twilio/cellular", {
        From: "sip:incoming@test.sip.twilio.com",
        "SipHeader_X-Bridge": incoming.id,
      })
    ).text();
    expect(body).not.toContain("/forward-screen");
    expect(body).toContain("<Number>+12025550123</Number>");
  });
  it("expires abandoned screens and rejects unbound confirmations", async () => {
    const f = await startScreen();
    expect(
      await (await webhook(confirmPath, { ...f, Digits: "1" })).text(),
    ).toContain("<Hangup/>");
    await db.prepare("UPDATE forward_screens SET expires=0").run();
    expect(await (await webhook(screenPath, f)).text()).toContain("<Hangup/>");
  });
});

describe("forward confirmation language", () => {
  it.each(["en", "fr", "ja", "zh-Hans", "zh-Hant"] as const)(
    "uses the saved service language and pins it to the incoming call: %s",
    async (language) => {
      const { config } = await import("../src/config");
      const { speech, prompt } = await import("../src/languages");
      await saveConfig(env, {
        ...(await config(env)),
        serviceLanguage: language,
      });
      const incoming = (await (
        await edge("/edge/incoming", { from: "02200000000" })
      ).json()) as { id: string };
      await webhook("/twilio/cellular", {
        From: "sip:incoming@test.sip.twilio.com",
        "SipHeader_X-Bridge": incoming.id,
      });
      await saveConfig(env, {
        ...(await config(env)),
        serviceLanguage: language === "en" ? "ja" : "en",
      });
      const body = await (
        await webhook("/twilio/forward-screen?parent=" + sid, {
          CallSid: "CA" + "c".repeat(32),
          ParentCallSid: sid,
          To: "+12025550123",
        })
      ).text();
      expect(body).toContain(`language="${speech[language].locale}"`);
      expect(body).toContain(prompt(language, "forwardAccept"));
      expect(body.match(/<Say /g)).toHaveLength(1);
    },
  );
});
