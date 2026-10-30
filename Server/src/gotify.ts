import { prompt } from "./languages";
import { config } from "./config";
export async function notify(env: Env, eventID?: string) {
  const c = await config(env);
  if (!c.gotifyToken) return;
  const rows = await env.DB.prepare(
    "SELECT id,kind,payload FROM events WHERE kind IN ('sms.received','call.incoming','system.test') AND notified=0 AND attempts<20 AND (? IS NULL OR id=?) ORDER BY created LIMIT 10",
  ).bind(eventID ?? null,eventID ?? null).all<{ id: string; kind: string; payload: string }>();
  for (const row of rows.results) {
    // Claim one delivery; abandoned claims return to pending after five minutes.
    const lock = await env.DB.prepare(
      "UPDATE events SET notified=2,attempts=attempts+1,delivery_updated=? WHERE id=? AND notified=0 RETURNING id",
    )
      .bind(Date.now(), row.id)
      .first();
    if (!lock) continue;
    let delivered = false;
    let error = "";
    try {
      const p = JSON.parse(row.payload);
      const language = c.serviceLanguage;
      const caller =
        p.from && p.from !== "unknown" ? p.from : prompt(language, "unknown");
      const title =
        prompt(
          language,
          row.kind === "system.test"
            ? "test"
            : row.kind === "call.incoming"
              ? "incoming"
              : "sms",
        ) + (row.kind === "system.test" ? "" : " · " + caller);
      const message =
        row.kind === "system.test"
          ? prompt(language, "testBody")
          : row.kind === "call.incoming"
            ? [
                prompt(language, "from") + ": " + caller,
                prompt(language, "forward", { via: p.via, to: p.to }),
                prompt(language, "display", { via: p.via }),
              ].join("\n")
            : p.body;
      // Internal binding avoids public Worker-to-Worker routing/security filters.
      const send =
        new URL(c.gotifyUrl).origin === "https://gotify.example.com"
          ? env.GOTIFY.fetch.bind(env.GOTIFY)
          : fetch;
      const r = await send(c.gotifyUrl + "/message", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Gotify-Key": c.gotifyToken,
        },
        body: JSON.stringify({
          title,
          message,
          priority: row.kind === "call.incoming" ? 8 : 5,
          extras: { "client::display": { contentType: "text/plain" } },
        }),
        signal: AbortSignal.timeout(10000),
        redirect: "manual",
      });
      delivered = r.ok;
      if (!r.ok) error = "Gotify HTTP " + r.status;
      await r.body?.cancel();
    } catch (e) {
      error =
        e instanceof Error
          ? (
              e.name +
              ": " +
              e.message.replaceAll(c.gotifyToken, "[redacted]")
            ).slice(0, 200)
          : "Gotify request failed";
    }
    await env.DB.prepare(
      "UPDATE events SET notified=?,last_error=?,delivery_updated=? WHERE id=?",
    )
      .bind(delivered ? 1 : 0, error, Date.now(), row.id)
      .run();
  }
}
