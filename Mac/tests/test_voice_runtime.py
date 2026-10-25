import sys
from pathlib import Path
import unittest
from unittest.mock import patch, MagicMock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import voice_runtime as runtime

class RouteResetTest(unittest.TestCase):
    def test_fresh_process_stops_actual_owned_route_before_rebuilding(self):
        # The CLI starts with ready=False even when the module still owns a live route.
        runtime._state['ready']=False
        adb=MagicMock()
        with patch.object(runtime,'ADBClient',return_value=adb), patch.object(runtime,'_route_is_stopped',return_value=True), patch.object(runtime,'_voice_shell') as rollback:
            runtime.stop_voice_route()
        self.assertTrue(adb.shell_checked.called,'must inspect/terminate the owned module helper')
        self.assertTrue(rollback.called,'must reset USB audio and restore the voice path')
        self.assertIn('audio_enable',rollback.call_args.args[1])
        adb.close.assert_called_once()


class ModuleADBSelectionTest(unittest.TestCase):
    @staticmethod
    def interface(number, cls=0xff, sub=0x42, protocol=1):
        i=MagicMock()
        i.bInterfaceNumber=number
        i.bInterfaceClass=cls
        i.bInterfaceSubClass=sub
        i.bInterfaceProtocol=protocol
        incoming=MagicMock(bmAttributes=2,bEndpointAddress=0x81)
        outgoing=MagicMock(bmAttributes=2,bEndpointAddress=0x02)
        i.__iter__.return_value=iter([incoming,outgoing])
        return i

    def test_only_module_ids_are_searched_and_actual_adb_interface_is_claimed(self):
        module=MagicMock()
        module.get_active_configuration.return_value=[self.interface(6,cls=1,sub=1,protocol=0),self.interface(5)]
        def find(**kw):
            self.assertTrue(kw['find_all'])
            self.assertIn((kw['idVendor'],kw['idProduct']),[(0x2ca3,0x4006),(0x2c7c,0x0125)])
            return [module] if kw['idVendor']==0x2ca3 else []
        with patch.object(runtime.usb.core,'find',side_effect=find), patch.object(runtime.usb.util,'claim_interface') as claim:
            client=runtime.ADBClient()
        claim.assert_called_once_with(module,5)
        self.assertIs(client.dev,module)

    def test_wrong_adb_protocol_is_never_claimed(self):
        module=MagicMock()
        module.get_active_configuration.return_value=[self.interface(6,protocol=0)]
        with patch.object(runtime.usb.core,'find',side_effect=[[module],[]]), patch.object(runtime.usb.util,'claim_interface') as claim:
            with self.assertRaises(runtime.ADBError):runtime.ADBClient()
        claim.assert_not_called()

    def test_multiple_modules_are_rejected_without_claiming_either(self):
        devices=[MagicMock(),MagicMock()]
        for d in devices:d.get_active_configuration.return_value=[self.interface(5)]
        with patch.object(runtime.usb.core,'find',side_effect=[devices,[]]), patch.object(runtime.usb.util,'claim_interface') as claim:
            with self.assertRaisesRegex(runtime.ADBError,'多个'):runtime.ADBClient()
        claim.assert_not_called()

    def test_module_interface_conflict_is_actionable_and_does_not_run_adb_cli(self):
        module=MagicMock()
        module.get_active_configuration.return_value=[self.interface(5)]
        with patch.object(runtime.usb.core,'find',side_effect=[[module],[]]), patch.object(runtime.usb.util,'claim_interface',side_effect=runtime.usb.core.USBError('busy')), patch.object(runtime.usb.util,'dispose_resources') as dispose:
            with self.assertRaisesRegex(runtime.ADBError,'仅释放该模块'):runtime.ADBClient()
        dispose.assert_called_once_with(module)

if __name__=='__main__':unittest.main()
