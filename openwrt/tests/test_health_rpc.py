import json
from pathlib import Path
import tempfile
import time
import unittest

class HealthRPCTests(unittest.TestCase):
    def test_fast_health_never_contacts_cloud_and_rejects_stale_state(self):
        source=Path(__file__).resolve().parents[1]/'root/usr/libexec/rpcd/yume-simhub'
        namespace={'__name__':'health_rpc_test'}
        exec(compile(source.read_text(),str(source),'exec'),namespace)
        with tempfile.TemporaryDirectory() as directory:
            health=Path(directory)/'health.json'
            namespace['Path']=lambda _:health
            def unavailable(*args,**kwargs):raise AssertionError('Health must not wait for cloud')
            namespace['cloud']=unavailable
            health.write_text(json.dumps({'updated':time.time()*1000,'modemConnected':True,'sipRegistered':True,'busy':True}))
            self.assertTrue(namespace['execute']('health',{})['local']['busy'])
            health.write_text(json.dumps({'updated':0,'modemConnected':True,'sipRegistered':True,'busy':True}))
            stale=namespace['execute']('health',{})['local']
            self.assertFalse(stale['modemConnected'])
            self.assertFalse(stale['sipRegistered'])
            self.assertFalse(stale['busy'])

if __name__=='__main__':unittest.main()
