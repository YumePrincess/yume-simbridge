#!/usr/bin/env python3
"""Verify a complete staged app and replace the old bundle without merging files."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import uuid
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"Mac/tools"))
from update_cleanup import clean_installation,clean_workspace,update_workspace
source=Path(sys.argv[1]).resolve()
dest=Path(sys.argv[2]).expanduser().absolute()
if source.name!='Yume SIMBridge.app' or dest.name not in ('Yume SIMBridge.app', 'Yume SIM Hub.app'):
    raise SystemExit('Unexpected app location')
dest.parent.mkdir(parents=True,exist_ok=True)
stage=dest.parent/('.simhub-install-'+str(uuid.uuid4())+'.app')
backup=dest.parent/('.simhub-previous-'+str(uuid.uuid4())+'.app')
with update_workspace(Path.home()/'Library/Application Support/YumeSimHub/Updates') as workspace:
    try:
        shutil.copytree(source,stage,symlinks=True)
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(stage)],check=True)
        if dest.exists():os.rename(dest,backup)
        try:os.rename(stage,dest)
        except Exception:
            if backup.exists():os.rename(backup,dest)
            raise
        if backup.exists():shutil.rmtree(backup)
        clean_installation(dest)
    finally:
        if stage.exists():shutil.rmtree(stage)
    clean_workspace(workspace)
print('Installed and signature verified:',dest)
