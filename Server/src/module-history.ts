import { fail } from "./util";
export async function archiveModuleHistory(env: Env, entries: unknown) {
 if (!Array.isArray(entries) || entries.length>6) fail("Invalid module history batch");
 const statements=[];
 for (const record of entries) {
  if (!record || !["DC","RC","MC"].includes(record.storage) || !Number.isInteger(record.index) || record.index<1 || record.index>1000 || typeof record.raw!=="string" || record.raw.length>2048 || !record.raw.startsWith("+CPBR:")) fail("Invalid module call history");
  const bytes=new TextEncoder().encode(record.storage+"\0"+record.raw);
  const hash=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),v=>v.toString(16).padStart(2,"0")).join("");
  statements.push(env.DB.prepare("INSERT OR IGNORE INTO module_call_history(fingerprint,payload,created) VALUES(?,?,?)").bind(hash,JSON.stringify({storage:record.storage,index:record.index,raw:record.raw}),Date.now()));
 }
 if (statements.length) await env.DB.batch(statements);
 return { stored:true };
}
