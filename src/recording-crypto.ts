import {config} from './config';
import { createHash } from "node:crypto";
import { b64, unb64, enc, fail } from "./util";
export const CHUNK = 256 * 1024;
export type Recording = {
  sid: string;
  call: string;
  conference: string;
  duration: number;
  status: string;
  key: string;
  size: number;
  iv: string;
  sha256: string;
  created: number;
  error: string;
  twilioDeleted: boolean;
};
const keyFor = (env: Env) =>
  crypto.subtle.importKey("raw", unb64(env.RECORDING_KEY), "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
function ivFor(base: string, i: number) {
  const iv = new Uint8Array(12);
  const original = unb64(base);
  iv.set(original);
  const view = new DataView(iv.buffer);
  view.setUint32(8, original.length === 12 ? (view.getUint32(8) ^ i) >>> 0 : i);
  return iv;
}
export async function cryptChunk(
  env: Env,
  sid: string,
  iv: string,
  index: number,
  data: Uint8Array,
  decrypt = false,
) {
  const key = await keyFor(env),
    args = {
      name: "AES-GCM",
      iv: ivFor(iv, index),
      additionalData: enc.encode(`simhub/v1/${sid}/${index}`),
    };
  return new Uint8Array(
    await crypto.subtle[decrypt ? "decrypt" : "encrypt"](args, key, data),
  );
}
async function* chunks(stream: ReadableStream<Uint8Array>, length: number) {
  const reader = stream.getReader();
  let buffered = new Uint8Array(length),
    used = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      let offset = 0;
      while (offset < value.length) {
        const n = Math.min(length - used, value.length - offset);
        buffered.set(value.subarray(offset, offset + n), used);
        used += n;
        offset += n;
        if (used === length) {
          yield buffered;
          buffered = new Uint8Array(length);
          used = 0;
        }
      }
    }
    if (used) yield buffered.subarray(0, used);
  } finally {
    reader.releaseLock();
  }
}
export async function archive(env: Env, rec: Recording): Promise<Recording> {
  let r = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Recordings/${rec.sid}.mp3`,
    {
      headers: {
        Authorization: `Basic ${btoa(`${env.TWILIO_ACCOUNT_SID}:${(await config(env)).twilioToken}`)}`,
      },
      signal: AbortSignal.timeout(120000),
      redirect: "manual",
    },
  );
  for (
    let hop = 0;
    hop < 3 && [301, 302, 303, 307, 308].includes(r.status);
    hop++
  ) {
    const dest = new URL(r.headers.get("Location") || "", r.url);
    if (
      dest.protocol !== "https:" ||
      !(
        dest.hostname === "api.twilio.com" ||
        dest.hostname.endsWith(".twiliocdn.com") ||
        dest.hostname.endsWith(".amazonaws.com")
      )
    )
      throw new Error("Untrusted recording redirect");
    const headers: Record<string, string> =
      dest.hostname === "api.twilio.com"
        ? {
            Authorization: `Basic ${btoa(`${env.TWILIO_ACCOUNT_SID}:${(await config(env)).twilioToken}`)}`,
          }
        : {};
    await r.body?.cancel();
    r = await fetch(dest.href, {
      headers,
      redirect: "manual",
      signal: AbortSignal.timeout(120000),
    });
  }
  if (!r.ok || !r.body) throw new Error(`recording-download-${r.status}`);
  const declared = Number(r.headers.get("Content-Length"));
  if (declared > 1024 * 1024 * 1024) throw new Error("recording-too-large");
  // Twilio may stream MP3 without Content-Length. Multipart upload keeps memory bounded.
  const iv = b64(crypto.getRandomValues(new Uint8Array(12))),
    key = `simhub/recordings/${new Date(rec.created).toISOString().slice(0, 10).replaceAll("-", "/")}/${rec.sid}.mp3.enc`;
  const upload = await env.RECORDINGS.createMultipartUpload(key, {
    httpMetadata: { contentType: "application/octet-stream" },
    customMetadata: { format: "aes-gcm-chunked-v1" },
  });
  const hash = createHash("sha256"),
    parts: R2UploadedPart[] = [];
  let size = 0,
    index = 0,
    buffers: Uint8Array[] = [],
    bufferSize = 0;
  async function flush() {
    const bytes = new Uint8Array(bufferSize);
    let at = 0;
    for (const b of buffers) {
      bytes.set(b, at);
      at += b.length;
    }
    parts.push(await upload.uploadPart(parts.length + 1, bytes));
    buffers = [];
    bufferSize = 0;
  }
  try {
    for await (const c of chunks(r.body, CHUNK)) {
      size += c.length;
      if (size > 1024 * 1024 * 1024) throw new Error("recording-too-large");
      hash.update(c);
      const encrypted = await cryptChunk(env, rec.sid, iv, index++, c);
      buffers.push(encrypted);
      bufferSize += encrypted.length;
      if (bufferSize >= 5 * 1024 * 1024) await flush();
    }
    if (!size) throw new Error("recording-empty");
    if (bufferSize) await flush();
    if (declared && declared !== size) throw new Error("recording-incomplete");
    await upload.complete(parts);
  } catch (e) {
    await upload.abort().catch(() => {});
    throw e;
  }
  const digest = hash.digest("hex");
  const object = await env.RECORDINGS.get(key);
  if (!object) throw new Error("r2-verification-missing");
  const check = createHash("sha256");
  let n = 0,
    i = 0;
  for await (const c of chunks(object.body, CHUNK + 16)) {
    const p = await cryptChunk(env, rec.sid, iv, i++, c, true);
    n += p.length;
    check.update(p);
  }
  if (n !== size || check.digest("hex") !== digest)
    throw new Error("r2-verification-failed");
  return {
    ...rec,
    key,
    size,
    iv,
    sha256: digest,
    status: "archived",
    error: "",
  };
}
export async function audio(req: Request, env: Env, rec: Recording) {
  if (
    rec.status !== "archived" ||
    !rec.key.startsWith("simhub/recordings/")
  )
    fail("录音尚未归档", 409);
  let start = 0,
    end = rec.size - 1,
    partial = false;
  const range = req.headers.get("Range");
  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!match || (!match[1] && !match[2]))
      return new Response(null, {
        status: 416,
        headers: { "Content-Range": `bytes */${rec.size}` },
      });
    if (!match[1]) start = Math.max(0, rec.size - Number(match[2]));
    else {
      start = Number(match[1]);
      if (match[2]) end = Math.min(end, Number(match[2]));
    }
    if (
      !Number.isSafeInteger(start) ||
      !Number.isSafeInteger(end) ||
      start > end ||
      start >= rec.size
    )
      return new Response(null, {
        status: 416,
        headers: { "Content-Range": `bytes */${rec.size}` },
      });
    partial = true;
  }
  const first = Math.floor(start / CHUNK),
    last = Math.floor(end / CHUNK),
    offset = first * (CHUNK + 16),
    cipherEnd = Math.min(
      (last + 1) * (CHUNK + 16),
      rec.size + 16 * Math.ceil(rec.size / CHUNK),
    );
  const object = await env.RECORDINGS.get(rec.key, {
    range: { offset, length: cipherEnd - offset },
  });
  if (!object) fail("录音文件不存在", 404);
  const reader = chunks(object.body, CHUNK + 16)[Symbol.asyncIterator]();
  let index = first;
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const v = await reader.next();
        if (v.done) {
          controller.close();
          return;
        }
        const p = await cryptChunk(env, rec.sid, rec.iv, index, v.value, true);
        const at = index * CHUNK;
        index++;
        controller.enqueue(
          p.subarray(Math.max(0, start - at), Math.min(p.length, end - at + 1)),
        );
      } catch (e) {
        controller.error(e);
      }
    },
    async cancel() {
      await reader.return?.();
    },
  });
  const headers = new Headers({
    "Content-Type": "audio/mpeg",
    "Content-Length": String(end - start + 1),
    "Accept-Ranges": "bytes",
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
    "Content-Disposition": `${new URL(req.url).searchParams.has("download") ? "attachment" : "inline"}; filename="${rec.sid}.mp3"`,
  });
  if (partial)
    headers.set("Content-Range", `bytes ${start}-${end}/${rec.size}`);
  return new Response(body, { status: partial ? 206 : 200, headers });
}
