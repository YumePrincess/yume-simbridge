import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('../../',import.meta.url)));
// Initialize only this project's infrastructure; runtime configuration stays in the Mac client.
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import {cf,account} from './cloudflare.mjs';
await fs.mkdir('.secrets',{recursive:true,mode:0o700});
let b;try{b=JSON.parse(await fs.readFile('.secrets/bootstrap.json','utf8'));}catch{b={MASTER_KEY:crypto.randomBytes(32).toString('base64'),EDGE_TOKEN:crypto.randomBytes(32).toString('hex'),RECORDING_KEY:crypto.randomBytes(32).toString('base64')};await fs.writeFile('.secrets/bootstrap.json',JSON.stringify(b),{mode:0o600});}
let cfg=await fs.readFile('Server/wrangler.jsonc','utf8');
if(cfg.includes('"database_id":""')){const d=await cf(`/accounts/${account}/d1/database`,{name:'yume-simbridge'});cfg=cfg.replace('"database_id":""','"database_id":'+JSON.stringify(d.uuid));await fs.writeFile('Server/wrangler.jsonc',cfg);}
await fs.writeFile('.secrets/worker.json',JSON.stringify({MASTER_KEY:b.MASTER_KEY,EDGE_TOKEN:b.EDGE_TOKEN,RECORDING_KEY:b.RECORDING_KEY}),{mode:0o600});
await fs.writeFile('.secrets/edge.json',JSON.stringify({origin:'https://worker.example.com',token:b.EDGE_TOKEN}),{mode:0o600});
console.log('Dedicated infrastructure and private bootstrap prepared.');
