#!/usr/bin/env python3
"""Linux exec wrapper: terminate this child if its owning supervisor dies."""
import ctypes
import os
import signal
import sys
parent=int(sys.argv[1])
libc=ctypes.CDLL(None,use_errno=True)
if libc.prctl(1,signal.SIGTERM,0,0,0)!=0:raise OSError(ctypes.get_errno(),'PR_SET_PDEATHSIG failed')
if os.getppid()!=parent:raise SystemExit('Owner already exited')
os.execvpe(sys.argv[2],sys.argv[2:],os.environ)
