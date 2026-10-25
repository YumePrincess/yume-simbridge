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

if __name__=='__main__':unittest.main()
