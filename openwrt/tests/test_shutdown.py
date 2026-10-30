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
        stop=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='stop')
        events=[]
        class Child:
            def __init__(self,pid):self.pid=pid
            def poll(self):return None
            def wait(self,timeout=None):events.append(('finished',self.pid))
        namespace={'stopping':False,'children':[Child(1),Child(2),Child(3)],
          'os':types.SimpleNamespace(killpg=lambda pid,sig:events.append(('signal',pid))),
          'signal':signal,'subprocess':subprocess,'time':types.SimpleNamespace(monotonic=lambda:0),
          'publish_offline':lambda:events.append(('offline',0)),
          'lease':types.SimpleNamespace(release=lambda:events.append(('release',0)))}
        exec(compile(ast.Module(body=[stop],type_ignores=[]),str(source),'exec'),namespace)
        with self.assertRaises(SystemExit):namespace['stop']()
        self.assertEqual(events,[('signal',3),('finished',3),('signal',2),('finished',2),('signal',1),('finished',1),('offline',0),('release',0)])

if __name__=='__main__':unittest.main()
