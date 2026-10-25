#!/usr/bin/env python3
"""Own only this app's processes; terminate all children when the app stops."""
import argparse
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import shutil
import json
import urllib.request
import threading
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"]="1"

parser=argparse.ArgumentParser()
parser.add_argument('--config',required=True)
parser.add_argument('--data',required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parent
data=Path(args.data); data.mkdir(mode=0o700,parents=True,exist_ok=True)
os.umask(0o077)
children=[]
stopping=False

def publish_offline():
    status={'modemConnected':False,'voiceReady':False,'sipRegistered':False,'busy':False,'sim':'unavailable'}
    (data/'edge-health.json').write_text(json.dumps(dict(status,updated=int(time.time()*1000))))
    try:
        cfg=json.loads(Path(args.config).read_text())
        req=urllib.request.Request(cfg['origin']+'/edge/sync',data=json.dumps(status).encode(),headers={'Authorization':'Bearer '+cfg['token'],'Content-Type':'application/json','User-Agent':'YumeSIMHub/27.2.0'})
        urllib.request.urlopen(req,timeout=4).close()
    except Exception: pass


def stop(*_):
    global stopping
    stopping=True
    publish_offline()
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
    deadline=time.monotonic()+10
    for child in reversed(children):
        try: child.wait(max(.1,deadline-time.monotonic()))
        except subprocess.TimeoutExpired: child.kill()
    raise SystemExit(0)

signal.signal(signal.SIGTERM,stop)
signal.signal(signal.SIGINT,stop)

def start(command,**kw):
    p=subprocess.Popen(command,**kw)
    children.append(p)
    return p

publish_offline()

# A reboot can take a minute to enumerate USB; do not settle into SMS-only mode prematurely.
sys.path.insert(0,str(root/"tools"))
import usb_backend
import usb.core
for _ in range(90):
    if usb.core.find(idVendor=0x2CA3,idProduct=0x4006) is not None:break
    time.sleep(1)
cache=data/'module-runtime'
cache.mkdir(mode=0o700,exist_ok=True)
os.environ['SIMHUB_VOICE_RUNTIME']=str(cache)
for asset in (root/'tools/voice-runtime').glob('*'):
    if asset.is_file() and not (cache/asset.name).exists():
        shutil.copy2(asset,cache/asset.name)
sys.path.insert(0,str(root/'tools'))
import voice_runtime
voice=False
try:
    if not voice_runtime.runtime_installed()[0]:
        voice_runtime.provision_runtime()
    voice_runtime.stop_voice_route()
    voice_runtime.ensure_voice_route(force=True)
    voice=True
except Exception as e:
    print('Voice runtime unavailable: '+str(e),flush=True)

at=start([sys.executable,'-s','-B','-u',str(root/'tools/at_pty_bridge.py')],stdout=subprocess.PIPE,text=True)
if not select.select([at.stdout],[],[],30)[0]:
    print('AT bridge did not become ready',flush=True);stop()
tty=at.stdout.readline().strip()
if not tty.startswith('/dev/'):
    print('AT bridge failed',flush=True);stop()
command=[str(root/'bin/simhub-edge'),'--config',args.config,'--data',str(data),'--tty',tty,'--python',sys.executable,'--route',str(root/'tools/reset_route.py')]
if voice:
    rx=data/'rx.fifo';tx=data/'tx.fifo'
    for fifo in [rx,tx]:
        if fifo.exists():fifo.unlink()
        os.mkfifo(fifo,0o600)
    # RDWR handles let CoreAudio open both pipes before the first call arrives.
    held=[os.open(str(f),os.O_RDWR|os.O_NONBLOCK) for f in [rx,tx]]
    audio=start([str(root/'bin/voice-audio-bridge'),'--fifo-rx',str(rx),'--fifo-tx',str(tx),'--health',str(data/'audio-health.json')])
    command+=['--rx',str(rx),'--tx',str(tx)]
edge=start(command)
try:
    while not stopping:
        if usb.core.find(idVendor=0x2CA3,idProduct=0x4006) is None:
            print('USB module disconnected; restarting runtime',flush=True)
            break
        if any(p.poll() is not None for p in children):
            print('Runtime component stopped; restart required',flush=True)
            break
        time.sleep(1)
finally: stop()
