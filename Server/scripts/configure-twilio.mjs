import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('../../',import.meta.url)));
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
const sid=process.env.TWILIO_ACCOUNT_SID?.trim()||'',number=process.env.TWILIO_NUMBER?.trim()||'';
let origin='';
try{const url=new URL(process.env.PUBLIC_ORIGIN||'');if(url.protocol!=='https:'||url.username||url.password||url.pathname!=='/'||url.search||url.hash)throw Error();origin=url.origin;}catch{throw Error('Set PUBLIC_ORIGIN to an HTTPS origin without credentials or a path');}
if(!/^AC[0-9a-fA-F]{32}$/.test(sid))throw Error('Set TWILIO_ACCOUNT_SID to your Account SID');
if(!/^\+[1-9]\d{6,14}$/.test(number))throw Error('Set TWILIO_NUMBER in E.164 format');
const token=(await fs.readFile('.secrets/twilio-token','utf8')).trim();
if(!/^[a-f0-9]{32}$/.test(token))throw Error('Invalid Twilio token format');
async function api(path,data){const r=await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/${path}.json`,{method:data?'POST':'GET',headers:{Authorization:'Basic '+Buffer.from(sid+':'+token).toString('base64'),'Content-Type':'application/x-www-form-urlencoded'},body:data?new URLSearchParams(data):undefined});const j=await r.json();if(!r.ok)throw Error('Twilio '+r.status+' code '+j.code);return j;}
let state;try{state=JSON.parse(await fs.readFile('.secrets/twilio-setup.json','utf8'));}catch{state={password:crypto.randomBytes(24).toString('base64url')+'Aa1!'};}
async function save(){await fs.writeFile('.secrets/twilio-setup.json',JSON.stringify(state),{mode:0o600});}
const numbers=await api('IncomingPhoneNumbers');

const phone=numbers.incoming_phone_numbers.find(n=>n.phone_number===number);if(!phone)throw Error('Requested number missing');
if(!state.phoneBackup){state.phoneBackup={sid:phone.sid,voice_url:phone.voice_url,voice_method:phone.voice_method,voice_application_sid:phone.voice_application_sid};await save();}
if(!state.list){const l=await api('SIP/CredentialLists',{FriendlyName:'Yume SIMBridge'});state.list=l.sid;await save();}
if(!state.credential){const c=await api(`SIP/CredentialLists/${state.list}/Credentials`,{Username:'simhub',Password:state.password});state.credential=c.sid;await save();}
if(state.domain){const current=await api(`SIP/Domains/${state.domain}`);if(current.domain_name!=='yume-simbridge.sip.twilio.com'){state.domain='';await save();}}
if(!state.domain){const d=await api('SIP/Domains',{DomainName:'yume-simbridge.sip.twilio.com',FriendlyName:'Yume SIMBridge',VoiceUrl:origin+'/twilio/cellular',VoiceMethod:'POST',SipRegistration:'true'});state.domain=d.sid;await save();}
for(const category of ['Calls','Registrations']){const path=`SIP/Domains/${state.domain}/Auth/${category}/CredentialListMappings`;const current=await api(path);if(!current.contents?.some(x=>(x.credential_list_sid===state.list||x.sid===state.list))&&!Object.values(current).some(v=>Array.isArray(v)&&v.some(x=>(x.credential_list_sid===state.list||x.sid===state.list))))await api(path,{CredentialListSid:state.list});}
const d=await api(`SIP/Domains/${state.domain}`);
console.log('SIP domain configured:',d.domain_name,'registration:',d.sip_registration);
// Only switch voice after the Worker is deployed and its signature checks pass.
if(process.argv.includes('--activate')){await api(`IncomingPhoneNumbers/${phone.sid}`,{VoiceUrl:origin+'/twilio/voice',VoiceMethod:'POST',VoiceApplicationSid:'',VoiceFallbackUrl:''});console.log('Requested phone number Voice URL configured.');}
