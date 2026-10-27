import { fail } from "./util";
// Preserve ticket/recording linkage and idempotency keys. Removing a row from
// the history view must never turn a replayed email into a second SMS.
export async function removeHistory(env: Env, path: string) {
  const match = path.match(/^\/edge\/history\/(sms|jobs)(?:\/([^/]+))?$/);
  if (!match) fail("Not found", 404);
  const table = match[1] === "sms" ? "events" : "jobs";
  const filter = table === "events" ? " AND kind='sms.received'" : "";
  let id: string | undefined;
  try {
    id = match[2] ? decodeURIComponent(match[2]) : undefined;
  } catch {
    fail("Invalid id");
  }
  if (id && id.length > 256) fail("Invalid id");
  const statement = env.DB.prepare(
    `UPDATE ${table} SET hidden=1 WHERE hidden=0${filter}${id ? " AND id=?" : ""}`,
  );
  await (id ? statement.bind(id) : statement).run();
}
