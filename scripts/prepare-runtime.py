#!/usr/bin/env python3
"""Prepare checksum-pinned runtime assets; nothing here runs on an installed Mac."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,tarfile,urllib.request
root=Path(__file__).resolve().parent.parent
cache=root/'Mac/runtime-cache';cache.mkdir(parents=True,exist_ok=True)
lock=json.loads((root/'Mac/runtime-lock.json').read_text())
archive=cache/'python.tar.gz'
if not archive.exists():
    with urllib.request.urlopen(lock['url'],timeout=60) as response, archive.open('wb') as output:shutil.copyfileobj(response,output)
if hashlib.sha256(archive.read_bytes()).hexdigest()!=lock['sha256']:raise SystemExit('Python runtime checksum mismatch')
python=cache/'python'
if not python.exists():
    with tarfile.open(archive) as source:source.extractall(cache,filter='data')
marker=cache/'prepared.json'
identity=json.dumps(lock,sort_keys=True)
if not marker.exists() or marker.read_text()!=identity:
    site=python/'lib/python3.12/site-packages'
    subprocess.run([sys.executable,'-m','pip','install','--upgrade','--no-compile','--no-deps','--only-binary=:all:','--target',str(site),'pyusb=='+lock['pyusb'],'certifi=='+lock['certifi']],check=True)
    marker.write_text(identity)
libusb=Path('/opt/homebrew/lib/libusb-1.0.dylib').resolve()
if hashlib.sha256(libusb.read_bytes()).hexdigest()!=lock['libusb']['sha256']:raise SystemExit('libusb source differs from runtime lock; review before updating the lock')
if (cache/'libusb-1.0.0.dylib').exists():(cache/'libusb-1.0.0.dylib').unlink()
shutil.copy2(libusb,cache/'libusb-1.0.0.dylib')
os.chmod(cache/'libusb-1.0.0.dylib',0o755)
subprocess.run(['/usr/bin/install_name_tool','-id','@loader_path/libusb-1.0.0.dylib',str(cache/'libusb-1.0.0.dylib')],check=True)
shutil.copy2(libusb.parents[1]/'COPYING',cache/'libusb-LICENSE.txt')
print('Standalone Python, pyusb, CA certificates and libusb prepared')
