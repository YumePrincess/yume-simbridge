import PostalMime from 'postal-mime';
import {config,number} from './config';
import {enqueue,limit} from './store';
import {readBytes,enc} from './util';
export async function receive(message:ForwardableEmailMessage,env:Env) {
 try {
  const c=await config(env);
  if(message.to.toLowerCase()!==env.EMAIL_ADDRESS||!c.emailEnabled)throw Error('Email SMS disabled');
  if(!c.allowedSenders.includes(message.from.toLowerCase()))throw Error('Sender not permitted');
  if(message.rawSize>131072)throw Error('Email too large');
  const raw=await readBytes(new Request('https://mail.invalid',{method:'POST',body:message.raw,duplex:'half'} as RequestInit),131072);
  const mail=await PostalMime.parse(raw);
  if(mail.from?.address?.toLowerCase()!==message.from.toLowerCase())throw Error('Envelope sender does not match From');
  // Only the first authentication result added by Cloudflare is trusted.
  const auth=mail.headers.find(h=>h.key==='authentication-results')?.value||'';
  const domain=message.from.toLowerCase().split('@')[1];
  if(!/^mx\.cloudflare\.net\s*;/i.test(auth)||!/(?:^|;)\s*dmarc=pass\b/i.test(auth)||!auth.toLowerCase().includes('header.from='+domain))throw Error('Cloudflare DMARC authentication required');
  const to=number(mail.subject?.trim());const body=mail.text?.trim();
  if(!body||body.length>2000)throw Error('Use text/plain body, 1–2000 characters');
  await limit(env,'email:'+message.from,30,3600);
  const digest=await crypto.subtle.digest('SHA-256',raw);
  const id='mail-'+Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
  await enqueue(env,id,'sms',{to,body,source:'email',from:message.from});
 } catch(e){message.setReject(e instanceof Error?e.message:'Email rejected');}
}
