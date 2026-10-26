import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from runtime_health import AudioWatchdog

class AudioWatchdogTest(unittest.TestCase):
    def probe(self,w,t,audio=True,voice=True,busy=False):
        return w.check({'modemConnected':True,'busy':busy,'updated':(100+t)*1000}, {'ready':audio,'updated':(100+t)*1000},voice,100+t,t)
    def test_initial_audio_failure_and_stale_helper_trigger_recovery(self):
        for startup in [True,False]:
            w=AudioWatchdog()
            self.assertFalse(self.probe(w,0,audio=False,voice=not startup))
            self.assertFalse(self.probe(w,14,audio=False,voice=not startup))
            self.assertTrue(self.probe(w,15,audio=False,voice=not startup))
    def test_idle_suspended_but_healthy_audio_is_ready(self):
        w=AudioWatchdog()
        for t in [0,15,1000]:self.assertFalse(self.probe(w,t))
    def test_active_call_and_recovered_health_reset_failure_window(self):
        w=AudioWatchdog()
        self.probe(w,0,audio=False)
        self.assertFalse(self.probe(w,20,audio=False,busy=True))
        self.assertFalse(self.probe(w,21,audio=False))
        self.assertFalse(self.probe(w,30))
        self.assertFalse(self.probe(w,31,audio=False))
        self.assertTrue(self.probe(w,46,audio=False))
    def test_stale_or_offline_edge_is_not_proof_of_idle(self):
        w=AudioWatchdog()
        for t in [0,50]:self.assertFalse(w.check({'updated':0,'modemConnected':True}, {},True,100,t))
