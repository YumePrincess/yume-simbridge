import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Mac/tools'))
from runtime_lease import RuntimeLease

class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.lease=RuntimeLease({'origin':'https://worker.example.com','token':'x'*64},self.temp.name)
    def test_identity_persists_but_each_process_has_a_new_session(self):
        other=RuntimeLease(self.lease.config,self.temp.name)
        self.assertEqual(other.device,self.lease.device)
        self.assertNotEqual(other.session,self.lease.session)
        self.assertEqual((Path(self.temp.name)/'device-id').stat().st_mode & 0o777,0o600)
    def test_acquire_uses_request_start_to_allow_shutdown_before_server_expiry(self):
        with patch.object(self.lease,'request',return_value={'epoch':7}),patch('runtime_lease.time.monotonic',return_value=100),patch.dict(os.environ):
            self.lease.acquire()
            self.assertEqual(self.lease.deadline,165)
            self.assertEqual(os.environ['SIMHUB_LEASE_EPOCH'],'7')
    def test_failed_renew_cannot_extend_local_deadline(self):
        self.lease.deadline=100
        with patch.object(self.lease,'request',side_effect=OSError('offline')):
            with self.assertRaises(OSError):self.lease.renew()
        self.assertEqual(self.lease.deadline,100)
    def test_watchdog_revocation_signals_stop_then_forces_stalled_cleanup(self):
        import urllib.error
        class Events:
            calls=0
            def wait(self,seconds):
                self.calls+=1
                return False
        self.lease.done=Events()
        error=urllib.error.HTTPError('https://example.invalid',409,'revoked',{},None)
        with patch.object(self.lease,'request',side_effect=error),patch('runtime_lease.threading.Thread') as thread,patch('runtime_lease.os.kill') as kill:
            self.lease.watch(lambda: None)
            run=thread.call_args.kwargs['target']
            forced=[]
            # Override emergency callback via a second watch construction.
            self.lease.watch(lambda: forced.append(True))
            run=thread.call_args.kwargs['target'];run()
            kill.assert_called_once()
            self.assertEqual(forced,[True])

if __name__=='__main__':unittest.main()
