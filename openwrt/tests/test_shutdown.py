"""Execute supervisor shutdown against observable fake owned processes."""
import ast
from pathlib import Path
import signal
import subprocess
import types
import unittest

class ShutdownTests(unittest.TestCase):
    def test_engine_finishes_before_at_and_audio_are_signalled(self):
        source=Path(__file__).resolve().parents[2]/'Mac/supervisor.py'
        tree=ast.parse(source.read_text())
        functions=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name in ('cleanup','stop')]
        events=[]
        class Child:
            def __init__(self,pid):self.pid=pid
            def poll(self):return None
            def wait(self,timeout=None):events.append(('finished',self.pid))
        namespace={'stopping':False,'hardware_owned':False,'held':[],'children':[Child(1),Child(2),Child(3)],
          'os':types.SimpleNamespace(killpg=lambda pid,sig:events.append(('signal',pid))),
          'signal':signal,'subprocess':subprocess,'time':types.SimpleNamespace(monotonic=lambda:0),
          'publish_offline':lambda:events.append(('offline',0)),
          'lease':types.SimpleNamespace(release=lambda:events.append(('release',0)))}
        exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),namespace)
        with self.assertRaises(SystemExit):namespace['stop']()
        self.assertEqual(events,[('signal',3),('finished',3),('signal',2),('finished',2),('signal',1),('finished',1),('offline',0),('release',0)])
        namespace['cleanup']()
        self.assertEqual(len(events),8)  # Explicit quit's finally is idempotent.

    def test_lost_lease_cleans_up_then_retries_without_parent_restart(self):
        import threading
        source=Path(__file__).resolve().parents[2]/'Mac/supervisor.py'
        tree=ast.parse(source.read_text())
        loop=tree.body[-1]
        self.assertIsInstance(loop,ast.While)
        events=[]
        namespace={'stopping':False,'ownership_lost':threading.Event(),
                   'time':types.SimpleNamespace(sleep=lambda _:events.append('delay'))}
        def run():
            events.append('run')
            if events.count('run')==1:
                namespace['ownership_lost'].set()
                raise RuntimeError('lease expired')
            self.assertFalse(namespace['ownership_lost'].is_set())
            namespace['stopping']=True
        namespace.update(run_runtime=run,cleanup=lambda:events.append('cleanup'))
        exec(compile(ast.Module(body=[loop],type_ignores=[]),str(source),'exec'),namespace)
        self.assertEqual(events,['run','cleanup','delay','run','cleanup'])

if __name__=='__main__':unittest.main()
