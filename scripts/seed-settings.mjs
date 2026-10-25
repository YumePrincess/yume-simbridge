import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import {EncryptJWT,jwtDecrypt} from 'jose';
import {cf,account} from './cloudflare.mjs';
const b=JSON.parse(await fs.readFile('.secrets/bootstrap.json','utf8'));
if(!b.RECORDING_KEY){b.RECORDING_KEY=crypto.randomBytes(32).toString('base64');await fs.writeFile('.secrets/bootstrap.json',JSON.stringify(b),{mode:0o600});}
await fs.writeFile('.secrets/worker.json',JSON.stringify({MASTER_KEY:b.MASTER_KEY,EDGE_TOKEN:b.EDGE_TOKEN,RECORDING_KEY:b.RECORDING_KEY}),{mode:0o600});
const wr={d1_databases:[{database_id:(await fs.readFile('wrangler.jsonc','utf8')).match(/"database_id"\s*:\s*"([^"]+)"/)[1]}]};
const query=(sql,params)=>cf(`/accounts/${account}/d1/database/${wr.d1_databases[0].database_id}/query`,{sql,params});
const existing=await query('SELECT value FROM settings WHERE id=1',[]);
let old={};if(existing[0]?.results?.[0])old=(await jwtDecrypt(existing[0].results[0].value,Buffer.from(b.MASTER_KEY,'base64'))).payload;
const tw=JSON.parse(await fs.readFile('.secrets/twilio-setup.json','utf8'));
const gotify=JSON.parse(await fs.readFile('.secrets/gotify.json','utf8'));
const settings={forwardTo:'+12025550123',gotifyUrl:gotify.url,gotifyToken:gotify.token,allowedSenders:['sender@example.com'],pinHash:'',twilioToken:(await fs.readFile('.secrets/twilio-token','utf8')).trim(),sipDomain:'yume-simhub.sip.twilio.com',sipUser:'simhub',sipPassword:tw.password,inboundEnabled:true,outboundEnabled:false,emailEnabled:true,...old};
const value=await new EncryptJWT(settings).setProtectedHeader({alg:'dir',enc:'A256GCM'}).encrypt(Buffer.from(b.MASTER_KEY,'base64'));
await query('INSERT INTO settings(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',[value]);
if(b.clientId)await cf(`/accounts/${account}/d1/database/c57c77ef-b69f-4a7e-9c13-b51c5327a3df/query`,{sql:'UPDATE oauth_clients SET is_active=0,updated_at=? WHERE id=?',params:[Date.now(),b.clientId]});
console.log('Encrypted settings saved. PIN dialing remains disabled until configured in the Mac app.');
