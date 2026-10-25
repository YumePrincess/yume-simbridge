#!/usr/bin/env python3
"""Verify a complete staged app and replace the old bundle without merging files."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import uuid
source=Path(sys.argv[1]).resolve()
dest=Path(sys.argv[2]).expanduser().absolute()
if source.name!='Yume SIM Hub.app' or dest.name!='Yume SIM Hub.app':
    raise SystemExit('Unexpected app location')
dest.parent.mkdir(parents=True,exist_ok=True)
stage=dest.parent/('.simhub-install-'+str(uuid.uuid4())+'.app')
backup=dest.parent/('.simhub-previous-'+str(uuid.uuid4())+'.app')
try:
    shutil.copytree(source,stage,symlinks=True)
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(stage)],check=True)
    if dest.exists():os.rename(dest,backup)
    try:os.rename(stage,dest)
    except Exception:
        if backup.exists():os.rename(backup,dest)
        raise
    if backup.exists():shutil.rmtree(backup)
finally:
    if stage.exists():shutil.rmtree(stage)
print('Installed and signature verified:',dest)
