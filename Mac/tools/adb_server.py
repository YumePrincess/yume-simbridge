"""Module-only access to an already running local ADB server; never starts/kills it."""
import module_select
import os
import re
import socket
import struct
import subprocess
import time

class ServerError(RuntimeError): pass

def module_paths(vendor, product):
    if os.uname().sysname == 'Linux':
        from pathlib import Path
        found = set()
        for path in Path('/sys/bus/usb/devices').glob('*'):
            try:
                if int((path/'idVendor').read_text(),16)!=vendor or int((path/'idProduct').read_text(),16)!=product: continue
                bus, ports = path.name.split('-',1)
                location = int(bus)<<24
                for index, port in enumerate(ports.split('.')):
                    if index>=6 or not 0<int(port)<16: raise ValueError('Unsupported topology')
                    location |= int(port) << (20-4*index)
                if module_select.selected_location() in (None,location): found.add(path.name)
            except (OSError,ValueError): continue
        return found
    import plistlib
    # Native macOS ADB reports IORegistry's USB locationID, e.g. 137560064X.
    raw = subprocess.check_output(['/usr/sbin/ioreg', '-a', '-r', '-c', 'IOUSBHostDevice'], timeout=4)
    found = set()
    def visit(item):
        if isinstance(item, dict):
            if item.get('idVendor') == vendor and item.get('idProduct') == product and isinstance(item.get('locationID'), int):
                selected = module_select.selected_location()
                if selected is None or selected == item['locationID']:
                    found.add(str(item['locationID']) + 'X')
            for value in item.values(): visit(value)
        elif isinstance(item, list):
            for value in item: visit(value)
    visit(plistlib.loads(raw))
    return found

def exact(sock, count):
    result = bytearray()
    while len(result) < count:
        chunk = sock.recv(count-len(result))
        if not chunk: raise ServerError('ADB server closed the connection')
        result.extend(chunk)
    return bytes(result)

def request(sock, service):
    data = service.encode()
    if len(data)>65535: raise ServerError('ADB service request too long')
    sock.sendall(f'{len(data):04x}'.encode()+data)
    status = exact(sock,4)
    if status == b'FAIL':
        size = int(exact(sock,4),16)
        detail = exact(sock,size).decode(errors='replace')
        raise ServerError('ADB server rejected module request: '+detail[:240])
    if status != b'OKAY': raise ServerError('Invalid ADB server status')

def select_transport(listing, paths):
    matches = []
    for line in listing.splitlines():
        match = re.match(r'^.*?\s+(device|offline|unauthorized)\s+(.*)$',line)
        if not match or match[1] != 'device': continue
        attributes = dict(re.findall(r'(\w+):([^\s]+)',match[2]))
        if attributes.get('usb') in paths and attributes.get('transport_id','').isdigit():
            matches.append(int(attributes['transport_id']))
    if len(matches)!=1: raise ServerError('Cannot uniquely match the physical DJI module to a local ADB transport')
    return matches[0]

class ServerADB:
    def __init__(self, vendor, product):
        self.paths = module_paths(vendor,product)
        if len(self.paths)!=1: raise ServerError('Cannot uniquely identify the DJI USB location')
        self.vendor, self.product = vendor,product
        self.transport = select_transport(self.query('host:devices-l'),self.paths)
        # Only read the physically matched module. No commands probe other devices.
        text,status = self.shell_checked('cat /sys/class/android_usb/android0/idVendor; cat /sys/class/android_usb/android0/idProduct',5)
        ids = text.split()
        if status or len(ids)!=2 or [int(x,16) for x in ids]!=[vendor,product]:
            raise ServerError('Local ADB device identity does not match DJI USB IDs')

    @staticmethod
    def connect(timeout=5):
        # Do not honor external host/port env vars, spawn adb, or depend on its binary.
        return socket.create_connection(('127.0.0.1',5037),timeout=timeout)

    def query(self, service):
        with self.connect() as sock:
            request(sock,service)
            size=int(exact(sock,4),16)
            return exact(sock,size).decode(errors='replace')

    def stream(self, service, timeout):
        # Recheck location on every operation, including after a server restart.
        path=self.query(f'host-transport-id:{self.transport}:get-devpath')
        if path.removeprefix('usb:') not in self.paths:
            raise ServerError('ADB transport changed; refusing to access a different device')
        sock=self.connect(timeout)
        try:
            request(sock,f'host:transport-id:{self.transport}')
            # A stale transport ID must not be reused for a phone after a USB
            # hot-swap or server restart, including the binary sync path.
            if module_paths(self.vendor,self.product)!=self.paths:
                raise ServerError('Physical module changed; service refused')
            current=self.query(f'host-transport-id:{self.transport}:get-devpath')
            if current.removeprefix('usb:') not in self.paths:
                raise ServerError('ADB transport changed; service refused')
            request(sock,service)
            return sock
        except Exception:
            sock.close()
            raise

    def shell_checked(self, command, timeout=8):
        token=os.urandom(12).hex()
        # Check IDs in the SAME shell before executing any state-changing command.
        gate=f'test "$(cat /sys/class/android_usb/android0/idVendor)" = "{self.vendor:04x}" && test "$(cat /sys/class/android_usb/android0/idProduct)" = "{self.product:04x}"'
        wrapped=f'if {gate}; then {{ {command}; }}; __simhub_status=$?; else __simhub_status=125; fi; printf "\\n__SIMHUB_{token}_%u__\\n" "$__simhub_status"'
        output=bytearray()
        deadline=time.monotonic()+timeout
        with self.stream('shell:'+wrapped,timeout) as sock:
            while True:
                remaining=deadline-time.monotonic()
                if remaining<=0: raise ServerError('Module ADB shell timed out')
                sock.settimeout(remaining)
                chunk=sock.recv(65536)
                if not chunk: break
                output.extend(chunk)
                if len(output)>2*1024*1024: raise ServerError('Module ADB shell output too large')
        marker=f'__SIMHUB_{token}_'.encode()
        index=output.rfind(marker)
        if index<0: raise ServerError('Module ADB shell did not return status')
        status=int(bytes(output[index+len(marker):]).split(b'__',1)[0])
        if status==125: raise ServerError('Module ADB identity changed; command refused')
        return output[:index].decode(errors='replace'),status

    def push(self,data,remote_path,mode,timeout=30):
        if ',' in remote_path or '\x00' in remote_path: raise ServerError('Invalid module push path')
        deadline=time.monotonic()+timeout
        with self.stream('sync:',timeout) as sock:
            def send(payload):
                remaining=deadline-time.monotonic()
                if remaining<=0: raise ServerError('Module ADB push timed out')
                sock.settimeout(remaining); sock.sendall(payload)
            name=f'{remote_path},{mode}'.encode()
            send(b'SEND'+struct.pack('<I',len(name))+name)
            for offset in range(0,len(data),65536):
                chunk=data[offset:offset+65536]
                send(b'DATA'+struct.pack('<I',len(chunk))+chunk)
            send(b'DONE'+struct.pack('<I',int(time.time())))
            sock.settimeout(max(.01,deadline-time.monotonic()))
            status=exact(sock,4); size=struct.unpack('<I',exact(sock,4))[0]
            if status!=b'OKAY' or size!=0: raise ServerError('Module rejected ADB push')
            send(b'QUIT'+struct.pack('<I',0))

    def close(self): pass  # Each operation closes only its own smart socket.
