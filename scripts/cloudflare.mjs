import fs from 'node:fs/promises';
export const account='8945f9d46f2b03639bc88d37424f1052';
export async function cf(path,data,method=data?'POST':'GET'){
 const auth=await fs.readFile(process.env.HOME+'/Library/Preferences/.wrangler/config/default.toml','utf8');const token=auth.match(/oauth_token\s*=\s*"([^"]+)"/)[1];
 const r=await fetch('https://api.cloudflare.com/client/v4'+path,{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:data?JSON.stringify(data):undefined});const j=await r.json();if(!j.success)throw Error('Cloudflare '+r.status+' '+JSON.stringify(j.errors));return j.result;
}
