import { describe, it, expect, beforeEach, vi } from "vitest";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { timingSafeEqual, randomBytes, createHmac } from "node:crypto";
import worker from "../src/index";
import { defaults, saveConfig, hashPin, publicConfig } from "../src/config";
import { cryptChunk } from "../src/recording-crypto";
import { recordingTasks, recordingCallback } from "../src/recordings";
import { receive } from "../src/email";
class DB {
  db = new DatabaseSync(":memory:");
  constructor() {
    this.db.exec(readFileSync("migrations/0001.sql", "utf8"));
    this.db.exec(readFileSync("migrations/0002_recordings.sql", "utf8"));
    this.db.exec(readFileSync("migrations/0003_notifications.sql", "utf8"));
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
    expect(xml).toContain("<Number>+12025550123</Number>");
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
describe("email-to-SMS", () => {
  async function mail(auth: string, from = "sender@example.com") {
    const raw = new TextEncoder().encode(
      `From: ${from}\r\nTo: sms@example.com\r\nSubject: +12025550123\r\nAuthentication-Results: ${auth}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n你好 SMS`,
    );
    const reject = vi.fn();
    const msg = {
      from,
      to: env.EMAIL_ADDRESS,
      rawSize: raw.length,
      raw: new ReadableStream({
        start(c) {
          c.enqueue(raw);
          c.close();
        },
      }),
      setReject: reject,
    } as unknown as ForwardableEmailMessage;
    await receive(msg, env);
    return reject;
  }
  it("accepts authenticated allowed mail and deduplicates MIME delivery", async () => {
    expect(
      await mail("mx.cloudflare.net; dmarc=pass header.from=yume.zone"),
    ).not.toHaveBeenCalled();
    await mail("mx.cloudflare.net; dmarc=pass header.from=yume.zone");
    expect(
      (
        (await db.prepare("SELECT count(*) n FROM jobs").first()) as {
          n: number;
        }
      ).n,
    ).toBe(1);
  });
  it("rejects spoofed sender, forged authentication service, or failed DMARC", async () => {
    expect(
      await mail("attacker.net; dmarc=pass header.from=yume.zone"),
    ).toHaveBeenCalled();
    expect(
      await mail("mx.cloudflare.net; dmarc=fail header.from=yume.zone"),
    ).toHaveBeenCalled();
    expect(
      await mail(
        "mx.cloudflare.net; dmarc=pass header.from=yume.zone.attacker.net",
      ),
    ).toHaveBeenCalled();
    expect(
      await mail(
        "mx.cloudflare.net; dmarc=pass header.from=other.zone",
        "attacker@other.zone",
      ),
    ).toHaveBeenCalled();
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
