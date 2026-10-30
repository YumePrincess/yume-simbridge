#!/usr/bin/env python3
"""Bounded 8 kHz S16 mono ALSA↔FIFO bridge, matched to the selected USB port."""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time
import module_select

def selected_card(sysroot=Path('/sys')):
    location = module_select.selected_location()
    if location is None: raise RuntimeError('A physical module must be selected')
    bus = location >> 24
    ports = []
    for shift in range(20,-1,-4):
        port = (location >> shift) & 15
        if port: ports.append(str(port))
    usb_name = str(bus)+'-'+'.'.join(ports)
    result = []
    for card in (sysroot/'class/sound').glob('card[0-9]*'):
        parts = card.resolve().parts
        if usb_name in parts: result.append(card.name[4:])
    if len(result) != 1: raise RuntimeError('Selected module has no unique ALSA card; install matching kmod-usb-audio')
    return result[0]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--fifo-rx',required=True)
    parser.add_argument('--fifo-tx',required=True)
    parser.add_argument('--health',required=True)
    args=parser.parse_args()
    card=selected_card()
    options=['-q','-D','hw:'+card+',0','-t','raw','-f','S16_LE','-r','8000','-c','1']
    capture=subprocess.Popen(['arecord']+options,stdout=subprocess.PIPE)
    playback=subprocess.Popen(['aplay']+options,stdin=subprocess.PIPE)
    children=[capture,playback]
    def stop(*_): raise SystemExit(0)
    signal.signal(signal.SIGTERM,stop)
    signal.signal(signal.SIGINT,stop)
    rx=os.open(args.fifo_rx,os.O_RDWR|os.O_NONBLOCK)
    tx=os.open(args.fifo_tx,os.O_RDWR|os.O_NONBLOCK)
    os.set_blocking(capture.stdout.fileno(),False)
    os.set_blocking(playback.stdin.fileno(),False)
    last_capture=0
    received=sent=0
    deadline=time.monotonic()
    try:
        while all(p.poll() is None for p in children):
            now=time.monotonic()
            ready,_,_=select.select([capture.stdout],[],[],max(0,deadline-now))
            if ready:
                chunk=os.read(capture.stdout.fileno(),3200)
                if not chunk: break
                received+=len(chunk); last_capture=time.monotonic()
                try: os.write(rx,chunk)
                except BlockingIOError: pass # Never accumulate latency on an idle FIFO.
            if time.monotonic() >= deadline:
                try: chunk=os.read(tx,320)
                except BlockingIOError: chunk=b''
                chunk=chunk.ljust(320,b'\0')
                try: sent+=os.write(playback.stdin.fileno(),chunk)
                except BlockingIOError: pass
                deadline=max(deadline+.02,time.monotonic())
                health={'ready':last_capture>0 and time.monotonic()-last_capture<2,'updated':int(time.time()*1000),'captureBytes':received,'playbackBytes':sent}
                target=Path(args.health); temp=target.with_suffix('.tmp')
                temp.write_text(json.dumps(health));os.chmod(temp,0o600);temp.replace(target)
    finally:
        for p in children:
            if p.poll() is None:p.terminate()
        for p in children:
            try:p.wait(2)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        os.close(rx);os.close(tx)
    raise SystemExit('ALSA stream stopped')
if __name__=='__main__':main()
