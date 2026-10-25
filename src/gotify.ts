import {config} from './config';
export async function notify(env:Env) {
 const c=await config(env);if(!c.gotifyToken)return;
 const rows=await env.DB.prepare("SELECT id,kind,payload FROM events WHERE kind IN ('sms.received','call.incoming') AND notified=0 AND attempts<20 ORDER BY created LIMIT 10").all<{id:string;kind:string;payload:string}>();
 for(const row of rows.results){
  // Claim one delivery; abandoned claims return to pending after five minutes.
  const lock=await env.DB.prepare('UPDATE events SET notified=2,attempts=attempts+1 WHERE id=? AND notified=0 RETURNING id').bind(row.id).first();if(!lock)continue;
  let delivered=false;
  try {const p=JSON.parse(row.payload);const caller=p.from&&p.from!=='unknown'?p.from:'未知／隐藏号码';const title=row.kind==='call.incoming'?'SIM 来电 · '+caller:'SIM 短信 · '+p.from;const message=row.kind==='call.incoming'?`原始来电号码：${caller}\n准备通过 Twilio ${p.via} 转接至 ${p.to}。\n接听页面显示的号码为 ${p.via}。`:p.body;const r=await fetch(c.gotifyUrl+'/message',{method:'POST',headers:{'Content-Type':'application/json','X-Gotify-Key':c.gotifyToken},body:JSON.stringify({title,message,priority:row.kind==='call.incoming'?8:5,extras:{'client::display':{contentType:'text/plain'}}}),signal:AbortSignal.timeout(10000),redirect:'error'});delivered=r.ok;await r.body?.cancel();}catch{ /* durable retry */ }
  await env.DB.prepare('UPDATE events SET notified=? WHERE id=?').bind(delivered?1:0,row.id).run();
 }
}
