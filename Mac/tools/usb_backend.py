"""Load the bundled libusb, without consulting Homebrew or another disk."""
from pathlib import Path
import usb.backend.libusb1
library=Path(__file__).resolve().parents[1]/'bin/libusb-1.0.0.dylib'
if library.exists():
    backend=usb.backend.libusb1.get_backend(find_library=lambda _:str(library))
    if backend is None:raise RuntimeError('Bundled libusb could not be loaded')
else:
    # Source development only. The release build always bundles libusb.
    backend=usb.backend.libusb1.get_backend()
