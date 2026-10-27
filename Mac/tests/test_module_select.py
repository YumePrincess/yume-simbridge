import os,sys,unittest,plistlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch,MagicMock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import module_select as select
import adb_server
import voice_runtime

class ModuleSelectionTest(unittest.TestCase):
    def test_stable_location_ignores_temporary_usb_address(self):
        for address in [5,17]:
            dev=SimpleNamespace(bus=8,port_numbers=(3,3),address=address)
            self.assertEqual(select.usb_location(dev),137560064)
    def test_ambiguous_auto_refuses_and_selected_missing_never_falls_back(self):
        a=SimpleNamespace(bus=8,port_numbers=(3,3));b=SimpleNamespace(bus=8,port_numbers=(3,4))
        with patch.object(select.usb.core,'find',side_effect=lambda **kw:[a,b] if kw['idVendor']==0x2ca3 else []):
            with patch.dict(os.environ,{'SIMHUB_MODULE_LOCATION':''}):
                with self.assertRaisesRegex(RuntimeError,'Multiple'):select.find_module()
            with patch.dict(os.environ,{'SIMHUB_MODULE_LOCATION':'137560064'}):self.assertIs(select.find_module(),a)
            with patch.dict(os.environ,{'SIMHUB_MODULE_LOCATION':'1'}):self.assertIsNone(select.find_module())
    def test_adb_matches_only_selected_ioreg_location(self):
        raw=plistlib.dumps([{'idVendor':0x2ca3,'idProduct':0x4006,'locationID':137560064},{'idVendor':0x2ca3,'idProduct':0x4006,'locationID':137625600}])
        with patch.object(adb_server.subprocess,'check_output',return_value=raw),patch.dict(os.environ,{'SIMHUB_MODULE_LOCATION':'137560064'}):
            self.assertEqual(adb_server.module_paths(0x2ca3,0x4006),{'137560064X'})
    def test_unselected_device_interfaces_are_never_inspected(self):
        other=MagicMock();other.bus=8;other.port_numbers=(3,4)
        with patch.dict(os.environ,{'SIMHUB_MODULE_LOCATION':'137560064'}),patch.object(voice_runtime.usb.core,'find',side_effect=[[other],[]]),patch.object(voice_runtime.usb.util,'claim_interface') as claim:
            with self.assertRaises(voice_runtime.ADBError):voice_runtime.ADBClient()
        other.get_active_configuration.assert_not_called();claim.assert_not_called()
