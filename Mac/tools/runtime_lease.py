"""Fail-closed single-runtime ownership shared by macOS and OpenWrt."""
import json
import os
from pathlib import Path
import signal
import threading
import time
import urllib.request
import urllib.error
import uuid

class RuntimeLease:
    def __init__(self, config, identity_dir, health_dir=None):
        self.config = config
        self.health_dir = Path(health_dir) if health_dir else None
        path = Path(identity_dir) / 'device-id'
        if not path.exists():
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as out: out.write(str(uuid.uuid4()))
        self.device = path.read_text().strip()
        self.session = str(uuid.uuid4())
        self.epoch = None
        self.deadline = 0
        self.done = threading.Event()

    def request(self, operation, **extra):
        body = dict(protocolVersion=2, device=self.device, session=self.session, epoch=self.epoch, **extra)
        request = urllib.request.Request(self.config['origin']+'/edge/runtime/'+operation,
            data=json.dumps(body).encode(), headers={'Authorization':'Bearer '+self.config['token'], 'Content-Type':'application/json', 'User-Agent':'YumeSIMBridge/27.3.0'})
        with urllib.request.urlopen(request, timeout=4) as response:
            return json.loads(response.read(16384))

    def acquire(self):
        started = time.monotonic()
        reply = self.request('acquire', platform='openwrt' if os.uname().sysname == 'Linux' else 'macos', label=os.uname().nodename)
        self.epoch = reply['epoch']
        if reply.get('protocolVersion') != 2:
            self.request('release')
            raise RuntimeError('Cloud runtime protocol update required')
        self.deadline = started + 65
        os.environ.update(SIMHUB_LEASE_DEVICE=self.device, SIMHUB_LEASE_SESSION=self.session, SIMHUB_LEASE_EPOCH=str(self.epoch))

    def headers(self):
        return {'X-SimHub-Device':self.device,'X-SimHub-Session':self.session,'X-SimHub-Epoch':str(self.epoch)}

    def renew(self):
        started = time.monotonic()
        busy = False
        if self.health_dir:
            try:
                h = json.loads((self.health_dir/'edge-health.json').read_text())
                busy = h.get('busy') is True and 0 <= time.time()*1000-h.get('updated',0) < 12000
            except (OSError, ValueError): pass
        self.request('renew', busy=busy)
        self.deadline = started + 65

    def watch(self, emergency_stop, on_lost=None):
        def run():
            while not self.done.wait(max(0, min(10, self.deadline-time.monotonic()))):
                if time.monotonic() >= self.deadline:
                    break
                try:
                    self.renew()
                except urllib.error.HTTPError as error:
                    if error.code in (401,403,409): self.deadline = 0
                except Exception:
                    # HTTP rejection means revoked. Network errors get a short
                    # retry window, bounded by the last acknowledged lease.
                    if time.monotonic() < self.deadline:
                        continue
                if time.monotonic() >= self.deadline:
                    break
            else:
                return
            # Cleanup must finish before another session can acquire ownership.
            # The supervisor can recover in place instead of depending on its
            # parent to restart a process that exited successfully.
            if on_lost is None: os.kill(os.getpid(), signal.SIGTERM)
            else: on_lost()
            if not self.done.wait(12): emergency_stop()
        threading.Thread(target=run, daemon=True).start()

    def release(self):
        self.done.set()
        if self.epoch is not None:
            try: self.request('release')
            except Exception: pass
