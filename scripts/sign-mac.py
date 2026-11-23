#!/usr/bin/env python3
"""Sign all bundled code with one persistent, project-only local identity.

No login/system keychain, trust-root policy, or runtime credential store is changed.
"""
from pathlib import Path
import hashlib, os, re, secrets, shlex, subprocess, sys, tempfile

folder=Path.home()/'Library/Application Support/YumeSimHub/Signing'
folder.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(folder,0o700)
keychain=folder/'build-signing.keychain-db'
password_file=folder/'keychain-password'
cert=folder/'signer.pem'

def run(args):
    result=subprocess.run([str(x) for x in args],capture_output=True,text=True)
    if result.returncode:
        # Never include command arguments: some security subcommands take passwords.
        raise SystemExit('Signing operation failed: '+result.stderr.strip()[:600])
    return result.stdout

if not password_file.exists():
    password_file.write_text(secrets.token_urlsafe(40));os.chmod(password_file,0o600)
password=password_file.read_text().strip()
if not keychain.exists():
    previous=shlex.split(run(['/usr/bin/security','list-keychains','-d','user']))
    try:run(['/usr/bin/security','create-keychain','-p',password,keychain])
    finally:run(['/usr/bin/security','list-keychains','-d','user','-s',*previous])
os.chmod(keychain,0o600)
run(['/usr/bin/security','unlock-keychain','-p',password,keychain])
run(['/usr/bin/security','set-keychain-settings','-lut','21600',keychain])
if not cert.exists():
    openssl=Path('/opt/homebrew/opt/openssl@3/bin/openssl')
    if not openssl.exists():raise SystemExit('Build requires OpenSSL 3 (runtime does not)')
    with tempfile.TemporaryDirectory(dir=folder) as stage:
        stage=Path(stage)
        config=stage/'openssl.cnf'
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Yume SIM Hub Local Signing\nO=Yume SIM Hub\n[ext]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=codeSigning\n')
        run([openssl,'req','-new','-x509','-newkey','rsa:3072','-sha256','-days','3650','-nodes','-config',config,'-keyout',stage/'key.pem','-out',stage/'cert.pem'])
        run([openssl,'pkcs12','-export','-legacy','-name','Yume SIM Hub Local Signing','-inkey',stage/'key.pem','-in',stage/'cert.pem','-out',stage/'identity.p12','-passout','file:'+str(password_file)])
        run(['/usr/bin/security','import',stage/'identity.p12','-k',keychain,'-P',password,'-T','/usr/bin/codesign','-T','/usr/bin/security'])
        cert.write_bytes((stage/'cert.pem').read_bytes());os.chmod(cert,0o600)
    run(['/usr/bin/security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',password,keychain])
der=run(['/usr/bin/openssl','x509','-in',cert,'-fingerprint','-sha1','-noout'])
fingerprint=der.split('=',1)[1].replace(':','').strip().upper()
requirement='designated => identifier "zone.yume.simhub" and certificate leaf = H"'+fingerprint+'"'
if len(sys.argv)<2 or sys.argv[1]=='--prepare':
    print('Persistent signing identity ready: '+fingerprint)
    sys.exit(0)
app=Path(sys.argv[1]).resolve()
if app.name not in ('Yume SIMBridge.app', 'Yume SIM Hub.app'):raise SystemExit('Unexpected app bundle')
import plistlib
plist=app/'Contents/Info.plist'
info=plistlib.loads(plist.read_bytes());info['SIMHubSignerFingerprint']=fingerprint;plist.write_bytes(plistlib.dumps(info))
base=['/usr/bin/codesign','--force','--timestamp=none','--sign',fingerprint,'--keychain',str(keychain),'--identifier','zone.yume.simhub','--requirements','='+requirement]
seen=set();signed=0
for path in sorted(app.rglob('*'),key=lambda p:len(p.parts),reverse=True):
    if not path.is_file() or path.is_symlink():continue
    with path.open('rb') as f:magic=f.read(4)
    if magic not in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']:continue
    inode=path.stat().st_ino
    if inode in seen:continue
    seen.add(inode);os.chmod(path,path.stat().st_mode|0o200);run([*base,path]);signed+=1
run([*base,app])
run(['/usr/bin/codesign','--verify','--deep','--strict',app])
print('Signed app and '+str(signed)+' bundled binaries with a stable certificate requirement')
