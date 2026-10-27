"""One physical USB port shared by AT, ADB and audio. Never silently switch SIMs."""
import os
import usb.core
IDS = ((0x2CA3, 0x4006), (0x2C7C, 0x0125))

def selected_location():
    value = os.environ.get('SIMHUB_MODULE_LOCATION', '')
    if not value: return None
    result = int(value, 0)
    if not 0 < result <= 0xffffffff: raise RuntimeError('Invalid module USB location')
    return result

def usb_location(dev):
    # Darwin libusb exposes locationID as bus + up to six 4-bit port numbers.
    # Unlike USB address this identity survives a module reboot/re-enumeration.
    ports = dev.port_numbers
    if not isinstance(dev.bus, int) or not isinstance(ports, (list, tuple)) or not 0 < len(ports) <= 6:
        raise RuntimeError('Cannot identify module USB port')
    result = dev.bus << 24
    for index, port in enumerate(ports):
        if not isinstance(port, int) or not 0 < port < 16: raise RuntimeError('Invalid USB topology')
        result |= port << (20 - 4 * index)
    return result

def matches(dev):
    selected = selected_location()
    return selected is None or usb_location(dev) == selected

def find_module(backend=None):
    devices = []
    for vendor, product in IDS:
        for dev in usb.core.find(find_all=True, idVendor=vendor, idProduct=product, backend=backend):
            if matches(dev): devices.append(dev)
    if len(devices) > 1: raise RuntimeError('Multiple DJI modules: choose a USB port in the App')
    return devices[0] if devices else None
