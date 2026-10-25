#!/usr/bin/env python3
"""Install a user-selected, signed update ZIP without mounting another volume."""
from pathlib import Path, PurePosixPath
import argparse, os, plistlib, shutil, stat, subprocess, tempfile, uuid, zipfile

parser=argparse.ArgumentParser()
parser.add_argument('--archive',required=True)
parser.add_argument('--destination',required=True)
parser.add_argument('--signer',required=True)
parser.add_argument('--current-build',type=int,required=True)
args=parser.parse_args()
if len(args.signer)!=40 or any(c not in '0123456789ABCDEFabcdef' for c in args.signer):raise SystemExit('Invalid signing identity')
destination=Path(args.destination).absolute()
if destination.name!='Yume SIM Hub.app':raise SystemExit('Unexpected application destination')
workspace=Path.home()/'Library/Application Support/YumeSimHub/Updates'
workspace.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(workspace,0o700)
with tempfile.TemporaryDirectory(dir=workspace) as temporary:
    temporary=Path(temporary)
    with zipfile.ZipFile(args.archive) as archive:
        entries=archive.infolist()
        if len(entries)>20000 or sum(e.file_size for e in entries)>1024**3:raise SystemExit('Update archive is too large')
        for entry in entries:
            parts=PurePosixPath(entry.filename)
            mode=entry.external_attr>>16
            if parts.is_absolute() or '..' in parts.parts or '\\' in entry.filename or stat.S_ISLNK(mode):raise SystemExit('Unsafe update archive')
            if not parts.parts or parts.parts[0]=='__MACOSX':continue
            if parts.parts[0]!='Yume SIM Hub.app':raise SystemExit('Unexpected update archive contents')
            target=temporary.joinpath(*parts.parts)
            if entry.is_dir():target.mkdir(parents=True,exist_ok=True);continue
            if entry.file_size>128*1024**2:raise SystemExit('Update file is too large')
            target.parent.mkdir(parents=True,exist_ok=True)
            # All paths are relative, symlinks are forbidden, and the parent is private.
            with archive.open(entry) as source, target.open('xb') as output:shutil.copyfileobj(source,output)
            os.chmod(target,0o755 if mode&0o111 else 0o644)
    app=temporary/'Yume SIM Hub.app'
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier')!='zone.yume.simhub' or int(info.get('CFBundleVersion','0'))<=args.current_build:raise SystemExit('Update is not a newer Yume SIM Hub build')
    if info.get('LSMinimumSystemVersion')!='26.0' or info.get('LSArchitecturePriority')!=['arm64']:raise SystemExit('Unexpected update platform')
    requirement='=identifier "zone.yume.simhub" and certificate leaf = H"'+args.signer+'"'
    checked=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','-R',requirement,str(app)],capture_output=True,text=True)
    if checked.returncode:raise SystemExit('Update signature does not match the installed application')
    stage=destination.parent/('.simhub-install-'+str(uuid.uuid4())+'.app')
    backup=destination.parent/('.simhub-previous-'+str(uuid.uuid4())+'.app')
    try:
        shutil.copytree(app,stage,symlinks=False)
        if destination.exists():os.rename(destination,backup)
        try:os.rename(stage,destination)
        except Exception:
            if backup.exists():os.rename(backup,destination)
            raise
        if backup.exists():shutil.rmtree(backup)
    finally:
        if stage.exists():shutil.rmtree(stage)
print('Signed update installed. Restart Yume SIM Hub to finish.')
