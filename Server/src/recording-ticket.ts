import { SignJWT, jwtVerify } from "jose";
import { unb64, fail } from "./util";
async function ticketKey(env:Env){
 const raw=unb64(env.MASTER_KEY),label=new TextEncoder().encode("simhub/recording-ticket/v1");
 const bytes=new Uint8Array(raw.length+label.length);bytes.set(raw);bytes.set(label,raw.length);
 return new Uint8Array(await crypto.subtle.digest("SHA-256",bytes));
}
export async function recordingTicket(env:Env,sid:string){
 const token=await new SignJWT({sid}).setProtectedHeader({alg:"HS256"}).setIssuer(env.PUBLIC_ORIGIN).setAudience("recording-playback").setIssuedAt().setExpirationTime("5m").setJti(crypto.randomUUID()).sign(await ticketKey(env));
 const url=env.PUBLIC_ORIGIN+"/recording/"+token;
 return {url,downloadURL:url+"?download",expires:Date.now()+300000};
}
export async function recordingFromTicket(env:Env,token:string){
 try {
  if(!/^[A-Za-z0-9_.-]{80,2048}$/.test(token))fail("Invalid recording ticket",403);
  const {payload}=await jwtVerify(token,await ticketKey(env),{algorithms:["HS256"],issuer:env.PUBLIC_ORIGIN,audience:"recording-playback",maxTokenAge:"5m"});
  if(typeof payload.sid!=="string"||!/^RE[a-f0-9]{32}$/.test(payload.sid))fail("Invalid recording ticket",403);
  return payload.sid;
 }catch{fail("Recording playback link expired or invalid",403);}
}
