import { fail } from "./util";
export function smsFingerprint(value: unknown): string {
  if (typeof value!=="string" || !/^[a-f0-9]{64}$/.test(value)) fail("SMS PDU fingerprint required",409);
  return value as string;
}
export async function seedSMSReceipts(env: Env, value: unknown) {
  if (!Array.isArray(value) || value.length>100) fail("Invalid receipt batch");
  for (const item of value) {
    const fingerprint=smsFingerprint(item?.fingerprint);
    if (typeof item?.id!=="string" || !/^msg_[a-f0-9]{32}$/.test(item.id)) fail("Invalid historical message ID");
    await env.DB.prepare("INSERT OR IGNORE INTO sms_receipts(fingerprint,event_id) SELECT ?,id FROM events WHERE id=? AND kind='sms.received'")
      .bind(fingerprint,"sms-"+item.id).run();
  }
  return { ok:true };
}
export async function smsEventID(env: Env, fingerprint: string) {
  await env.DB.prepare("INSERT OR IGNORE INTO sms_receipts(fingerprint,event_id) VALUES(?,?)")
    .bind(fingerprint,"sms-pdu-"+fingerprint).run();
  const row=await env.DB.prepare("SELECT event_id FROM sms_receipts WHERE fingerprint=?").bind(fingerprint).first<{event_id:string}>();
  if (!row) throw new Error("Missing SMS receipt");
  return row.event_id;
}
